'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const pm = require('../src/payment_methods');

const repoRoot = path.join(__dirname, '..', '..');
const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
const fixture = JSON.parse(read('app/test/fixtures/payment_methods_v1.json'));
const indexSource = read('api/src/index.js');

// ---- contract: the JS catalogue equals the frozen fixture -------------------

test('payment_methods.js matches the frozen payment_methods_v1 fixture exactly', () => {
  assert.equal(fixture.contractId, 'transaction-payment-methods');
  assert.equal(fixture.version, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(pm.PAYMENT_METHODS)), fixture.methods);
  assert.deepEqual([...pm.PAYMENT_METHOD_GROUPS], fixture.groups);
  assert.deepEqual([...pm.PAYMENT_METHOD_INSTRUMENTS], fixture.instruments);
  assert.deepEqual([...pm.PAYMENT_METHOD_WIRES], fixture.methods.map((m) => m.wire));
});

test('every catalogue method uses a declared group and declared instruments only', () => {
  for (const method of pm.PAYMENT_METHODS) {
    assert.ok(pm.PAYMENT_METHOD_GROUPS.includes(method.group), method.wire);
    assert.ok(method.instruments.length > 0, method.wire);
    for (const instrument of method.instruments) {
      assert.ok(pm.PAYMENT_METHOD_INSTRUMENTS.includes(instrument), `${method.wire}:${instrument}`);
    }
  }
});

test('the instrument list in the API is the unchanged six values of the fixture', () => {
  const declared = indexSource.match(/const TXN_INSTRUMENTS = \[([^\]]*)\]/);
  assert.ok(declared, 'TXN_INSTRUMENTS missing');
  const values = [...declared[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(values, fixture.instruments);
});

test('the migration CHECK allows exactly the fixture wire values', () => {
  const dir = path.join(repoRoot, 'db', 'supabase', 'migrations');
  const file = fs.readdirSync(dir).find((name) => name.endsWith('_widen_transaction_payment_method.sql'));
  assert.ok(file, 'widen_transaction_payment_method migration missing');
  const sql = fs.readFileSync(path.join(dir, file), 'utf8');
  const list = sql.match(/payment_method in \(([\s\S]*?)\)/i);
  assert.ok(list, 'CHECK list missing');
  const values = [...list[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual([...values].sort(), fixture.methods.map((m) => m.wire).sort());
  assert.match(sql, /not valid/i);
  // Validation lives in its own file (the runner wraps each file in one
  // transaction, so validating here would hold the lock through the scan).
  assert.doesNotMatch(sql.replace(/^--.*$/gm, ''), /validate\s+constraint/i);
  const validateFile = fs.readdirSync(dir).find((name) => name.endsWith('_validate_transaction_payment_method.sql'));
  assert.ok(validateFile, 'validate_transaction_payment_method migration missing');
  assert.ok(validateFile > file, 'validation must sort after the constraint is added');
  assert.match(
    fs.readFileSync(path.join(dir, validateFile), 'utf8'),
    /validate\s+constraint\s+transactions_payment_method_wire_check/i,
  );
  assert.match(sql, /pg_constraint/i);
  // Sorts after the migration that created the column.
  assert.ok(file > '20261115030000_transaction_payment_method.sql');
  // Never rewrites rows.
  assert.doesNotMatch(sql, /\b(update|delete)\s+(from\s+)?(public\.)?transactions\b/i);
});

// ---- validators --------------------------------------------------------------

test('isValidPaymentMethod accepts exactly the wire values', () => {
  for (const method of fixture.methods) assert.equal(pm.isValidPaymentMethod(method.wire), true, method.wire);
  for (const bad of ['', ' cheque', 'Cheque', 'CHEQUE', 'cash', 'check', 'credit_card', null, undefined, 1, {}, []]) {
    assert.equal(pm.isValidPaymentMethod(bad), false, String(bad));
  }
});

test('isMethodCompatibleWithInstrument follows the fixture table', () => {
  for (const method of fixture.methods) {
    for (const instrument of fixture.instruments) {
      assert.equal(
        pm.isMethodCompatibleWithInstrument(method.wire, instrument),
        method.instruments.includes(instrument),
        `${method.wire} on ${instrument}`,
      );
    }
  }
  // Cheque is a bank-account payment, never cash or a card.
  assert.equal(pm.isMethodCompatibleWithInstrument('cheque', 'upi_bank'), true);
  assert.equal(pm.isMethodCompatibleWithInstrument('cheque', 'cash'), false);
  assert.equal(pm.isMethodCompatibleWithInstrument('cheque', 'credit_card'), false);
  // Cash accepts no method; a null method is always fine; unknowns are not.
  for (const method of fixture.methods) assert.equal(pm.isMethodCompatibleWithInstrument(method.wire, 'cash'), false);
  assert.equal(pm.isMethodCompatibleWithInstrument(null, 'cash'), true);
  assert.equal(pm.isMethodCompatibleWithInstrument(undefined, 'upi_bank'), true);
  assert.equal(pm.isMethodCompatibleWithInstrument('cheque', 'bogus'), false);
  assert.equal(pm.isMethodCompatibleWithInstrument('bogus', 'upi_bank'), false);
});

test('rtgs minimum is data in the fixture, not enforced by the API', () => {
  assert.equal(fixture.methods.find((m) => m.wire === 'rtgs').minAmountInr, 200000);
  assert.equal(pm.isMethodCompatibleWithInstrument('rtgs', 'upi_bank'), true);
});

test('normalisePaymentMethodInput distinguishes absent, null and values', () => {
  assert.deepEqual(pm.normalisePaymentMethodInput(undefined), { provided: false });
  assert.deepEqual(pm.normalisePaymentMethodInput(null), { provided: true, value: null });
  assert.deepEqual(pm.normalisePaymentMethodInput('neft'), { provided: true, value: 'neft' });
  for (const bad of ['', 'NEFT', ' neft', 'wire', 5, true, {}, []]) {
    assert.ok(pm.normalisePaymentMethodInput(bad).error, JSON.stringify(bad));
  }
});

test('resolvePaymentMethodForCreate: absent/null store nothing, bad values 400', () => {
  assert.deepEqual(pm.resolvePaymentMethodForCreate(undefined, 'credit_card'), { value: null });
  assert.deepEqual(pm.resolvePaymentMethodForCreate(null, 'cash'), { value: null });
  assert.deepEqual(pm.resolvePaymentMethodForCreate('cheque', 'upi_bank'), { value: 'cheque' });
  assert.deepEqual(pm.resolvePaymentMethodForCreate('emi', 'credit_card'), { value: 'emi' });
  assert.ok(pm.resolvePaymentMethodForCreate('bogus', 'upi_bank').error);
  assert.ok(pm.resolvePaymentMethodForCreate('cheque', 'cash').error);
  assert.ok(pm.resolvePaymentMethodForCreate('neft', 'credit_card').error);
  assert.ok(pm.resolvePaymentMethodForCreate('pay_later', 'upi_bank').error);
});

test('resolvePaymentMethodForPatch: keep, clear, set, and incompatible instrument changes', () => {
  // absent keeps the stored value
  assert.deepEqual(pm.resolvePaymentMethodForPatch(undefined, 'cheque', 'upi_bank'), { value: 'cheque', changed: false });
  assert.deepEqual(pm.resolvePaymentMethodForPatch(undefined, null, 'cash'), { value: null, changed: false });
  // explicit null clears
  assert.deepEqual(pm.resolvePaymentMethodForPatch(null, 'cheque', 'upi_bank'), { value: null, changed: true });
  // set / change
  assert.deepEqual(pm.resolvePaymentMethodForPatch('neft', null, 'upi_bank'), { value: 'neft', changed: true });
  assert.deepEqual(pm.resolvePaymentMethodForPatch('cheque', 'cheque', 'upi_bank'), { value: 'cheque', changed: false });
  // unknown or incompatible with the EFFECTIVE instrument -> error
  assert.ok(pm.resolvePaymentMethodForPatch('bogus', null, 'upi_bank').error);
  assert.ok(pm.resolvePaymentMethodForPatch('cheque', null, 'cash').error);
  // changing instrument away from what the stored method fits is rejected...
  assert.ok(pm.resolvePaymentMethodForPatch(undefined, 'cheque', 'cash').error);
  assert.ok(pm.resolvePaymentMethodForPatch(undefined, 'neft', 'credit_card').error);
  // ...unless the client resolves it in the same request
  assert.deepEqual(pm.resolvePaymentMethodForPatch(null, 'cheque', 'cash'), { value: null, changed: true });
  assert.deepEqual(pm.resolvePaymentMethodForPatch('emi', 'cheque', 'credit_card'), { value: 'emi', changed: true });
  // legacy 'upi' (SMS v2) never blocks an older client's instrument edit
  assert.deepEqual(pm.resolvePaymentMethodForPatch(undefined, 'upi', 'cash'), { value: 'upi', changed: false });
  assert.deepEqual(pm.resolvePaymentMethodForPatch(undefined, 'upi', 'wallet'), { value: 'upi', changed: false });
});

// ---- route wiring (handler source evaluated against fakes, like duplicate_resolution.test.js) ----

const TXN_ID = '00000000-0000-4000-8000-000000000001';
const PROFILE = '00000000-0000-4000-8000-0000000000aa';

function fakeRes() {
  return {
    code: 200,
    body: undefined,
    status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

function loadPostHandler({ insertResult }) {
  const start = indexSource.indexOf('const TXN_INSTRUMENTS');
  const end = indexSource.indexOf('registerBillsProjectionRoutes(app', start);
  assert.ok(start >= 0 && end > start);
  const routes = {};
  const app = { post: (route, ...handlers) => { routes[route] = handlers[handlers.length - 1]; } };
  const calls = [];
  const client = {
    async query(sql, params) {
      calls.push({ sql: String(sql), params });
      if (/UPDATE transactions SET payment_method/.test(sql)) return { rows: [{ payment_method: params[0] }], rowCount: 1 };
      return { rows: [], rowCount: 0 };
    },
  };
  const inserts = [];
  const register = new Function(
    'app', 'requireAuth', 'withUserClient', 'importResolvers', 'insertTransactionAndUpdateState',
    'clientMutationSourceKey', 'paymentMethods', 'safeErrorCode', 'registerBillsProjectionRoutes',
    `${indexSource.slice(start, end)}\n;`,
  );
  register(
    app, () => {}, async (_userId, fn) => fn(client),
    {
      resolveCategoryAssignmentForImport: async () => ({ categoryId: null, userCategoryId: null }),
      userCardMatchesInstrument: async () => true,
    },
    async (_client, _userId, args) => { inserts.push(args); return insertResult(args); },
    () => 'key', pm, () => 'err', () => {},
  );
  return { handler: routes['/transactions'], calls, inserts };
}

async function post(harness, body) {
  const res = fakeRes();
  await harness.handler({ userId: PROFILE, body }, res);
  return res;
}

const created = (args) => ({
  status: 201,
  transaction: { id: TXN_ID, instrument: args.instrument, entry_kind: args.entryKind },
});

test('POST /transactions persists a valid paymentMethod and returns it', async () => {
  const h = loadPostHandler({ insertResult: created });
  const res = await post(h, { amountInr: 5000, instrument: 'upi_bank', paymentMethod: 'cheque' });
  assert.equal(res.code, 201);
  assert.equal(res.body.transaction.payment_method, 'cheque');
  const write = h.calls.find((c) => /SET payment_method/.test(c.sql));
  assert.deepEqual(write.params, ['cheque', TXN_ID, PROFILE]);
  // The shared insert helper receives no new field and the same instrument.
  assert.equal(h.inserts.length, 1);
  assert.equal(h.inserts[0].instrument, 'upi_bank');
  assert.equal('paymentMethod' in h.inserts[0], false);
});

test('POST /transactions without paymentMethod (or with null) behaves as before', async () => {
  for (const body of [
    { amountInr: 99, instrument: 'cash' },
    { amountInr: 99, instrument: 'cash', paymentMethod: null },
  ]) {
    const h = loadPostHandler({ insertResult: created });
    const res = await post(h, body);
    assert.equal(res.code, 201);
    assert.equal(h.calls.some((c) => /payment_method/.test(c.sql)), false);
    assert.equal('payment_method' in res.body.transaction, false);
  }
});

test('POST /transactions rejects unknown and incompatible paymentMethod before touching the database', async () => {
  for (const body of [
    { amountInr: 10, instrument: 'upi_bank', paymentMethod: 'bogus' },
    { amountInr: 10, instrument: 'upi_bank', paymentMethod: '' },
    { amountInr: 10, instrument: 'upi_bank', paymentMethod: 7 },
    { amountInr: 10, instrument: 'cash', paymentMethod: 'cheque' },
    { amountInr: 10, instrument: 'upi_bank', paymentMethod: 'pay_later' },
    { amountInr: 10, userCardId: 'c', paymentMethod: 'neft' }, // default instrument credit_card
  ]) {
    const h = loadPostHandler({ insertResult: created });
    const res = await post(h, body);
    assert.equal(res.code, 400, JSON.stringify(body));
    assert.match(res.body.error, /paymentMethod/);
    assert.equal(h.calls.length, 0);
    assert.equal(h.inserts.length, 0);
  }
});

test('POST /transactions does not stamp the method onto a duplicate or retried row', async () => {
  const h = loadPostHandler({
    insertResult: () => ({ status: 200, duplicate: true, duplicateKind: 'exact_retry', transaction: { id: TXN_ID } }),
  });
  const res = await post(h, { amountInr: 10, instrument: 'upi_bank', paymentMethod: 'neft' });
  assert.equal(res.code, 200);
  assert.equal(h.calls.some((c) => /SET payment_method/.test(c.sql)), false);
});

function loadPatchHandler(row) {
  const start = indexSource.indexOf("app.patch('/transactions/:id'");
  const end = indexSource.indexOf('const BULK_CATEGORY_MAX_ROWS', start);
  assert.ok(start >= 0 && end > start);
  const routes = {};
  const app = { patch: (route, ...handlers) => { routes[route] = handlers[handlers.length - 1]; } };
  const calls = [];
  const client = {
    async query(sql, params) {
      const text = String(sql);
      calls.push({ sql: text, params });
      if (/FROM transactions WHERE id = \$1 AND profile_id = \$2 FOR UPDATE/.test(text)) {
        return { rows: [row], rowCount: 1 };
      }
      if (/^\s*UPDATE transactions\s+SET user_card_id/.test(text)) {
        return {
          rows: [{
            id: row.id, instrument: params[7], entry_kind: params[8], status: 'active',
            payment_method: params[10],
          }],
          rowCount: 1,
        };
      }
      return { rows: [], rowCount: 0 };
    },
  };
  const register = new Function(
    'app', 'requireAuth', 'withUserClient', 'selfTransfers', 'loadUserCardForState', 'reverseTransactionState',
    'applyTransactionState', 'importResolvers', 'TXN_INSTRUMENTS', 'TXN_ENTRY_KINDS', 'paymentMethods', 'safeErrorCode',
    `${indexSource.slice(start, end)}\n;`,
  );
  register(
    app, () => {}, async (_userId, fn) => fn(client), {}, async () => null, async () => {}, async () => ({}),
    { userCardMatchesInstrument: async () => true },
    ['credit_card', 'debit_card', 'cash', 'upi_bank', 'wallet', 'other'],
    ['spend', 'income', 'investment', 'transfer'],
    pm, () => 'err',
  );
  return { handler: routes['/transactions/:id'], calls };
}

const storedRow = (overrides = {}) => ({
  id: TXN_ID, user_card_id: null, amount_inr: '5000.00', occurred_at: new Date('2026-11-01T00:00:00Z'),
  category_id: null, user_category_id: null, rail: 'unknown', merchant_name: 'Landlord', status: 'active',
  instrument: 'upi_bank', entry_kind: 'spend', state_applied: true, is_backfill: false, payment_method: null,
  ...overrides,
});

async function patch(harness, body) {
  const res = fakeRes();
  await harness.handler({ userId: PROFILE, params: { id: TXN_ID }, body }, res);
  return res;
}
const updateCall = (h) => h.calls.find((c) => /^\s*UPDATE transactions\s+SET user_card_id/.test(c.sql));

test('PATCH /transactions/:id sets, changes and clears paymentMethod', async () => {
  let h = loadPatchHandler(storedRow());
  let res = await patch(h, { paymentMethod: 'cheque' });
  assert.equal(res.code, 200);
  assert.equal(res.body.transaction.payment_method, 'cheque');
  assert.equal(updateCall(h).params[7], 'upi_bank'); // instrument untouched

  h = loadPatchHandler(storedRow({ payment_method: 'cheque' }));
  res = await patch(h, { paymentMethod: null });
  assert.equal(res.code, 200);
  assert.equal(res.body.transaction.payment_method, null);
});

test('PATCH /transactions/:id keeps the stored method when the field is absent', async () => {
  const h = loadPatchHandler(storedRow({ payment_method: 'neft' }));
  const res = await patch(h, { merchantName: 'Rent' });
  assert.equal(res.code, 200);
  assert.equal(updateCall(h).params[10], 'neft');
  assert.equal(res.body.transaction.payment_method, 'neft');
});

test('PATCH /transactions/:id rejects unknown/incompatible values and changes nothing', async () => {
  const cases = [
    [storedRow(), { paymentMethod: 'bogus' }, false],
    [storedRow(), { paymentMethod: 'cheque', instrument: 'cash' }, true],
    [storedRow({ instrument: 'cash' }), { paymentMethod: 'neft' }, true],
    // stored cheque, instrument changes, no paymentMethod sent
    [storedRow({ payment_method: 'cheque' }), { instrument: 'cash' }, true],
  ];
  for (const [row, body, reachedDb] of cases) {
    const h = loadPatchHandler(row);
    const res = await patch(h, body);
    assert.equal(res.code, 400, JSON.stringify(body));
    assert.match(res.body.error, /paymentMethod|payment method/);
    assert.equal(updateCall(h), undefined, 'no UPDATE may run');
    // Rejected before any card-state reversal or write (the transaction commits whatever the handler returns).
    assert.equal(h.calls.filter((c) => /^\s*(UPDATE|INSERT|DELETE)\b/i.test(c.sql)).length, 0);
    if (!reachedDb) assert.equal(h.calls.length, 0);
  }
});

test('PATCH /transactions/:id lets an instrument change carry paymentMethod null, and legacy upi stays editable', async () => {
  let h = loadPatchHandler(storedRow({ payment_method: 'cheque' }));
  let res = await patch(h, { instrument: 'cash', paymentMethod: null });
  assert.equal(res.code, 200);
  assert.equal(res.body.transaction.instrument, 'cash');
  assert.equal(res.body.transaction.payment_method, null);

  // An older client edits an SMS 'upi' row's instrument without knowing about paymentMethod.
  h = loadPatchHandler(storedRow({ payment_method: 'upi' }));
  res = await patch(h, { instrument: 'cash' });
  assert.equal(res.code, 200);
  assert.equal(res.body.transaction.payment_method, 'upi');
});

test('the transaction list and detail queries already return payment_method', () => {
  const selects = indexSource.match(/t\.rail, t\.payment_method, t\.status, t\.source, t\.note/g) || [];
  assert.ok(selects.length >= 2, 'GET /transactions list and detail select payment_method');
});
