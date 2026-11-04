'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerInlineAdminRoutes } = require('../src/admin/inline_routes');

const RULE_ID = '11111111-2222-3333-4444-555555555555';

function makeApp(respond) {
  const queries = [];
  const client = {
    async query(sql, params = []) {
      queries.push({ sql: sql.replace(/\s+/g, ' ').trim(), params });
      return respond(sql, params) || { rows: [] };
    },
  };
  const app = express();
  app.use(express.json());
  const asAdmin = (req, _res, next) => { req.userId = 'admin-1'; req.admin = { email: 'a@x.test', role: 'owner', permissions: [] }; next(); };
  registerInlineAdminRoutes(app, {
    withUserClient: async (_userId, fn) => fn(client),
    requireAdmin: asAdmin,
    requireAuth: asAdmin,
  });
  return { app, queries };
}

async function post(app, path, body = {}) {
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test('approving a report on a field without a typed writer is refused and leaves it pending', async () => {
  const { app, queries } = makeApp((sql) => {
    if (/FROM data_error_reports/.test(sql)) {
      return { rows: [{ id: 'r1', field_path: 'card_products.annual_fee', card_product_id: 'c1', claimed_value: '499' }] };
    }
    return null;
  });
  const result = await post(app, '/admin/error-reports/r1/approve');
  assert.equal(result.status, 422);
  assert.equal(result.body.error, 'field_not_auto_correctable');
  assert.equal(queries.length, 1, 'only the pending-report lookup runs');
  assert.ok(!queries.some((q) => /^(UPDATE|INSERT)/.test(q.sql)));
});

test('approving a reward-rate report still applies the correction and records it', async () => {
  const { app, queries } = makeApp((sql) => {
    if (/FROM data_error_reports/.test(sql)) {
      return { rows: [{ id: 'r2', field_path: `reward_rules.${RULE_ID}.rate`, card_product_id: 'c1', claimed_value: '2.5' }] };
    }
    if (/SELECT id, card_product_id, rate FROM reward_rules/.test(sql)) return { rows: [{ id: RULE_ID, card_product_id: 'c1', rate: 1.5 }] };
    if (/UPDATE reward_rules/.test(sql)) return { rows: [{ id: RULE_ID, rate: 2.5 }] };
    if (/SELECT data_version FROM card_products/.test(sql)) return { rows: [{ data_version: 7 }] };
    if (/INSERT INTO card_catalogue_changes/.test(sql)) return { rows: [{ id: 'change-1' }] };
    return null;
  });
  const result = await post(app, '/admin/error-reports/r2/approve');
  assert.equal(result.status, 200);
  assert.equal(result.body.changeId, 'change-1');
  assert.ok(queries.some((q) => /UPDATE data_error_reports SET state = 'resolved'/.test(q.sql)));
  assert.ok(queries.some((q) => /'approve_error_report'/.test(q.sql)));
});

test('a parked policy alert can still be approved or rejected', async () => {
  for (const decision of ['approved', 'rejected']) {
    const { app, queries } = makeApp((sql) => (/UPDATE policy_change_alerts/.test(sql) ? { rows: [{ id: 'a1' }] } : null));
    const result = await post(app, '/admin/alerts/a1/decide', { decision, note: 'more evidence arrived' });
    assert.equal(result.status, 200);
    const update = queries.find((q) => /UPDATE policy_change_alerts/.test(q.sql));
    assert.deepEqual(update.params[4], ['open', 'needs_more_evidence']);
    assert.ok(queries.some((q) => /'decide_policy_alert'/.test(q.sql)));
  }
});

test('parking only applies to open alerts, and a decided alert returns 404', async () => {
  const { app, queries } = makeApp(() => null);
  const result = await post(app, '/admin/alerts/a1/decide', { decision: 'needs_more_evidence' });
  assert.equal(result.status, 404);
  const update = queries.find((q) => /UPDATE policy_change_alerts/.test(q.sql));
  assert.deepEqual(update.params[4], ['open']);
  assert.ok(!queries.some((q) => /admin_audit_log/.test(q.sql)), 'no audit row without a state change');
});
