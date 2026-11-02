const test = require('node:test');
const assert = require('node:assert/strict');
const { classifyAmountAudit, auditTransactions, registerSmsAmountAuditRoutes } = require('../src/sms_amount_audit');
const base = { id: '11111111-1111-4111-8111-111111111111', source_key: 'a'.repeat(64), amount_inr: '150000.00' };
const fact = (payload, extra = {}) => ({ fact_type: 'balance_snapshot', payload, provenance: { channel: 'parser' }, status: 'active', ...extra });

test('limit-only and obligation facts identify an unsupported expense', () => {
  for (const field of ['limitInr', 'availableBalanceInr', 'outstandingInr', 'amountDueInr', 'minimumDueInr', 'proposedAmountInr']) {
    assert.equal(classifyAmountAudit(base, [fact({ [field]: 150000 })]).disposition, 'candidate');
  }
});
test('a genuine equal-valued posted amount is not removed', () => {
  assert.equal(classifyAmountAudit(base, [fact({ limitInr: 150000 }), fact({ amountInr: 150000 }, { fact_type: 'posted_movement' })]).disposition, 'verified');
});
test('missing, discarded or AI-only source facts remain unverified', () => {
  for (const facts of [[], [fact({ limitInr: 150000 }, { status: 'discarded' })], [fact({ limitInr: 150000 }, { provenance: { channel: 'ai' } })]]) {
    assert.equal(classifyAmountAudit(base, facts).disposition, 'unverified');
  }
});
test('annotations, explicit user observations and overrides protect a record', () => {
  for (const patch of [{ note: 'Corrected by me' }, { user_category_id: 'private' }, { has_tags: true }, { has_manual_observation: true }, { has_user_sync: true }]) {
    assert.equal(classifyAmountAudit({ ...base, ...patch }, [fact({ limitInr: 150000 })]).disposition, 'protected');
  }
  assert.equal(classifyAmountAudit(base, [fact({ limitInr: 150000 }, { has_override: true })]).disposition, 'protected');
});
test('audit joins aliases within the authenticated profile and locks repair reads', async () => {
  const calls = [];
  const client = { query: async (sql, params) => {
    calls.push({ sql, params });
    if (sql.includes('SELECT t.*')) return { rows: [{ ...base, source_keys: ['b'.repeat(64)] }] };
    return { rows: [{ source_key: 'b'.repeat(64), ...fact({ limitInr: 150000 }) }] };
  } };
  const result = await auditTransactions(client, 'owner', { ids: [base.id], limit: 50, forUpdate: true });
  assert.equal(result[0].audit.disposition, 'candidate');
  assert.match(calls[0].sql, /profile_id=\$1/);
  assert.match(calls[0].sql, /FOR UPDATE OF t/);
  assert.equal(calls[0].params[0], 'owner');
  assert.deepEqual(calls[1].params, ['owner', ['a'.repeat(64), 'b'.repeat(64)]]);
});
test('repair rejects unbounded input before any database operation', async () => {
  const routes = new Map();
  registerSmsAmountAuditRoutes({ get() {}, post(path, auth, handler) { routes.set(path, handler); } }, {
    requireAuth() {}, withUserClient() { throw new Error('must not access database'); },
  });
  let status, body;
  const res = { status(code) { status = code; return this; }, json(value) { body = value; return this; } };
  await routes.get('/transactions/amount-audit/repair')({ body: { transaction_ids: Array(51).fill(base.id) } }, res);
  assert.equal(status, 400);
  assert.equal(body.error, 'choose_1_to_50_transaction_ids');
});
