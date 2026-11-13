'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createUserCardsAddHandler } = require('../src/user_cards_add');

const U = '11111111-1111-4111-8111-111111111111';
const CID = '22222222-2222-4222-8222-222222222222';
const PROD = '33333333-3333-4333-8333-333333333333';

// Scripted client: matches SQL fragments; keeps rows in memory.
function harness({ owned = [], failInsert = null } = {}) {
  const rows = [...owned];
  const client = {
    async query(sql, params) {
      if (/pg_advisory/.test(sql)) return { rows: [] };
      if (/FROM user_cards WHERE id = \$1 AND profile_id/.test(sql)) {
        return { rows: rows.filter((r) => r.id === params[0] && r.profile_id === params[1]) };
      }
      if (/FROM card_products/.test(sql) && /status = 'published'/.test(sql)) {
        return { rows: [{ id: PROD, issuer_id: 'i1', card_type: 'credit' }] };
      }
      if (/FROM user_cards uc/.test(sql)) {
        return {
          rows: rows
            .filter((r) => !r.is_archived)
            .map((r) => ({ ...r, card_name: 'X', issuer_id: 'i1', card_type: 'credit' })),
        };
      }
      if (/INSERT INTO user_cards/.test(sql)) {
        if (failInsert) throw failInsert;
        const row = /\(id,/.test(sql)
          ? { id: params[0], profile_id: params[1], card_product_id: params[2], nickname: params[3], last4: params[4] }
          : { id: 'gen', profile_id: params[0], card_product_id: params[1], nickname: params[2], last4: params[3] };
        rows.push(row);
        return { rows: [row] };
      }
      throw new Error('unscripted: ' + sql);
    },
  };
  let repairs = 0;
  const handler = createUserCardsAddHandler({
    withUserClient: (_u, fn) => fn(client),
    scheduleSmsRepair: () => {
      repairs += 1;
    },
    safeErrorCode: () => 'x',
  });
  const call = async (body) => {
    const out = {};
    const res = {
      status(c) {
        out.status = c;
        return this;
      },
      json(b) {
        out.body = b;
        return this;
      },
    };
    await handler({ userId: U, body }, res);
    return out;
  };
  return { call, rows, repairs: () => repairs };
}

test('same id twice: one row, second is 200 replayed with no extra side effects', async () => {
  const h = harness();
  const a = await h.call({ cardProductId: PROD, last4: '1234', id: CID });
  assert.equal(a.status, 201);
  const b = await h.call({ cardProductId: PROD, last4: '1234', id: CID.toUpperCase() });
  assert.equal(b.status, 200);
  assert.equal(b.body.replayed, true);
  assert.equal(h.rows.length, 1);
  assert.equal(h.repairs(), 1);
});

test('natural-key conflict echoes clientId', async () => {
  const h = harness({ owned: [{ id: 'old', profile_id: U, card_product_id: PROD, last4: '1234', is_archived: false }] });
  const r = await h.call({ cardProductId: PROD, last4: '1234', id: CID });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'card_already_added');
  assert.equal(r.body.userCard.id, 'old');
  assert.equal(r.body.clientId, CID);
});

test('foreign id (primary key taken) is 409 id_conflict without leaking', async () => {
  const h = harness({ failInsert: Object.assign(new Error('dup'), { code: '23505', constraint: 'user_cards_pkey' }) });
  const r = await h.call({ cardProductId: PROD, last4: '1234', id: CID });
  assert.deepEqual([r.status, r.body], [409, { error: 'id_conflict' }]);
});

test('identity unique violation with id keeps card_already_added and echoes clientId', async () => {
  const h = harness({
    failInsert: Object.assign(new Error('dup'), { code: '23505', constraint: 'uq_user_cards_active_identity' }),
  });
  const r = await h.call({ cardProductId: PROD, last4: '1234', id: CID });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'card_already_added');
  assert.equal(r.body.clientId, CID);
});

test('bad id is 400; no id path is unchanged (201, generated id, no clientId)', async () => {
  const h = harness();
  assert.equal((await h.call({ cardProductId: PROD, id: 'nope' })).status, 400);
  const r = await h.call({ cardProductId: PROD, last4: '1234' });
  assert.equal(r.status, 201);
  assert.equal(r.body.userCard.id, 'gen');
  assert.equal('clientId' in r.body, false);
  const dup = await h.call({ cardProductId: PROD, last4: '1234' });
  assert.equal(dup.status, 409);
  assert.equal('clientId' in dup.body, false);
});
