'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createCardOverridesPostHandler } = require('../src/card_overrides_write');

const U = '11111111-1111-4111-8111-111111111111';
const OID = '44444444-4444-4444-8444-444444444444';
const CARD = '55555555-5555-4555-8555-555555555555';
const CAT = '66666666-6666-4666-8666-666666666666';

function harness({ foreignIds = [], cardOwned = true, insertError = null } = {}) {
  const overrides = [];
  const client = {
    async query(sql, params) {
      if (/FROM card_overrides WHERE id/.test(sql)) {
        return { rows: overrides.filter((o) => o.id === params[0] && o.profile_id === params[1]) };
      }
      if (/FROM user_cards/.test(sql)) return { rows: cardOwned ? [{ id: CARD }] : [] };
      if (/INSERT INTO card_overrides/.test(sql)) {
        if (insertError) throw insertError;
        const id = /, id\)/.test(sql) ? params[7] : 'gen';
        if (foreignIds.includes(id)) return { rows: [] }; // ON CONFLICT DO NOTHING
        const row = { id, profile_id: params[0], user_card_id: params[1], scope: params[2], reason_note: params[6] };
        overrides.push(row);
        return { rows: [row] };
      }
      throw new Error('unscripted: ' + sql);
    },
  };
  const handler = createCardOverridesPostHandler({ withUserClient: (_u, fn) => fn(client), safeErrorCode: () => 'x' });
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
      set() {},
    };
    await handler({ userId: U, body }, res);
    return out;
  };
  return { call, overrides };
}
const body = { userCardId: CARD, scope: 'category', categoryId: CAT, id: OID };

test('replay same id: 200 replayed, one row, newer edit never overwritten', async () => {
  const h = harness();
  assert.equal((await h.call({ ...body, reasonNote: 'a' })).status, 201);
  h.overrides[0].reason_note = 'newer edit';
  const r = await h.call({ ...body, reasonNote: 'a' });
  assert.equal(r.status, 200);
  assert.equal(r.body.replayed, true);
  assert.equal(r.body.override.reason_note, 'newer edit');
  assert.equal(h.overrides.length, 1);
});

test('foreign id is 409 id_conflict', async () => {
  const h = harness({ foreignIds: [OID] });
  assert.deepEqual((await h.call(body)).body, { error: 'id_conflict' });
});

test('validation: pairing, ids, ownership, missing category', async () => {
  const h = harness();
  assert.equal((await h.call({ ...body, categoryId: undefined })).status, 400);
  assert.equal((await h.call({ ...body, id: 'x' })).status, 400);
  assert.equal((await harness({ cardOwned: false }).call(body)).status, 404);
  const fk = harness({ insertError: Object.assign(new Error('fk'), { code: '23503' }) });
  assert.equal((await fk.call(body)).status, 409);
});

test('no id: plain 201 insert as before', async () => {
  const h = harness();
  const r = await h.call({ userCardId: CARD, scope: 'vpa', vpa: 'a@b' });
  assert.equal(r.status, 201);
  assert.equal(r.body.override.id, 'gen');
});
