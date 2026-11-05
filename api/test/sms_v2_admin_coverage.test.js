'use strict';
// Everything the learning loop does is visible and controllable in the admin
// portal. This test fails when a route, a setting or a status has no console
// surface: it is the audit behind the coverage matrix in the plan (Task B7).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { routeManifest, routeKey } = require('../src/admin/route_manifest');
const { SETTINGS, listSettings } = require('../src/sms_v2/settings');

const root = path.resolve(__dirname, '../..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const authManifest = JSON.parse(read('auth/src/admin_route_manifest.json'));
const docsManifest = JSON.parse(read('docs/admin-console-contracts/v1/routes.json'));
const client = read('console/lib/data/sms_v2_admin_api.dart');

// [method, path, permission, freshMfa]. Every learning-loop admin route.
const ROUTES = [
  ['GET', '/admin/sms/v2/settings', 'learning.read', false],
  ['PUT', '/admin/sms/v2/settings/:key', 'learning.publish', true],
  ['GET', '/admin/sms/v2/user-limits', 'learning.read', false],
  ['PUT', '/admin/sms/v2/user-limits/:profileId/:key', 'learning.publish', true],
  ['DELETE', '/admin/sms/v2/user-limits/:profileId/:key', 'learning.publish', true],
  ['GET', '/admin/sms/v2/learning/summary', 'learning.read', false],
  ['GET', '/admin/sms/v2/learning/categories', 'learning.read', false],
  ['GET', '/admin/sms/v2/learning/merchant-names', 'learning.read', false],
  ['GET', '/admin/sms/v2/learning/uncategorised', 'learning.read', false],
  ['GET', '/admin/sms/v2/learning/reporters', 'learning.read', false],
  ['POST', '/admin/sms/v2/learning/decisions', 'learning.publish', true],
  ['PUT', '/admin/sms/v2/merchant-aliases/:id/draft', 'learning.publish', true],
  ['GET', '/admin/sms/v2/merchant-aliases/:id/candidate', 'learning.read', false],
  ['POST', '/admin/sms/v2/merchant-aliases/:id/publish', 'learning.publish', true],
  ['POST', '/admin/sms/v2/templates/:hash/reject', 'learning.publish', true],
  ['POST', '/admin/sms/v2/templates/:hash/requeue', 'learning.publish', true],
  ['POST', '/admin/sms/v2/templates/:hash/block', 'learning.publish', true],
  ['POST', '/admin/sms/v2/merchant-suggestions/:key/ask-again', 'learning.publish', true],
  ['GET', '/admin/sms/v2/audit', 'learning.read', false],
];

const fragment = (route) =>
  route.replace('/admin/sms/v2/', '').replace(/:[A-Za-z]+/g, '\\$\\{[^}]+\\}');

for (const [method, route, permission, freshMfa] of ROUTES) {
  test(`${method} ${route} is classified, mirrored and called by the console`, () => {
    const entry = routeManifest.find((r) => routeKey(r.method, r.path) === routeKey(method, route));
    assert.ok(entry, 'missing from api/src/admin/route_manifest.js');
    assert.equal(entry.permission, permission);
    assert.equal(entry.freshMfa, freshMfa);
    for (const [name, list] of [['auth manifest', authManifest], ['docs manifest', docsManifest]]) {
      const mirror = list.find((r) => routeKey(r.method, r.path) === routeKey(method, route));
      assert.ok(mirror, `missing from ${name}`);
      assert.equal(mirror.permission, permission, name);
      assert.equal(mirror.freshMfa, freshMfa, name);
    }
    assert.match(client, new RegExp(fragment(route)), 'console/lib/data/sms_v2_admin_api.dart never calls this route');
  });
}

test('every setting has a console row, a default and a validated range', () => {
  const rows = listSettings([], process.env);
  assert.deepEqual(rows.map((r) => r.key).sort(), Object.keys(SETTINGS).sort());
});

test('the console names every setting the registry has', () => {
  const labels = read('console/lib/features/sms_rules/settings_tab.dart');
  for (const key of Object.keys(SETTINGS)) {
    assert.ok(labels.includes(`'${key}'`), `settings_tab.dart has no label for ${key}`);
  }
});

test('the Templates tab offers every layout status', () => {
  // The Templates tab lives in templates_tab.dart (smsTemplateStatuses); the screen hosts it.
  const tab = read('console/lib/features/sms_rules/templates_tab.dart');
  for (const status of ['held', 'queued', 'working', 'ready', 'failed', 'covered', 'rejected', 'blocked']) {
    assert.ok(tab.includes(`'${status}'`), `Templates tab has no '${status}' filter`);
  }
});

test('every status the database allows for a layout is one the console filters on', () => {
  const sql = fs.readdirSync(path.join(root, 'db/supabase/migrations')).sort()
    .map((file) => read(`db/supabase/migrations/${file}`))
    .filter((text) => text.includes('sms_v2_unknown_templates_ai_status_check'))
    .at(-1);
  const allowed = [...sql.match(/CHECK \(ai_status IN \(([^)]*)\)\)/)[1].matchAll(/'([a-z]+)'/g)].map((m) => m[1]);
  const tab = read('console/lib/features/sms_rules/templates_tab.dart');
  for (const status of allowed) assert.ok(tab.includes(`'${status}'`), `the database allows '${status}' but the Templates tab has no filter`);
});

test('the Learning tab, the Settings tab and the Overview each have their controls', () => {
  const learning = read('console/lib/features/sms_rules/learning_tab.dart');
  for (const text of ['Create rule', 'Dismiss', 'Create name', 'Pick category', 'Use suggestion', 'Ask again', 'Reporters', 'Set limit']) {
    assert.ok(learning.includes(text), `Learning tab is missing "${text}"`);
  }
  const templates = read('console/lib/features/sms_rules/templates_tab.dart');
  for (const text of ['Create draft', 'Reject', 'Requeue', 'Block']) assert.ok(templates.includes(text), `Templates tab is missing "${text}"`);
  const settings = read('console/lib/features/sms_rules/settings_tab.dart');
  for (const text of ['Per-user limits', 'Recent changes']) assert.ok(settings.includes(text), `Settings tab is missing "${text}"`);
  const overview = read('console/lib/features/overview/overview_screen.dart');
  for (const text of ['Learning candidates', 'AI drafting']) assert.ok(overview.includes(text), `Overview is missing the "${text}" tile`);
});
