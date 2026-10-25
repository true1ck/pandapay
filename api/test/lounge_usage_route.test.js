'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  INSERT_OWNED_LOUNGE_USAGE_SQL,
  MAX_AIRPORT_LENGTH,
  createLoungeUsagePostHandler,
  validateBody,
} = require('../src/lounge_usage_route');

const PROFILE = '10000000-0000-4000-8000-000000000001';
const CARD = '20000000-0000-4000-8000-000000000002';
const BENEFIT = '30000000-0000-4000-8000-000000000003';
const row = {
  id: '40000000-0000-4000-8000-000000000004',
  user_card_id: CARD,
  benefit_id: BENEFIT,
  used_on: '2026-10-21',
  airport: 'BLR',
  logged_manually: true,
  created_at: '2026-10-21T09:00:00.000Z',
};

function responseDouble() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
  };
}

function request(body = {}) {
  return { userId: PROFILE, body };
}

test('owned active card and matching benefit create the existing 201 contract', async () => {
  const calls = [];
  const handler = createLoungeUsagePostHandler({
    withUserClient: async (profileId, callback) => {
      assert.equal(profileId, PROFILE);
      return callback({ query: async (...args) => { calls.push(args); return { rows: [row] }; } });
    },
    logger: { error() { assert.fail('success should not log'); } },
  });
  const res = responseDouble();
  await handler(request({ userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-10-21', airport: ' BLR ' }), res);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(res.body, { loungeUsage: row });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], INSERT_OWNED_LOUNGE_USAGE_SQL);
  assert.deepEqual(calls[0][1], [PROFILE, CARD, BENEFIT, '2026-10-21', 'BLR']);
});

test('single insert query binds the caller, active wallet ownership, matching benefit product, and locks the wallet row', () => {
  assert.match(INSERT_OWNED_LOUNGE_USAGE_SQL, /uc\.profile_id\s*=\s*\$1/);
  assert.match(INSERT_OWNED_LOUNGE_USAGE_SQL, /uc\.is_archived\s*=\s*false/);
  assert.match(INSERT_OWNED_LOUNGE_USAGE_SQL, /b\.card_product_id\s*=\s*uc\.card_product_id/);
  assert.match(INSERT_OWNED_LOUNGE_USAGE_SQL, /FOR UPDATE OF uc/);
  assert.match(INSERT_OWNED_LOUNGE_USAGE_SQL, /INSERT INTO lounge_usage[\s\S]*SELECT \$1[\s\S]*FROM eligible/);
});

test('foreign cards, archived cards and card-benefit mismatches share a non-enumerating 404', async () => {
  // PostgreSQL's eligibility SELECT yields no row for each of these states;
  // the route deliberately maps the same zero-row result to one response.
  for (const deniedState of ['foreign_card', 'archived_card', 'benefit_from_another_card']) {
    const handler = createLoungeUsagePostHandler({
      withUserClient: async (_profileId, callback) => callback({ query: async () => ({ rows: [] }) }),
      logger: { error() {} },
    });
    const res = responseDouble();
    await handler(request({ userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-10-21' }), res);
    assert.equal(res.statusCode, 404, deniedState);
    assert.deepEqual(res.body, { error: 'not_found' }, deniedState);
  }
});

test('malformed identifiers, dates, and airport input are rejected before database access', async () => {
  let queries = 0;
  const handler = createLoungeUsagePostHandler({
    withUserClient: async (_profileId, callback) => callback({ query: async () => { queries += 1; return { rows: [row] }; } }),
    logger: { error() {} },
  });
  const invalidBodies = [
    { userCardId: 'not-a-uuid', benefitId: BENEFIT },
    { userCardId: CARD, benefitId: 'not-a-uuid' },
    { userCardId: CARD, benefitId: BENEFIT, usedOn: 'not-a-date' },
    { userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-02-30' },
    { userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-02-30T12:00:00Z' },
    { userCardId: CARD, benefitId: BENEFIT, usedOn: '9'.repeat(41) },
    { userCardId: CARD, benefitId: BENEFIT, airport: 'x'.repeat(MAX_AIRPORT_LENGTH + 1) },
    { userCardId: CARD, benefitId: BENEFIT, airport: 'BLR\nmalicious' },
    { userCardId: CARD, benefitId: BENEFIT, airport: 42 },
  ];
  for (const body of invalidBodies) {
    const res = responseDouble();
    await handler(request(body), res);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.body, { error: 'invalid_request' });
  }
  assert.equal(queries, 0);
});

test('date-only and prior ISO timestamp client input normalize to the existing date value', () => {
  assert.equal(validateBody({ userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-10-21' }).usedOn, '2026-10-21');
  assert.equal(validateBody({ userCardId: CARD, benefitId: BENEFIT, usedOn: '2026-10-21T12:30:00.000Z' }).usedOn, '2026-10-21');
});

test('database failures return the stable API error and do not log exception contents', async () => {
  const logged = [];
  const handler = createLoungeUsagePostHandler({
    withUserClient: async () => { throw new Error('secret-token SQL values'); },
    logger: { error(...args) { logged.push(args); } },
  });
  const res = responseDouble();
  await handler(request({ userCardId: CARD, benefitId: BENEFIT }), res);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.body, { error: 'internal_error' });
  assert.deepEqual(logged, [['POST /lounge-usage failed']]);
});

