'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { parseKeyRing, encryptPhone, decryptPhone } = require('../src/shared_expenses/phone_crypto');
const { describePhone, maskNational } = require('../src/shared_expenses/phone_display');
const { normalizePhone, registerInvitationRoutes } = require('../src/shared_expenses/invitations');
const { cleanLabel, labelKey, isReservedLabel } = require('../src/shared_expenses/label');
const vectors = require('../../contracts/shared_expenses/v1/label_key_vectors.json');

const key = () => crypto.randomBytes(32).toString('base64');
const ringOf = (current, keys) => parseKeyRing(JSON.stringify({ current, keys }));
const INV = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const NUMBER = '+917234512345';

test('encryption round trip, nonce reuse never, key rotation keeps old ciphertext readable', () => {
  const k1 = key(), k2 = key();
  const old = ringOf('k1', { k1 });
  const sealed = encryptPhone(old, INV, NUMBER);
  assert.equal(sealed.keyId, 'k1');
  assert.ok(sealed.enc.length === 28 + NUMBER.length);
  assert.ok(!sealed.enc.toString('latin1').includes('7234512345'));
  assert.notDeepEqual(encryptPhone(old, INV, NUMBER).enc, sealed.enc, 'fresh nonce each time');
  const rotated = ringOf('k2', { k1, k2 });
  assert.equal(decryptPhone(rotated, INV, sealed.enc, sealed.keyId), NUMBER, 'old key id still decrypts');
  assert.equal(encryptPhone(rotated, INV, NUMBER).keyId, 'k2', 'new numbers use the current key');
  assert.equal(decryptPhone(ringOf('k2', { k2 }), INV, sealed.enc, 'k1'), null, 'a retired key cannot decrypt');
});

test('ciphertext is bound to the invitation id and detects tampering', () => {
  const ring = ringOf('k1', { k1: key() });
  const sealed = encryptPhone(ring, INV, NUMBER);
  assert.equal(decryptPhone(ring, OTHER, sealed.enc, sealed.keyId), null, 'copied to another row');
  const flipped = Buffer.from(sealed.enc);
  flipped[flipped.length - 1] ^= 1;
  assert.equal(decryptPhone(ring, INV, flipped, sealed.keyId), null);
  assert.equal(decryptPhone(ring, INV, sealed.enc.subarray(0, 20), sealed.keyId), null);
  assert.equal(decryptPhone(ring, INV, 'nope', sealed.keyId), null);
});

test('a missing or malformed key ring means no capture, never a throw', () => {
  for (const raw of [undefined, null, '', '   ', 'not json', '{}', '{"current":"k1"}', '{"current":"k1","keys":{}}',
    JSON.stringify({ current: 'k9', keys: { k1: key() } }),
    JSON.stringify({ current: 'k1', keys: { k1: Buffer.alloc(16).toString('base64') } }),
    JSON.stringify({ current: 'k1', keys: { 'bad id!': key() } })]) assert.equal(parseKeyRing(raw), null, String(raw));
  assert.equal(encryptPhone(null, INV, NUMBER), null);
  assert.equal(decryptPhone(null, INV, Buffer.alloc(40), 'k1'), null);
});

test('masks show at most six national digits and never throw', () => {
  assert.deepEqual(describePhone('+917234512345'), { countryCode: '+91', mask: '+91 72••• •2345', last4: '2345' });
  for (const n of ['+917234512345', '+14155552671', '+447911123456', '+96812345678', '+4912345678901']) {
    const { mask } = describePhone(n);
    assert.ok((mask.replace(/^\+\d+ /, '').match(/\d/g) || []).length <= 6, mask);
  }
  assert.match(describePhone('+9112345').mask, /^\+91 •••345$/, 'short numbers show the last three only');
  assert.equal(maskNational('1234567'), '•••567');
  for (const bad of ['+999999999', 'garbage', '', '+', null, undefined, 42]) {
    const shown = describePhone(bad);
    assert.equal(shown.countryCode, '');
    assert.match(shown.mask, /^•{4} \d{0,4}$/);
  }
});

test('E.164 numbers of seven digits are accepted, odd characters are not', () => {
  assert.equal(normalizePhone('+1234567'), '+1234567');
  assert.equal(normalizePhone('+44 20 7946 0958'), '+442079460958');
  assert.equal(normalizePhone('98765 43210'), '+919876543210');
  for (const bad of ['+123456', '+1234567890123456', '+١٢٣٤٥٦٧', '+12345​67', '+12345 6a7', '']) assert.throws(() => normalizePhone(bad), bad);
});

test('label_key and clean_label vectors are shared with SQL', () => {
  for (const v of vectors.labelKey) assert.equal(labelKey(v.input), v.key, JSON.stringify(v.input));
  for (const v of vectors.cleanLabel) assert.equal(cleanLabel(v.input), v.clean, JSON.stringify(v.input));
  assert.ok(isReservedLabel('You') && isReservedLabel('Pandа Pay') && isReservedLabel('former-member') && !isReservedLabel('Youssef'));
  assert.equal(cleanLabel('‮​\u0085'), '');
  assert.ok(Array.from(cleanLabel('\u{1F600}'.repeat(80))).length === 40);
});

// ------------------------------------------------------------------ routes (fake database)
const SECRET = 'synthetic-secret-for-tests-only-32-bytes';
const USER = '33333333-3333-4333-8333-333333333333';
const TOKEN = 'A'.repeat(43);

function harness({ enabled, ring, contacts = { phone: { verified: true, value: NUMBER } }, handlers = {} }) {
  const routes = new Map(), queries = [];
  const app = { get: (p, ...h) => routes.set('GET ' + p, h[h.length - 1]), post: (p, ...h) => routes.set('POST ' + p, h[h.length - 1]) };
  const withUserClient = async (_user, fn) => fn({
    async query(sql, params = []) {
      queries.push({ sql: sql.replace(/\s+/g, ' ').trim(), params });
      for (const [re, fnr] of Object.entries(handlers)) if (new RegExp(re).test(sql)) return { rows: [{ result: fnr(params) }] };
      return { rows: [{ result: {} }] };
    },
  });
  const errors = [];
  registerInvitationRoutes(app, { protect: (fn) => [fn], withUserClient, sendError: (res, e) => { errors.push(e); res.status(500).json({ error: e.message }); }, secret: SECRET, phone: { enabled: () => enabled, ring: () => ring } });
  async function call(method, path, { body = {}, query = {} } = {}) {
    const out = { code: 200, headers: {} };
    const res = { set(h, v) { Object.assign(out.headers, typeof h === 'string' ? { [h]: v } : h); return res; }, status(c) { out.code = c; return res; }, json(b) { out.body = b; return res; }, type() { return res; }, send(b) { out.body = b; return res; } };
    try { await routes.get(method + ' ' + path)({ body, query, params: {}, userId: USER, verifiedSession: { verifiedContacts: contacts } }, res); } catch (e) { errors.push(e); out.code = 400; }
    return out;
  }
  return { call, queries, errors };
}

const claimBody = (extra = {}) => ({ token: TOKEN, operationId: '44444444-4444-4444-8444-444444444444', ...extra });
const claimResult = { contextId: INV, memberId: OTHER, invitationId: '55555555-5555-4555-8555-555555555555', status: 'awaiting_owner' };

test('feature off: claim stores nothing, answers as before, and the new endpoints do not exist', async () => {
  const h = harness({ enabled: false, ring: ringOf('k1', { k1: key() }), handlers: { claim_invitation: () => ({ ...claimResult }) } });
  const r = await h.call('POST', '/shared-expenses/invitations/claim', { body: claimBody({ sharePhone: true }) });
  assert.deepEqual(r.body, { contextId: INV, memberId: OTHER, status: 'awaiting_owner' }, 'no invitationId, no phoneShare');
  assert.equal(h.queries.length, 1, 'no attach call');
  assert.equal(h.queries[0].params[5], null, 'no consent recorded');
  assert.equal((await h.call('POST', '/shared-expenses/invitations/reveal-phone', { body: { invitationId: claimResult.invitationId, operationId: claimBody().operationId } })).code, 404);
  assert.equal((await h.call('POST', '/shared-expenses/invitations/check-phone', { body: { invitationId: claimResult.invitationId, phoneNumber: NUMBER } })).code, 404);
  const list = harness({ enabled: false, ring: null, handlers: { list_join_requests: () => ({ items: [{ invitationId: INV, claimantPhone: { v: 1 }, verifiedPhoneSuffix: '2345' }] }) } });
  assert.deepEqual((await list.call('GET', '/shared-expenses/invitations/requests')).body, { items: [{ invitationId: INV, verifiedPhoneSuffix: '2345' }] });
  const pv = harness({ enabled: false, ring: null, handlers: { preview_invitation: () => ({ kind: 'invitation' }) } });
  assert.deepEqual((await pv.call('POST', '/shared-expenses/invitations/preview', { body: { token: TOKEN } })).body, { kind: 'invitation' });
});

test('feature on: consent is sent, the number is encrypted before it leaves Node, nothing in clear reaches SQL', async () => {
  const ring = ringOf('k1', { k1: key() });
  const spy = [];
  const originals = {};
  for (const m of ['log', 'info', 'warn', 'error', 'debug']) { originals[m] = console[m]; console[m] = (...a) => spy.push(a.join(' ')); }
  let h, r;
  try {
    h = harness({ enabled: true, ring, handlers: { claim_invitation: () => ({ ...claimResult }), attach_claimant_phone: () => ({ attached: true }) } });
    r = await h.call('POST', '/shared-expenses/invitations/claim', { body: claimBody({ sharePhone: true }) });
  } finally { Object.assign(console, originals); }
  assert.deepEqual(r.body, { ...claimResult, phoneShare: 'shared' });
  const attach = h.queries.find((q) => /attach_claimant_phone/.test(q.sql));
  assert.ok(attach);
  assert.equal(h.queries[0].params[5], null, 'shared is attached afterwards, not passed to claim');
  const everything = JSON.stringify(h.queries.map((q) => q.params.map((p) => (Buffer.isBuffer(p) ? p.toString('latin1') : p))));
  assert.ok(!everything.includes('7234512345'), 'plaintext number never sent to the database');
  assert.ok(!spy.join('\n').includes('7234512345'), 'and never logged');
  assert.equal(attach.params[2], '+91');
  assert.equal(attach.params[3], '+91 72••• •2345');
  assert.equal(decryptPhone(ring, claimResult.invitationId, attach.params[4], attach.params[5]), NUMBER);
  assert.match(attach.params[1], /^[a-f0-9]{64}$/);
});

test('feature on: decline, email-only and old-app claims record the right consent and store no number', async () => {
  const ring = ringOf('k1', { k1: key() });
  const run = async (contacts, body) => {
    const h = harness({ enabled: true, ring, contacts, handlers: { claim_invitation: () => ({ ...claimResult }) } });
    const r = await h.call('POST', '/shared-expenses/invitations/claim', { body });
    return { r, h };
  };
  let x = await run({ phone: { verified: true, value: NUMBER } }, claimBody({ sharePhone: false }));
  assert.equal(x.h.queries[0].params[5], 'declined');assert.equal(x.r.body.phoneShare, 'declined');assert.equal(x.h.queries.length, 1);
  x = await run({}, claimBody());
  assert.equal(x.h.queries[0].params[5], 'none');assert.equal(x.r.body.phoneShare, 'none');
  x = await run({ phone: { verified: false, value: NUMBER } }, claimBody({ sharePhone: true }));
  assert.equal(x.h.queries[0].params[5], 'none', 'an unverified number is no number');
  x = await run({ phone: { verified: true, value: NUMBER } }, claimBody());
  assert.equal(x.h.queries[0].params[5], null);assert.equal(x.r.body.phoneShare, 'not_asked', 'old app');
  const r = await run({ phone: { verified: true, value: NUMBER } }, claimBody({ sharePhone: 'yes' }));
  assert.equal(r.h.errors.length, 1, 'sharePhone must be a boolean');
});

test('missing key ring: the claim works and no number is stored', async () => {
  const h = harness({ enabled: true, ring: null, handlers: { claim_invitation: () => ({ ...claimResult }) } });
  const r = await h.call('POST', '/shared-expenses/invitations/claim', { body: claimBody({ sharePhone: true }) });
  assert.equal(r.body.phoneShare, 'not_asked');
  assert.ok(!h.queries.some((q) => /attach_claimant_phone/.test(q.sql)));
});

test('an attach failure keeps the claim and stores nothing', async () => {
  const ring = ringOf('k1', { k1: key() });
  const h = harness({ enabled: true, ring, handlers: { claim_invitation: () => ({ ...claimResult }), attach_claimant_phone: () => ({ attached: false }) } });
  assert.equal((await h.call('POST', '/shared-expenses/invitations/claim', { body: claimBody({ sharePhone: true }) })).body.phoneShare, 'not_asked');
});

test('preview adds phoneSharing and the caller\'s own masked number, never anyone else\'s', async () => {
  const ring = ringOf('k1', { k1: key() });
  const h = harness({ enabled: true, ring, handlers: { preview_invitation: () => ({ kind: 'group_link', ownerName: 'Olive' }) } });
  assert.deepEqual((await h.call('POST', '/shared-expenses/invitations/preview', { body: { token: TOKEN } })).body, { kind: 'group_link', ownerName: 'Olive', phoneSharing: true, ownPhoneMask: '+91 72••• •2345' });
  const none = harness({ enabled: true, ring, contacts: {}, handlers: { preview_invitation: () => ({ kind: 'group_link' }) } });
  assert.equal((await none.call('POST', '/shared-expenses/invitations/preview', { body: { token: TOKEN } })).body.ownPhoneMask, null);
  const noKey = harness({ enabled: true, ring: null, handlers: { preview_invitation: () => ({ kind: 'group_link' }) } });
  assert.equal((await noKey.call('POST', '/shared-expenses/invitations/preview', { body: { token: TOKEN } })).body.phoneSharing, false);
});

test('reveal decrypts for the owner only, is no-store, and maps every refusal', async () => {
  const ring = ringOf('k1', { k1: key() });
  const sealed = encryptPhone(ring, claimResult.invitationId, NUMBER);
  const body = { invitationId: claimResult.invitationId, operationId: claimBody().operationId };
  const ok = harness({ enabled: true, ring, handlers: { reveal_claimant_phone: () => ({ invitationId: claimResult.invitationId, enc: sealed.enc.toString('hex'), keyId: sealed.keyId }) } });
  const r = await ok.call('POST', '/shared-expenses/invitations/reveal-phone', { body });
  assert.equal(r.body.e164, NUMBER);assert.equal(r.body.invitationId, claimResult.invitationId);assert.ok(!Number.isNaN(Date.parse(r.body.revealedAt)));
  assert.equal(r.headers['Cache-Control'], 'no-store');
  for (const [error, code] of [['phone_not_available', 409], ['owner_phone_required', 409], ['reveal_rate_limited', 429]]) {
    const h = harness({ enabled: true, ring, handlers: { reveal_claimant_phone: () => ({ error }) } });
    const x = await h.call('POST', '/shared-expenses/invitations/reveal-phone', { body });
    assert.equal(x.code, code);assert.deepEqual(x.body, { error });
  }
  const rotatedAway = harness({ enabled: true, ring: ringOf('k2', { k2: key() }), handlers: { reveal_claimant_phone: () => ({ invitationId: claimResult.invitationId, enc: sealed.enc.toString('hex'), keyId: 'k1' }) } });
  assert.equal((await rotatedAway.call('POST', '/shared-expenses/invitations/reveal-phone', { body })).code, 409, 'undecryptable => not available');
  const bad = harness({ enabled: true, ring, handlers: {} });
  await bad.call('POST', '/shared-expenses/invitations/reveal-phone', { body: { invitationId: 'x', operationId: 'y' } });
  assert.equal(bad.errors.length, 1);
});

test('requests: full numbers appear only for look-alike items and only when asked', async () => {
  const ring = ringOf('k1', { k1: key() });
  const a = '66666666-6666-4666-8666-666666666666', b = '77777777-7777-4777-8777-777777777777';
  const sealed = encryptPhone(ring, a, NUMBER);
  const handlers = {
    list_join_requests_enc: (p) => { assert.deepEqual(p[0], [a]); return [{ invitationId: a, enc: sealed.enc.toString('hex'), keyId: 'k1' }]; },
    list_join_requests: () => ({ items: [{ invitationId: a, claimantPhone: { lookalike: true, mask: 'm' } }, { invitationId: b, claimantPhone: { lookalike: false, mask: 'm2' } }] }),
  };
  const h = harness({ enabled: true, ring, handlers });
  const plain = await h.call('GET', '/shared-expenses/invitations/requests');
  assert.ok(!JSON.stringify(plain.body).includes('72345'));
  assert.ok(!h.queries.some((q) => /_enc/.test(q.sql)));
  const full = await harness({ enabled: true, ring, handlers }).call('GET', '/shared-expenses/invitations/requests', { query: { withLookalikeFull: '1' } });
  assert.equal(full.body.items[0].fullNumber, NUMBER);
  assert.equal('fullNumber' in full.body.items[1], false);
  assert.equal(full.headers['Cache-Control'], 'no-store');
  const bad = harness({ enabled: true, ring, handlers });
  await bad.call('GET', '/shared-expenses/invitations/requests', { query: { withLookalikeFull: 'yes' } });
  assert.equal(bad.errors.length, 1);
});

test('check-phone sends only a keyed hash and returns match without disclosure', async () => {
  const h = harness({ enabled: true, ring: null, handlers: { check_claimant_phone: () => ({ matches: true, attemptsLeft: 1 }) } });
  const body = { invitationId: claimResult.invitationId, phoneNumber: '+91 72345 12345' };
  const r = await h.call('POST', '/shared-expenses/invitations/check-phone', { body });
  assert.deepEqual(r.body, { matches: true, attemptsLeft: 1 });
  assert.match(h.queries[0].params[1], /^[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(h.queries).includes('7234512345'));
  const limit = harness({ enabled: true, ring: null, handlers: { check_claimant_phone: () => ({ error: 'check_attempts_exhausted' }) } });
  assert.equal((await limit.call('POST', '/shared-expenses/invitations/check-phone', { body })).code, 429);
  const unknown = harness({ enabled: true, ring: null, handlers: { check_claimant_phone: () => ({ matches: null, attemptsLeft: 3 }) } });
  assert.equal((await unknown.call('POST', '/shared-expenses/invitations/check-phone', { body })).body.matches, null);
  const invalid = harness({ enabled: true, ring: null });
  await invalid.call('POST', '/shared-expenses/invitations/check-phone', { body: { ...body, phoneNumber: 'not a number' } });
  assert.equal(invalid.errors.length, 1);
  assert.ok(!invalid.errors[0].message.includes('not a number'), 'error text never echoes the input');
});

test('push audience and notifier never gain a phone field', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require.resolve('../src/shared_expenses/notifications.js'), 'utf8');
  assert.ok(!/claimant_?phone|phone_?share|e164|fullNumber/i.test(src));
});
