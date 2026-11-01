const test = require('node:test');
const assert = require('node:assert/strict');

const {
  cursorPredicate,
  encodeCursor,
  normalizePageRequest,
  pageInfo,
} = require('../src/transaction_paging');

const SECRET = 'transaction-paging-test-secret';
const SCOPE = 'profile-1|active|all';
const first = {
  id: '11111111-1111-4111-8111-111111111111',
  occurred_at: '2026-11-01T10:00:00.000Z',
};
const second = {
  id: '22222222-2222-4222-8222-222222222222',
  occurred_at: '2026-11-01T09:00:00.000Z',
};

test('legacy transaction requests remain unpaged', () => {
  assert.deepEqual(normalizePageRequest({}, { secret: SECRET, scope: SCOPE }), {
    paged: false,
    pageSize: null,
    cursor: null,
  });
});

test('page size is bounded and defaults for an explicit cursor request', () => {
  assert.equal(normalizePageRequest({ pageSize: '500' }, { secret: SECRET, scope: SCOPE }).pageSize, 500);
  assert.equal(normalizePageRequest({ pageSize: '501' }, { secret: SECRET, scope: SCOPE }).error, 'invalid_page_size');
  assert.equal(normalizePageRequest({ pageSize: '0' }, { secret: SECRET, scope: SCOPE }).error, 'invalid_page_size');
  assert.equal(normalizePageRequest({ cursor: encodeCursor({ occurredAt: first.occurred_at, id: first.id }, { secret: SECRET, scope: SCOPE }) }, { secret: SECRET, scope: SCOPE }).pageSize, 200);
});

test('cursor is opaque, tamper resistant, and bound to scope', () => {
  const encoded = encodeCursor({ occurredAt: first.occurred_at, id: first.id }, { secret: SECRET, scope: SCOPE });
  const parsed = normalizePageRequest({ cursor: encoded }, { secret: SECRET, scope: SCOPE });
  assert.deepEqual(parsed.cursor, { occurredAt: first.occurred_at, id: first.id });
  assert.equal(normalizePageRequest({ cursor: `${encoded}x` }, { secret: SECRET, scope: SCOPE }).error, 'invalid_cursor');
  assert.equal(normalizePageRequest({ cursor: encoded }, { secret: SECRET, scope: 'other' }).error, 'invalid_cursor');
});

test('cursor predicate uses stable occurred-at and id ordering', () => {
  const result = cursorPredicate({ occurredAt: first.occurred_at, id: first.id }, 4);
  assert.match(result.sql, /\(t\.occurred_at, t\.id\) < \(\$4::timestamptz, \$5::uuid\)/);
  assert.deepEqual(result.params, [first.occurred_at, first.id]);
});

test('page info trims the lookahead row and emits a continuation cursor', () => {
  const result = pageInfo([first, second], 1, { secret: SECRET, scope: SCOPE });
  assert.deepEqual(result.rows, [first]);
  assert.equal(result.pageInfo.hasMore, true);
  const next = normalizePageRequest({ cursor: result.pageInfo.nextCursor }, { secret: SECRET, scope: SCOPE });
  assert.deepEqual(next.cursor, { occurredAt: first.occurred_at, id: first.id });
});

test('last page has no continuation cursor', () => {
  assert.deepEqual(pageInfo([second], 2, { secret: SECRET, scope: SCOPE }), {
    rows: [second],
    pageInfo: { hasMore: false, nextCursor: null },
  });
});
