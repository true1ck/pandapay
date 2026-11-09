const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
const svc = require('../src/services/recoveryEmail');
const { RecoveryEmailError } = svc;

const SECRET = 'recovery-email-test-secret-0123456789';
const jwtApi = { sign: (claims, ttl) => jwt.sign(claims, SECRET, { expiresIn: ttl }), verify: token => jwt.verify(token, SECRET) };

function world(users = {}) {
  const db = new Map(Object.entries({
    me: { id: 'me', email: 'me@gmail.com', email_canonical: 'me@gmail.com', is_email_verified: true, recovery_email: null, recovery_email_added_at: null },
    ...users,
  }));
  const state = { codes: [], mail: [], notices: [], otpCalls: [], discarded: 0, updates: [] };
  let counter = 0;
  const query = async (sql, args = []) => {
    if (sql.includes('FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE')) {
      const u = db.get(args[0]); return { rows: u && !u.deleted && u.is_active !== false ? [{ ...u }] : [] };
    }
    if (sql.includes('SELECT recovery_email, recovery_email_added_at FROM users')) {
      const u = db.get(args[0]); return { rows: u ? [{ ...u }] : [] };
    }
    if (sql.includes('email_canonical = $1 AND deleted = FALSE AND id <> $2')) {
      const hit = [...db.values()].find(u => u.id !== args[1] && !u.deleted && u.email_canonical === args[0]);
      return { rows: hit ? [{ '?column?': 1 }] : [] };
    }
    if (sql.includes('SET recovery_email = $2')) {
      const u = db.get(args[0]);
      if (state.checkViolation) throw Object.assign(new Error('chk_users_recovery_email_differs'), { code: '23514' });
      u.recovery_email = args[1]; u.recovery_email_added_at = new Date(); state.updates.push(args[1]);
      return { rows: [{ id: u.id }] };
    }
    if (sql.includes('SET recovery_email = NULL')) {
      const u = db.get(args[0]); if (!u.recovery_email) return { rows: [] };
      u.recovery_email = null; u.recovery_email_added_at = null; return { rows: [{ id: u.id }] };
    }
    throw new Error(`Unexpected SQL: ${sql.slice(0, 60)}`);
  };
  const otp = {
    async createOtpV2(identifier, type, purpose, deviceId) {
      counter++; const code = String(100000 + counter); const requestId = `00000000-0000-4000-8000-00000000000${counter}`;
      state.codes.push({ identifier, code, requestId, purpose, deviceId }); return { code, requestId };
    },
    async discardUndeliveredOtpV2() { state.discarded++; },
    async verifyOtpV2(identifier, code, type, purpose, deviceId, requestId) {
      state.otpCalls.push({ identifier, code, requestId });
      const row = state.codes.find(c => c.identifier === identifier);
      return { ok: Boolean(row) && row.code === code && row.requestId === requestId && row.deviceId === deviceId && !row.used && (row.used = true) };
    },
  };
  const mail = {
    async sendOtpEmail(to, code, options) { state.mail.push({ to, code, purpose: options.purpose }); return state.mailResult ? state.mailResult(to) : { success: true }; },
    async sendSecurityNotice(n) { state.notices.push(n); if (state.noticeThrows) throw new Error('smtp down'); return { success: true }; },
  };
  return { db, state, query, otp, mail };
}

const base = (w, extra = {}) => ({ query: w.query, userId: 'me', deviceId: 'device-1', otp: w.otp, mail: w.mail, jwtApi, ttlSeconds: 60, ...extra });

async function start(w, email = 'backup@outlook.com') { return svc.startChange({ ...base(w), email }); }
function codesOf(w) {
  const toSignIn = w.state.mail.find(m => m.purpose === 'recovery-email-signin');
  const toNew = w.state.mail.find(m => m.purpose === 'recovery-email-new');
  return { signIn: toSignIn, fresh: toNew };
}

test('step one sends one code to the sign-in email and one to the new address, and signs a challenge', async () => {
  const w = world();
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  assert.equal(signIn.to, 'me@gmail.com');
  assert.equal(fresh.to, 'backup@outlook.com');
  assert.notEqual(signIn.code, fresh.code);
  assert.equal(r.contact_hint, 'b•••@outlook.com');
  assert.equal(r.expires_in, 60);
  const claims = jwt.verify(r.challenge, SECRET);
  assert.equal(claims.sub, 'me');
  assert.equal(claims.value, 'backup@outlook.com');
  assert.equal(claims.device_binding_hash, svc.deviceHash('device-1'));
  assert.doesNotMatch(JSON.stringify(claims), /11000\d/, 'the codes are never in the challenge');
  assert.deepEqual(w.state.codes.map(c => c.purpose), ['replacement', 'replacement']);
});

test('step two with both right codes saves it at once and tells the sign-in email', async () => {
  const w = world();
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  const done = await svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code });
  assert.deepEqual(done, { recovery_email_hint: 'b•••@outlook.com' });
  assert.equal(w.db.get('me').recovery_email, 'backup@outlook.com');
  assert.equal(w.state.notices.length, 1);
  assert.equal(w.state.notices[0].to, 'me@gmail.com');
  assert.match(w.state.notices[0].text, /b•••@outlook\.com/);
  assert.doesNotMatch(w.state.notices[0].text, /backup@outlook\.com/, 'the notice carries the masked address only');
  assert.deepEqual(await svc.getStatus({ query: w.query, userId: 'me' }),
    { has_recovery_email: true, recovery_email_hint: 'b•••@outlook.com', added_at: w.db.get('me').recovery_email_added_at });
});

test('either code being wrong saves nothing', async () => {
  for (const [swap, label] of [[(s, f) => ['000000', f], 'wrong sign-in code'], [(s, f) => [s, '000000'], 'wrong recovery code']]) {
    const w = world();
    const r = await start(w);
    const { signIn, fresh } = codesOf(w);
    const [a, b] = swap(signIn.code, fresh.code);
    await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: a, newCode: b }),
      e => e instanceof RecoveryEmailError && e.code === 'code_invalid' && e.status === 400, label);
    assert.equal(w.db.get('me').recovery_email, null, label);
    assert.equal(w.state.notices.length, 0, label);
  }
});

test('the codes only work for the person and device that asked', async () => {
  const w = world({ other: { id: 'other', email: 'other@gmail.com', email_canonical: 'other@gmail.com', is_email_verified: true } });
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  await assert.rejects(svc.finishChange({ ...base(w, { deviceId: 'device-2' }), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code }),
    e => e.code === 'challenge_invalid');
  await assert.rejects(svc.finishChange({ ...base(w, { userId: 'other' }), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code }),
    e => e.code === 'challenge_invalid');
  await assert.rejects(svc.finishChange({ ...base(w), challenge: 'garbage', signInCode: '111111', newCode: '222222' }), e => e.code === 'challenge_invalid');
  const tampered = jwt.sign({ sub: 'me', value: 'thief@outlook.com', a: {}, b: {} }, 'wrong-secret');
  await assert.rejects(svc.finishChange({ ...base(w), challenge: tampered, signInCode: '111111', newCode: '222222' }), e => e.code === 'challenge_invalid');
  assert.equal(w.db.get('me').recovery_email, null);
});

test('addresses that cannot be a recovery email are refused before any email is sent', async () => {
  const cases = [
    ['not-an-email', 'email_invalid'], ['', 'email_invalid'], [42, 'email_invalid'],
    ['x@mailinator.com', 'email_not_allowed'],
    ['me@gmail.com', 'same_as_sign_in'], ['M.E+promo@googlemail.com', 'same_as_sign_in'],
    ['taken@yahoo.com', 'email_unavailable'],
  ];
  for (const [typed, code] of cases) {
    const w = world({ taken: { id: 'taken', email: 'taken@yahoo.com', email_canonical: 'taken@yahoo.com', is_email_verified: true } });
    await assert.rejects(start(w, typed), e => e instanceof RecoveryEmailError && e.code === code, `${typed} -> ${code}`);
    assert.equal(w.state.mail.length, 0, `${typed}: nothing is sent`);
    assert.equal(w.state.codes.length, 0, `${typed}: no code is created`);
  }
});

test('an account with no verified sign-in email cannot add one, and a missing account is refused', async () => {
  const w = world({ legacy: { id: 'legacy', email: null, email_canonical: null, is_email_verified: false } });
  await assert.rejects(svc.startChange({ ...base(w, { userId: 'legacy' }), email: 'x@outlook.com' }), e => e.code === 'sign_in_email_required' && e.status === 409);
  await assert.rejects(svc.startChange({ ...base(w, { userId: 'ghost' }), email: 'x@outlook.com' }), e => e.code === 'account_unavailable' && e.status === 401);
});

test('if either email cannot be delivered both codes are discarded and the person is told', async () => {
  const w = world();
  w.state.mailResult = to => ({ success: to !== 'backup@outlook.com' });
  await assert.rejects(start(w), e => e.code === 'delivery_failed' && e.status === 503);
  assert.equal(w.state.discarded, 2);
  const w2 = world();
  w2.mail.sendOtpEmail = async () => { throw new Error('smtp'); };
  await assert.rejects(start(w2), e => e.code === 'delivery_failed');
  assert.equal(w2.state.discarded, 2);
});

test('a mailbox taken between the two steps is refused at the end, and a database check refusal is the same answer', async () => {
  const w = world();
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  w.db.set('late', { id: 'late', email: 'Backup@Outlook.com', email_canonical: 'backup@outlook.com', is_email_verified: true });
  await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code }), e => e.code === 'email_unavailable');
  const w2 = world();
  const r2 = await start(w2);
  const c2 = codesOf(w2);
  w2.state.checkViolation = true;
  await assert.rejects(svc.finishChange({ ...base(w2), challenge: r2.challenge, signInCode: c2.signIn.code, newCode: c2.fresh.code }), e => e.code === 'same_as_sign_in');
});

test('a codes pair can be used once', async () => {
  const w = world();
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  await svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code });
  await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code }), e => e.code === 'code_invalid');
});

test('a failing notice never undoes the change', async () => {
  const w = world();
  w.state.noticeThrows = true;
  const r = await start(w);
  const { signIn, fresh } = codesOf(w);
  await svc.finishChange({ ...base(w), challenge: r.challenge, signInCode: signIn.code, newCode: fresh.code });
  assert.equal(w.db.get('me').recovery_email, 'backup@outlook.com');
});

test('removing the recovery email clears it and tells the sign-in email; removing nothing is refused', async () => {
  const w = world({ me: { id: 'me', email: 'me@gmail.com', email_canonical: 'me@gmail.com', is_email_verified: true, recovery_email: 'old@outlook.com', recovery_email_added_at: new Date() } });
  assert.deepEqual(await svc.removeRecoveryEmail({ query: w.query, userId: 'me', mail: w.mail }), { removed: true });
  assert.equal(w.db.get('me').recovery_email, null);
  assert.equal(w.state.notices.length, 1);
  assert.match(w.state.notices[0].subject, /removed/);
  await assert.rejects(svc.removeRecoveryEmail({ query: w.query, userId: 'me', mail: w.mail }), e => e.code === 'nothing_to_remove' && e.status === 404);
});
