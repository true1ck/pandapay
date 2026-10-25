'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  SUPPORT_TICKET_KINDS,
  SUPPORT_TICKET_MAX_MESSAGE_LENGTH,
  SUPPORT_TICKET_METADATA_SQL,
  INSERT_SUPPORT_TICKET_SQL,
  validateSupportTicketPayload,
  createSupportTicketRateLimiter,
  createSupportTicketHandler,
  registerSupportTicketRoute,
} = require('../src/support_tickets');

function responseDouble() {
  return {
    statusCode: 200,
    headers: {},
    body: null,
    status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('support ticket kinds preserve the existing four-value API contract', () => {
  assert.deepEqual(SUPPORT_TICKET_KINDS, ['bug', 'wrong_card_data', 'card_request', 'general']);
});

test('support ticket payload rejects malformed, oversized, nested, and unbounded fields', () => {
  assert.equal(validateSupportTicketPayload(null).error, 'invalid_request');
  assert.equal(validateSupportTicketPayload({ kind: 'invalid', message: 'Hello' }).ok, false);
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: '   ' }).error, 'message is required');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'x'.repeat(SUPPORT_TICKET_MAX_MESSAGE_LENGTH + 1) }).error, 'message_too_long');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'bad\u0000value' }).error, 'invalid_message');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', diagnostics: [] }).error, 'invalid_diagnostics');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', diagnostics: { nested: { value: 1 } } }).error, 'invalid_diagnostics');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', diagnostics: { text: 'x'.repeat(513) } }).error, 'invalid_diagnostics');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', diagnostics: Object.fromEntries(Array.from({ length: 25 }, (_, i) => [`field${i}`, i])) }).error, 'invalid_diagnostics');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', diagnostics: Object.fromEntries(Array.from({ length: 24 }, (_, i) => [`field${i}`, 'x'.repeat(256)])) }).error, 'invalid_diagnostics');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', appVersion: 'x'.repeat(65) }).error, 'invalid_app_version');
  assert.equal(validateSupportTicketPayload({ kind: 'general', message: 'valid', appVersion: 'bad\u0000value' }).error, 'invalid_app_version');
});

test('support ticket payload accepts current flat mobile diagnostics and trims bounded text', () => {
  const parsed = validateSupportTicketPayload({
    kind: 'wrong_card_data',
    message: '  The reward rate looks wrong.  ',
    diagnostics: { transactionId: 'txn-42', merchant: 'Coffee shop', amountInr: 120, category: null },
    appVersion: '  1.2.3+4  ',
  });
  assert.equal(parsed.ok, true);
  assert.deepEqual(parsed.value, {
    kind: 'wrong_card_data',
    message: 'The reward rate looks wrong.',
    diagnostics: { transactionId: 'txn-42', merchant: 'Coffee shop', amountInr: 120, category: null },
    appVersion: '1.2.3+4',
  });
});

test('registered route preserves optional authentication and inserts a signed-out ticket with bounded parameters', async () => {
  let route;
  const app = { post(...args) { route = args; } };
  const optionalAuth = (_req, _res, next) => next();
  const inserts = [];
  registerSupportTicketRoute(app, {
    optionalAuth,
    withUserClient: async (userId, callback) => callback({
      query: async (sql, params) => {
        if (sql === SUPPORT_TICKET_METADATA_SQL) return { rows: [{ id: 'ticket-1', created_at: 'now' }] };
        inserts.push({ userId, sql, params });
        return { rows: [], rowCount: 1 };
      },
    }),
    limiter: createSupportTicketRateLimiter({ anonymousLimit: 4 }),
  });

  assert.equal(route[0], '/support-tickets');
  assert.equal(route[1], optionalAuth);
  const req = {
    userId: null,
    ip: '203.0.113.9',
    body: {
      kind: 'general', message: '  OTP is not arriving  ',
      diagnostics: { platform: 'android', appVersion: '2.0.0' }, appVersion: '2.0.0',
    },
  };
  const res = responseDouble();
  await route[2](req, res);

  assert.equal(res.statusCode, 201);
  assert.equal(res.body.ticket.id, 'ticket-1');
  assert.equal(inserts.length, 1);
  assert.equal(inserts[0].userId, null);
  assert.equal(inserts[0].sql, INSERT_SUPPORT_TICKET_SQL);
  assert.deepEqual(inserts[0].params, ['ticket-1', null, 'general', 'OTP is not arriving', '{"platform":"android","appVersion":"2.0.0"}', '2.0.0']);
});

test('handler rejects invalid payloads before database access and rate-limits account or IP identity', async () => {
  let now = 1_000;
  let writes = 0;
  const limiter = createSupportTicketRateLimiter({ now: () => now, windowMs: 60_000, authenticatedLimit: 1, anonymousLimit: 1 });
  const handler = createSupportTicketHandler({
    limiter,
    withUserClient: async (_userId, callback) => callback({ query: async (sql) => {
      if (sql === SUPPORT_TICKET_METADATA_SQL) return { rows: [{ id: 'ticket', created_at: 'now' }] };
      writes += 1;
      return { rows: [], rowCount: 1 };
    } }),
  });

  const invalid = responseDouble();
  await handler({ body: { kind: 'bug', message: '' }, ip: '198.51.100.7' }, invalid);
  assert.equal(invalid.statusCode, 400);
  assert.equal(writes, 0);

  const first = responseDouble();
  await handler({ userId: 'profile-1', ip: '198.51.100.7', body: { kind: 'bug', message: 'works' } }, first);
  assert.equal(first.statusCode, 201);

  const limitedAccount = responseDouble();
  await handler({ userId: 'profile-1', ip: '198.51.100.8', body: { kind: 'bug', message: 'again' } }, limitedAccount);
  assert.equal(limitedAccount.statusCode, 429);
  assert.equal(limitedAccount.body.error, 'support_ticket_rate_limited');
  assert.equal(limitedAccount.headers['Retry-After'], '60');

  const independentAccount = responseDouble();
  await handler({ userId: 'profile-2', ip: '198.51.100.7', body: { kind: 'bug', message: 'other account' } }, independentAccount);
  assert.equal(independentAccount.statusCode, 201);

  const anonymousFirst = responseDouble();
  await handler({ userId: null, ip: '198.51.100.9', body: { kind: 'general', message: 'signed out' } }, anonymousFirst);
  assert.equal(anonymousFirst.statusCode, 201);
  const anonymousLimited = responseDouble();
  await handler({ userId: null, ip: '198.51.100.9', body: { kind: 'general', message: 'signed out again' } }, anonymousLimited);
  assert.equal(anonymousLimited.statusCode, 429);
  assert.equal(writes, 3);

  now += 60_001;
  const afterWindow = responseDouble();
  await handler({ userId: 'profile-1', ip: '198.51.100.8', body: { kind: 'bug', message: 'retry' } }, afterWindow);
  assert.equal(afterWindow.statusCode, 201);

  let boundedNow = 0;
  const bounded = createSupportTicketRateLimiter({ now: () => boundedNow, windowMs: 1000, maxEntries: 1 });
  assert.equal(bounded.consume('first-ip', false).allowed, true);
  assert.equal(bounded.consume('second-ip', false).allowed, false);
  boundedNow = 1001;
  assert.equal(bounded.consume('second-ip', false).allowed, true);
});
