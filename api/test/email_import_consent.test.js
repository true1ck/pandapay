'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const {
  EMAIL_IMPORT_CONSENT_REQUIRED, hasCurrentEmailImportConsent, requireEmailImportConsent, isEmailImportConsentRequired,
} = require('../src/email_import_consent');
const { hasImapControlChars, isValidImapHost } = require('../src/imap_network');
const { normalizeSenderFilter } = require('../src/imap_credentials');
const { requireBankSenders } = require('../src/imap_connections_store');

// Email import reads mail on the server, so the server itself refuses to
// connect a mailbox or issue a forwarding address without a current
// `email_import` consent. The app's consent sheet is not the only gate.

const POLICY = '2026-11-15';
const PROFILE = '00000000-0000-4000-8000-000000000001';

/** A fake client whose latest `email_import` row is `latest` (or none). */
function fakeClient(latest, log = []) {
  return {
    query: async (sql, params) => {
      log.push({ sql, params });
      if (/FROM user_consents/.test(sql)) return { rows: latest ? [latest] : [] };
      if (/INSERT INTO forwarding_addresses/.test(sql)) {
        return { rows: [{ id: 'fa1', profile_id: params[0], local_part: params[1], is_active: true }] };
      }
      if (/FROM forwarding_addresses/.test(sql)) return { rows: [] };
      return { rows: [] };
    },
  };
}

const grant = (overrides = {}) => ({ granted: true, revoked_at: null, policy_version: POLICY, ...overrides });

test('a current, granted email_import consent counts', async () => {
  const log = [];
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant(), log), PROFILE, POLICY), true);
  assert.equal(log.length, 1);
  assert.match(log[0].sql, /purpose = 'email_import'/);
  // Same tie-break as the SMS consents: a withdrawal in the same instant wins.
  assert.match(log[0].sql, /ORDER BY granted_at DESC, granted ASC, id DESC/);
  assert.deepEqual(log[0].params, [PROFILE]);
});

test('no consent, a withdrawal, a revoked row or an older policy version does not count', async () => {
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(null), PROFILE, POLICY), false);
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant({ granted: false })), PROFILE, POLICY), false);
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant({ revoked_at: new Date() })), PROFILE, POLICY), false);
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant({ policy_version: '2026-01-01' })), PROFILE, POLICY), false);
});

test('a missing current policy version never counts as consent', async () => {
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant()), PROFILE, ''), false);
  assert.equal(await hasCurrentEmailImportConsent(fakeClient(grant()), PROFILE, undefined), false);
});

test('requireEmailImportConsent throws a recognisable error', async () => {
  await assert.doesNotReject(requireEmailImportConsent(fakeClient(grant()), PROFILE, POLICY));
  const error = await requireEmailImportConsent(fakeClient(null), PROFILE, POLICY).catch((e) => e);
  assert.ok(isEmailImportConsentRequired(error));
  assert.equal(EMAIL_IMPORT_CONSENT_REQUIRED, 'email_import_consent_required');
  assert.equal(isEmailImportConsentRequired(new Error('other')), false);
  assert.equal(isEmailImportConsentRequired(undefined), false);
});

// The routes are registered inside index.js, which boots the whole server, so
// (as in consents_purposes.test.js) the route source is evaluated against
// fakes instead of importing the module.
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');

function routeSource(signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `${signature} is registered in index.js`);
  return source.slice(start, source.indexOf('\n});', start) + 5);
}

function response() {
  return {
    code: null,
    body: null,
    status(code) { this.code = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
}

const deps = (latest, log, extra = {}) => ({
  app: { post: (_path, _auth, fn) => { deps.handler = fn; }, get: (_path, _auth, fn) => { deps.handler = fn; } },
  requireAuth: () => {},
  withUserClient: async (_profile, fn) => fn(fakeClient(latest, log)),
  safeErrorCode: (error) => error?.code || 'unknown',
  config: { productTermsVersion: POLICY, imapKeyring: { current: { id: 'k1', bytes: crypto.randomBytes(32) } } },
  requireEmailImportConsent,
  isEmailImportConsentRequired,
  ...extra,
});

function load(signature, values) {
  const names = Object.keys(values);
  new Function(...names, routeSource(signature))(...names.map((name) => values[name]));
  return deps.handler;
}

async function postImapConnection(latest) {
  const log = [];
  const saved = [];
  const handler = load("app.post('/imap-connections',", deps(latest, log, {
    hasImapControlChars,
    isValidImapHost,
    normalizeSenderFilter,
    requireBankSenders,
    bankSenderPatterns: async () => ['alerts@bank'],
    saveImapConnection: async (_client, input) => {
      saved.push(input);
      return { id: 'c1', email: input.email, sender_filter: input.senderFilter };
    },
  }));
  const res = response();
  await handler({
    userId: PROFILE,
    body: {
      email: 'me@example.test',
      appPassword: 'synthetic-app-password',
      imapHost: 'imap.example.test',
      imapPort: 993,
      senderFilter: 'alerts@bank.test',
    },
  }, res);
  return { res, saved, log };
}

async function postForwardingAddress(latest) {
  const log = [];
  const handler = load("app.post('/forwarding-addresses',", deps(latest, log));
  const res = response();
  await handler({ userId: PROFILE, body: {} }, res);
  return { res, log };
}

test('POST /imap-connections refuses without email_import consent and stores nothing', async () => {
  const { res, saved } = await postImapConnection(null);
  assert.equal(res.code, 403);
  assert.deepEqual(res.body, { error: 'email_import_consent_required' });
  assert.equal(saved.length, 0);
});

test('POST /imap-connections refuses a withdrawn or out-of-date consent', async () => {
  for (const latest of [grant({ granted: false }), grant({ policy_version: '2026-01-01' })]) {
    const { res, saved } = await postImapConnection(latest);
    assert.equal(res.code, 403);
    assert.equal(res.body.error, 'email_import_consent_required');
    assert.equal(saved.length, 0);
  }
});

test('POST /imap-connections saves the mailbox once consent is current', async () => {
  const { res, saved } = await postImapConnection(grant());
  assert.equal(res.code, 201);
  assert.equal(saved.length, 1);
  assert.equal(res.body.imapConnection.id, 'c1');
});

test('POST /forwarding-addresses refuses without email_import consent and issues nothing', async () => {
  const { res, log } = await postForwardingAddress(null);
  assert.equal(res.code, 403);
  assert.deepEqual(res.body, { error: 'email_import_consent_required' });
  assert.ok(!log.some(({ sql }) => /forwarding_addresses/.test(sql)), 'no forwarding address is read or written');
});

test('POST /forwarding-addresses issues an address once consent is current', async () => {
  const { res, log } = await postForwardingAddress(grant());
  assert.equal(res.code, 201);
  assert.equal(res.body.forwardingAddress.profile_id, PROFILE);
  assert.ok(log.some(({ sql }) => /INSERT INTO forwarding_addresses/.test(sql)));
});


async function getForwardingAddress(latest) {
  const log = [];
  const handler = load("app.get('/forwarding-addresses/me',", deps(latest, log));
  const res = response();
  await handler({ userId: PROFILE }, res);
  return { res, log };
}

test('GET /forwarding-addresses/me refuses without email_import consent and reads nothing', async () => {
  const { res, log } = await getForwardingAddress(null);
  assert.equal(res.code, 403);
  assert.deepEqual(res.body, { error: 'email_import_consent_required' });
  assert.ok(!log.some(({ sql }) => /FROM forwarding_addresses/.test(sql)));
});

test('GET /forwarding-addresses/me answers once consent is current', async () => {
  const { res, log } = await getForwardingAddress(grant());
  assert.notEqual(res.code, 403);
  assert.deepEqual(res.body, { forwardingAddress: null });
  assert.ok(log.some(({ sql }) => /FROM forwarding_addresses/.test(sql)));
});

test('forwarded email for an owner without consent is not turned into a transaction', () => {
  const route = routeSource("app.post('/inbound-emails/webhook',");
  const ingest = route.indexOf('pandapay.ingest_inbound_email');
  const check = route.indexOf('hasCurrentEmailImportConsent');
  const create = route.indexOf('profileDisplayName');
  assert.ok(ingest >= 0 && check > ingest, 'consent is checked after the owner is known');
  assert.ok(create > check, 'and before any transaction is created');
  assert.match(route.slice(check, create), /body_text = NULL/);
});
