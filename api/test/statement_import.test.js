const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { validateStatementImport, createStatementImportHandler, createStatementImportAdmission, maskAccount, inferStatementEntryKind } = require('../src/statement_import');
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const cardId = '11111111-1111-4111-8111-111111111111';
const categoryId = '22222222-2222-4222-8222-222222222222';
const userCategoryId = '33333333-3333-4333-8333-333333333333';
function body(overrides = {}) {
  return { userCardId: null, statementFrom: '2026-10-02', statementTo: '2026-10-02',
    importSource: 'csv', importKey: hash('batch'), transactions: [{ amountInr: 123.45,
      occurredAt: '2026-10-01T18:30:00.000Z', merchantName: 'Coffee', importRowKey: hash('row') }], ...overrides };
}

test('statement imports reject concurrent same-account and excess work before DB use, then recover after failure', async () => {
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  let dbCalls = 0;
  const logs = [];
  const handler = createStatementImportHandler({ withUserClient: async () => {
    dbCalls++; await pending; throw Object.assign(new Error('private SQL and financial payload'), { code: '23514' });
  }, admission: createStatementImportAdmission({ maxConcurrent: 2 }), logger: { error: (...args) => logs.push(args) } });
  const response = () => ({ code: 200, headers: {}, status(code) { this.code=code;return this; },
    set(name,value) { this.headers[name]=value;return this; },json(value) { this.body=value;return this; } });
  const first=response(),other=response();
  const running=handler({userId:'one',body:body()},first);
  const duplicate=response();await handler({userId:'one',body:body()},duplicate);
  assert.equal(duplicate.code,503);assert.equal(dbCalls,1);
  const second=handler({userId:'two',body:body()},other);
  const overloaded=response();await handler({userId:'three',body:body()},overloaded);
  assert.equal(overloaded.code,503);assert.equal(overloaded.headers['Retry-After'],'5');assert.equal(dbCalls,2);
  finish();await Promise.all([running,second]);
  assert.equal(first.code,500);assert.doesNotMatch(JSON.stringify(logs),/private SQL|financial payload/);
  const retried=response();await handler({userId:'one',body:body()},retried);
  assert.equal(dbCalls,3);assert.equal(retried.code,500,'the released account can retry');
});

test('validates all file sources, accounting timezone offsets and legacy clients', () => {
  for (const importSource of ['statement', 'screenshot', 'csv', 'xlsx', 'json']) {
    assert.equal(validateStatementImport(body({ importSource })), null);
  }
  assert.equal(validateStatementImport({ userCardId: cardId, statementFrom: '2026-10-02', statementTo: '2026-10-02', txnCount: 2 }), null);
});

test('accepts each supported transaction type and rejects unknown types', () => {
  for (const entryKind of ['spend', 'income', 'investment', 'transfer']) {
    assert.equal(validateStatementImport(body({ transactions: [{ ...body().transactions[0], entryKind }] })), null);
  }
  assert.match(validateStatementImport(body({ transactions: [{ ...body().transactions[0], entryKind: 'refund-ish' }] })), /entryKind/);
});

test('rejects invalid calendar dates, ranges, decimal precision, nonfinite values and malformed rows', () => {
  for (const value of [null, [], body({ statementFrom: '2026-02-30' }), body({ statementTo: '2026-10-01' }),
    body({ transactions: [] }), body({ importSource: 'xls' }), body({ transactions: [null] }),
    body({ userCardId: 'not-a-uuid' }), body({ closingBalanceInr: Infinity })]) {
    assert.ok(validateStatementImport(value));
  }
  for (const field of ['categoryId', 'userCategoryId']) {
    const invalidCategory = body();
    invalidCategory.transactions[0][field] = 'not-a-uuid';
    assert.match(validateStatementImport(invalidCategory), new RegExp(field));
  }
  for (const amountInr of [0, -1, NaN, Infinity, '123', null, 1.001, 1.000001, 10000000000]) {
    const value = body(); value.transactions[0].amountInr = amountInr;
    assert.ok(validateStatementImport(value), `amount ${amountInr}`);
  }
  for (const occurredAt of ['2026-02-30T00:00:00Z', '2026-10-02T25:00:00Z', '2026-10-02', '2026-10-15T12:00:00Z', null]) {
    const value = body(); value.transactions[0].occurredAt = occurredAt;
    assert.ok(validateStatementImport(value), `date ${occurredAt}`);
  }
  const repeated = body(); repeated.transactions.push({ ...repeated.transactions[0] });
  assert.ok(validateStatementImport(repeated));
});

function harness({ cardType = 'credit', owned = true, automatic = false, failOnInsert = false } = {}) {
  const batches = new Map(); const rows = new Map(); const written = []; const updates = [];
  let databaseCalls = 0;
  const client = { query: async (sql, params) => {
    databaseCalls++;
    if (sql.includes('SELECT cp.card_type')) return { rows: owned ? [{ card_type: cardType }] : [] };
    if (sql.includes('FROM user_categories')) return { rows: [{ id: userCategoryId, parent_category_id: categoryId }] };
    if (sql.includes('FROM spend_categories')) return { rows: [{ id: categoryId }] };
    if (sql.includes('INSERT INTO statement_imports')) {
      if (batches.has(params[9])) return { rowCount: 0, rows: [] };
      const row = { id: `batch-${batches.size}`, txn_count: params[6], reconciled_count: params[7] };
      batches.set(params[9], row); return { rowCount: 1, rows: [row] };
    }
    if (sql.includes('SELECT * FROM statement_imports')) return { rows: [batches.get(params[1])] };
    if (sql.includes('UPDATE statement_imports')) return { rows: [{ id: params[2], txn_count: params[0], reconciled_count: params[1] }] };
    if (sql.includes('UPDATE transactions')) { updates.push(sql); return { rows: [] }; }
    throw new Error(`Unexpected SQL ${sql}`);
  } };
  const handler = createStatementImportHandler({ withUserClient: async (_, fn) => fn(client),
    importResolvers: { resolveCategoryForImport: async () => 'category' },
    clientMutationSourceKey: (user, source, key) => hash(`${user}:${source}:${key}`),
    insertTransactionAndUpdateState: async (_, user, input) => {
      if (failOnInsert) throw new Error('test database failure');
      written.push(input);
      if (automatic) return {status:200, duplicateKind:'high_confidence', transaction:{id:'canonical', status:'active'}};
      if (rows.has(input.sourceKey)) return { status: 200, duplicateKind: 'exact_retry', transaction: rows.get(input.sourceKey) };
      const transaction = { id: `row-${rows.size}`, status: input.merchantName === 'Possible duplicate' ? 'ignored' : 'active' }; rows.set(input.sourceKey, transaction);
      return { status: 201, transaction, duplicatePending: input.merchantName === 'Possible duplicate' };
    }, logger: { error() {} },
  });
  return { written, updates, get databaseCalls() { return databaseCalls; }, call: async (input) => {
    let status; let result;
    await handler({ userId: 'profile', body: input, requestId: 'import-test-123' }, { status(value) { status = value; return this; }, json(value) { result = value; return this; } });
    return { status, result };
  } };
}

test('unexpected import failures return a correlation id without leaking server details', async () => {
  const response = await harness({ failOnInsert: true }).call(body());
  assert.equal(response.status, 500);
  assert.deepEqual(response.result, {
    error: 'internal_error',
    requestId: 'import-test-123',
  });
});

test('handler blocks bad requests before any database work and checks card ownership', async () => {
  const denied = harness({ owned: false });
  assert.equal((await denied.call(body({ importKey: 'invalid' }))).status, 400);
  assert.equal(denied.databaseCalls, 0);
  assert.equal((await denied.call(body({ userCardId: cardId }))).status, 404);
  assert.equal(denied.written.length, 0);
});

test('handler routes bank/debit/credit separately, masks source account metadata and reports replay', async () => {
  for (const [userCardId, cardType, instrument] of [[null, 'credit', 'other'], [cardId, 'debit', 'debit_card'], [cardId, 'credit', 'credit_card']]) {
    const run = harness({ cardType }); const value = body({ userCardId });
    value.transactions[0].sourceAccount = 'Bank 1234567890123456';
    const first = await run.call(value);
    assert.equal(first.status, 201);
    assert.equal(run.written[0].instrument, instrument);
    assert.equal(run.written[0].backfill, true);
    assert.equal(run.written[0].observationMetadata.sourceAccount, 'Bank ****3456');
    assert.deepEqual(first.result.summary, { imported: 1, pendingDuplicates: 0, exactRetries: 0 });
    const replay = await run.call(value);
    assert.equal(replay.status, 200);
    assert.equal(replay.result.summary.exactRetries, 1);
    assert.equal(run.written.length, 1);
  }
  assert.equal(maskAccount('Bank 1234'), 'Bank 1234');
});

test('stable row keys survive different batch selections and duplicate candidates are not counted as added', async () => {
  const run = harness();
  const first = body();
  await run.call(first);
  const second = body({ importKey: hash('different selection') });
  second.transactions.push({ ...second.transactions[0], importRowKey: hash('second row'), merchantName: 'Possible duplicate' });
  const result = await run.call(second);
  assert.deepEqual(result.result.summary, { imported: 0, exactRetries: 1, pendingDuplicates: 1 });
  assert.equal(result.result.statementImport.reconciled_count, 1);
  assert.equal(run.written[0].sourceKey, run.written[1].sourceKey);
  assert.ok(run.updates.every((sql) => sql.includes("CASE WHEN status = 'active'")));
});


test('automatic duplicate is skipped without modifying the canonical transaction', async () => {
  const run = harness({automatic:true});
  const input = body(); input.transactions[0].bankReference = 'ABC123456789';
  const response = await run.call(input);
  assert.deepEqual(response.result.summary, {imported:0, pendingDuplicates:0, exactRetries:1});
  assert.equal(run.updates.length, 0);
  assert.equal(run.written[0].observationMetadata.bankReference, 'ABC123456789');
});

test('statement import forwards the transaction kind to the shared insert path', async () => {
  const run = harness();
  await run.call(body({ transactions: [{ ...body().transactions[0], entryKind: 'income' }] }));
  assert.equal(run.written[0].entryKind, 'income');
});

test('statement narration classification excludes settlements and preserves explicit kinds', () => {
  assert.equal(inferStatementEntryKind({ merchantName: 'CREDIT CARD BILL PAYMENT' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'SELF TRANSFER TO HDFC ACCOUNT' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'MUTUAL FUND SIP' }), 'investment');
  assert.equal(inferStatementEntryKind({ merchantName: 'MUTUAL FUND REDEMPTION PROCEEDS' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'SALARY CREDIT' }), 'income');
  assert.equal(inferStatementEntryKind({ merchantName: 'AMAZON PURCHASE' }), 'spend');
  assert.equal(inferStatementEntryKind({ entryKind: 'income', merchantName: 'REFUND' }), 'income');
});

test('statement adjustments and loan advances stay outside spending and earned income', () => {
  assert.equal(inferStatementEntryKind({ merchantName: 'Card statement credit' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'Chargeback from merchant' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'Salary advance credited' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'Interest reversal credited' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'Dividend refund' }), 'transfer');
  assert.equal(inferStatementEntryKind({ merchantName: 'EMI interest charge' }), 'spend');
});

test('reviewed category, subcategory, and note are saved as the selected assignment', async () => {
  const run = harness();
  const input = body({
    transactions: [{
      ...body().transactions[0],
      categoryId,
      userCategoryId,
      categoryHint: 'Dining',
      subcategoryHint: 'Coffee',
      note: 'Edited before import',
    }],
  });
  const response = await run.call(input);
  assert.equal(response.status, 201);
  assert.equal(run.written[0].categoryId, categoryId);
  assert.equal(run.written[0].userCategoryId, userCategoryId);
  assert.equal(run.written[0].note, 'Edited before import');
});

test('reviewed private category must belong to the importing account and match its parent', async () => {
  const mismatched = harness();
  const wrongParent = body({
    transactions: [{ ...body().transactions[0], categoryId: cardId, userCategoryId }],
  });
  assert.equal((await mismatched.call(wrongParent)).status, 400);
  assert.equal(mismatched.written.length, 0);
});
