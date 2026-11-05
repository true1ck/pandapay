'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

// POST /consents is registered inside index.js, which boots the whole server,
// so (like consent_ordering_pg.test.js) the route source is evaluated against
// a fake database client instead of importing the module.
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');

function purposes() {
  const match = source.match(/const CONSENT_PURPOSES = (\[[\s\S]*?\]);/);
  assert.ok(match, 'CONSENT_PURPOSES is declared in index.js');
  return new Function(`return ${match[1]};`)();
}

function postConsent(body) {
  const start = source.indexOf("app.post('/consents',");
  const end = source.indexOf('\n});', start) + 5;
  let handler;
  const inserted = [];
  new Function('app', 'requireAuth', 'withUserClient', 'CONSENT_PURPOSES', 'safeErrorCode', source.slice(start, end))(
    { post: (_path, _auth, fn) => { handler = fn; } },
    () => {},
    async (_profile, fn) => fn({
      query: async (sql, params) => {
        if (/INSERT INTO user_consents/.test(sql)) {
          inserted.push(params);
          return { rows: [{ purpose: params[1], granted: params[3], policy_version: params[2], source_screen: params[4] }] };
        }
        return { rows: [] };
      },
    }),
    purposes(),
    (error) => error?.code || 'unknown',
  );
  const res = {
    code: null,
    body: null,
    status(code) { this.code = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
  return handler({ userId: '00000000-0000-4000-8000-000000000001', body }, res).then(() => ({ res, inserted }));
}

test('sms_reading is an accepted consent purpose, next to email_import', () => {
  const list = purposes();
  assert.ok(list.includes('sms_reading'));
  assert.ok(list.includes('email_import'));
});

test('POST /consents records an sms_reading grant with its policy version and screen', async () => {
  const { res, inserted } = await postConsent({
    purpose: 'sms_reading',
    granted: true,
    policyVersion: '2026-11-15',
    sourceScreen: 'onboarding_sms',
  });
  assert.equal(res.code, 201);
  assert.deepEqual(res.body.consent, {
    purpose: 'sms_reading',
    granted: true,
    policy_version: '2026-11-15',
    source_screen: 'onboarding_sms',
  });
  assert.equal(inserted.length, 1);
});

test('POST /consents records an sms_reading withdrawal as its own row', async () => {
  const { res } = await postConsent({
    purpose: 'sms_reading',
    granted: false,
    policyVersion: '2026-11-15',
    sourceScreen: 'privacy_permissions',
  });
  assert.equal(res.code, 201);
  assert.equal(res.body.consent.granted, false);
});

test('POST /consents still rejects an unknown purpose', async () => {
  const { res, inserted } = await postConsent({
    purpose: 'sms_everything',
    granted: true,
    policyVersion: '2026-11-15',
  });
  assert.equal(res.code, 400);
  assert.equal(inserted.length, 0);
});
