'use strict';
// Lane U (LO-09): the public API serves pre-signed bundles and never signs.
// Run: node --test api/test/sms_v2/lane_u_signing.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');

const { createSigner, verifyBundle } = require('../../src/sms_v2/signer');
const builder = require('../../src/sms_v2/bundle_builder');
const { MemoryStore } = require('../../src/sms_v2/rules_store');
const { registerRules } = require('../../src/sms_v2/rules_route');
const { importBundle } = require('../../src/sms_v2/rules_admin_route');
const stats = require('../../src/sms_v2/rule_stats');
const { assertNoSigningKeyInPublicProcess } = require('../../src/sms_v2/security');

const CONTRACTS = path.resolve(__dirname, '../../../contracts/sms/v2');
const fullBundle = JSON.parse(fs.readFileSync(path.join(CONTRACTS, 'fixtures/valid/bundle/full.json'), 'utf8'));
const newSigner = (keyId) => createSigner({
  privateKeyPem: crypto.generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId,
});
const signer = newSigner('sms-rules-test');
const USER = '00000000-0000-4000-8000-000000000042';
const ADMIN = 'aaaaaaaa-0000-4000-8000-000000000001';
const T0 = new Date('2026-11-20T10:00:00Z');
const DAY = 86400000;

async function harness() {
  const store = new MemoryStore();
  let clock = T0;
  const app = express();
  // Deliberately no signer: the public process holds no key.
  registerRules(app, {
    store, requireSmsV2: (_q, _s, n) => n(),
    requireMember: (req, _res, next) => { req.userId = USER; next(); },
    now: () => clock,
  });
  await store.tx(ADMIN, (s) => importBundle(s, fullBundle, { signer, adminId: ADMIN, now: clock }));
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const get = async (since = 0) => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/sms/v2/rules?since=${since}`);
    return { status: res.status, json: res.status === 200 ? await res.json() : await res.json().catch(() => null), headers: res.headers };
  };
  return { store, get, setClock: (d) => { clock = d; }, close: () => { server.closeAllConnections(); server.close(); } };
}
const refresh = (h, over = {}) => h.store.tx(ADMIN, (s) => builder.refreshServedBundles(s, { signer, now: over.now, ...over }));

test('LO-09 public rules route serves the pre-signed bundle without any signing key', async () => {
  const h = await harness();
  try {
    const res = await h.get();
    assert.equal(res.status, 200);
    assert.ok(verifyBundle(res.json, signer.publicKeyPem));
    assert.equal(Date.parse(res.json.expiresAt) - T0.getTime(), 7 * DAY);
  } finally { h.close(); }
});

test('LO-09 public API sources never load or use the rule signing key', () => {
  const src = path.resolve(__dirname, '../../src/sms_v2');
  for (const file of ['rules_route.js', 'index.js', 'sync_route.js', 'rule_stats.js']) {
    const text = fs.readFileSync(path.join(src, file), 'utf8');
    for (const banned of ['signerFromEnv', 'SMS_RULES_SIGNING_KEY', 'bundleForServing', 'signBundle', 'createSigner', "require('./signer')"]) {
      assert.ok(!text.includes(banned), `${file} must not reference ${banned}`);
    }
  }
});

test('LO-09 an expired served bundle fails closed with 503 and is never re-signed', async () => {
  const h = await harness();
  try {
    h.setClock(new Date(T0.getTime() + 8 * DAY));
    const res = await h.get();
    assert.equal(res.status, 503);
    assert.equal(res.json.error, 'bundle_unavailable');
    assert.equal(res.json.rules, undefined);
  } finally { h.close(); }
});

test('LO-09 a missing, unsigned or mismatched served body answers 503', async () => {
  const h = await harness();
  try {
    for (const mutate of [
      (row) => { row.servedBody = null; },
      (row) => { row.servedBody.signature = null; },
      (row) => { row.servedBody.bundleVersion = 99; },
    ]) {
      const saved = structuredClone(h.store.state.bundles);
      for (const row of h.store.state.bundles) mutate(row);
      assert.equal((await h.get()).status, 503);
      h.store.state.bundles = saved;
    }
    assert.equal((await h.get()).status, 200);
  } finally { h.close(); }
});

test('LO-09 the job re-signs before expiry, and the phone then gets the fresh expiry', async () => {
  const h = await harness();
  try {
    assert.deepEqual(await refresh(h, { now: new Date(T0.getTime() + 2 * DAY) }), [], 'five days left: nothing due');
    const later = new Date(T0.getTime() + 5 * DAY);
    const done = await refresh(h, { now: later });
    assert.deepEqual(done.map((d) => d.cohort).sort(), ['all', 'pct25', 'pct5', 'testers']);
    h.setClock(new Date(T0.getTime() + 8 * DAY));
    const res = await h.get();
    assert.equal(res.status, 200, 'previously expired clock is now covered');
    assert.ok(verifyBundle(res.json, signer.publicKeyPem));
    assert.equal(Date.parse(res.json.expiresAt), Math.floor(later.getTime() / 3600000) * 3600000 + 7 * DAY);
    assert.deepEqual(await refresh(h, { now: later }), [], 'idempotent');
  } finally { h.close(); }
});

test('LO-09 the job re-signs everything when the signing key id changes (rotation)', async () => {
  const h = await harness();
  try {
    const next = newSigner('sms-rules-next');
    const done = await h.store.tx(ADMIN, (s) => builder.refreshServedBundles(s, { signer: next, now: T0 }));
    assert.equal(done.length, 4);
    const res = await h.get();
    assert.equal(res.json.signature.keyId, 'sms-rules-next');
    assert.ok(verifyBundle(res.json, next.publicKeyPem));
    assert.ok(!verifyBundle(res.json, signer.publicKeyPem));
  } finally { h.close(); }
});

test('LO-09 the job refuses to sign a stored body that no longer matches its content hash', async () => {
  const h = await harness();
  try {
    h.store.state.bundles[0].body.senders = [];
    h.store.state.bundles[0].servedBody = null;
    await assert.rejects(refresh(h, { now: T0 }), (e) => e.code === 'bundle_corrupt');
  } finally { h.close(); }
});

test('LO-09 runRuleJobs reports refreshed bundles', async () => {
  const h = await harness();
  try {
    const out = await stats.runRuleJobs({ store: h.store, signer, adminId: ADMIN, now: new Date(T0.getTime() + 5 * DAY) });
    assert.equal(out.refreshed.length, 4);
  } finally { h.close(); }
});

test('LO-09 production public process flags a signing key in its environment', () => {
  const lines = [];
  assert.equal(assertNoSigningKeyInPublicProcess({ NODE_ENV: 'production', SMS_RULES_SIGNING_KEY: 'x' }, (m) => lines.push(m)), false);
  assert.match(lines.join(' '), /SMS_RULES_SIGNING_KEY/);
  assert.equal(assertNoSigningKeyInPublicProcess({ NODE_ENV: 'production' }, () => assert.fail('no log')), true);
  assert.equal(assertNoSigningKeyInPublicProcess({ NODE_ENV: 'test', SMS_RULES_SIGNING_KEY: 'x' }, () => assert.fail('no log')), true);
});
