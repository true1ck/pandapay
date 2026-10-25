'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { QUERIES, fingerprint, evaluatePolicy } = require('../scripts/audit_runtime_privileges');
const { REVIEW, FORMAT, RECEIPT, TARGET_SQL, hash, catalogDigest, targetDigest, createRepairPlan,
  effectiveAccess, verifyRepairResult, reviewTemplate, runRepair, report, parseArgs, connectionOptions } = require('../scripts/runtime_privilege_repair');
const NOW = Date.parse('2026-10-24T10:00:00.000Z');
const SOURCE = { candidate_sha256: 'a'.repeat(64) };
const TARGET = { database: 'synthetic', database_oid: '101', operator: 'operator_fixture', server_address: '127.0.0.1', server_port: 50000, server_version_num: 180004 };
const acl = (grantee, privilege, grantable = false) => ({ grantee, privilege, grantable, grantor: TARGET.operator });
function policy() { return { format: 'pandapay-runtime-privilege-policy-v1', scope: 'fixture', managedSchemas: ['private'],
  roles: [{ name: 'runtime_fixture', kind: 'runtime', required: true }, { name: 'rpc_fixture', kind: 'capability', required: true }],
  memberships: [], ledgers: [], restrictedRoles: [], requiredRoutineAccess: [{ role: 'rpc_fixture', identity: 'private.safe()' }], acceptedFindings: [] }; }
function inventory() {
  const result = Object.fromEntries(Object.keys(QUERIES).map(key => [key, []]));
  result.metadata = { server_version_num: 180004, read_only: 'on', isolation: 'repeatable read' };
  result.roles = [{ name: 'runtime_fixture', login: true }, { name: 'rpc_fixture', login: false }];
  result.schemas = [{ name: 'private', owner: TARGET.operator, acl: [acl('runtime_fixture', 'USAGE')] }];
  result.relations = [{ schema: 'private', name: 'data', kind: 'r', owner: TARGET.operator, rls: true, force_rls: true, extension: false,
    acl: [acl('runtime_fixture', 'SELECT'), acl('runtime_fixture', 'TRUNCATE'), acl('runtime_fixture', 'UPDATE', true)] }];
  result.effectiveRelations = [{ role: 'runtime_fixture', schema: 'private', relation: 'data', privileges: ['SELECT', 'UPDATE', 'TRUNCATE'] }];
  result.effectiveRoutines = [{ role: 'rpc_fixture', schema: 'private', identity: 'private.safe()', execute: true }];
  result.routines = [{ schema: 'private', name: 'safe', identity: 'private.safe()', owner: TARGET.operator, security_definer: false, extension: false, acl: [acl('rpc_fixture', 'EXECUTE')] }];
  return result;
}
function fixture() {
  const p = policy(), i = inventory(), audit = report(i, p, NOW);
  const review = { ...reviewTemplate({ audit, policy: p, source: SOURCE, target: TARGET, now: NOW }),
    reviewed_by: 'Fixture reviewer', review_reference: 'synthetic clone access matrix',
    operations: [{ kind: 'relation', schema: 'private', name: 'data', grantee: 'runtime_fixture', grantor: TARGET.operator,
      privilege: 'TRUNCATE', grant_option_only: false, reason: 'Runtime transactions never truncate financial relations.' }],
    expected_effective_losses: ['["relation","runtime_fixture","private","data","TRUNCATE"]'] };
  const plan = createRepairPlan({ audit, policy: p, review, source: SOURCE, target: TARGET, now: NOW });
  const after = structuredClone(i);
  after.relations[0].acl = after.relations[0].acl.filter(grant => grant.privilege !== 'TRUNCATE');
  after.effectiveRelations[0].privileges = ['SELECT', 'UPDATE'];
  return { p, i, audit, review, plan, after, afterAudit: report(after, p, NOW) };
}

test('explicit review generates only an exact quoted REVOKE with RESTRICT', () => {
  const { plan } = fixture();
  assert.equal(plan.format, FORMAT);
  assert.deepEqual(plan.statements, ['REVOKE TRUNCATE ON TABLE "private"."data" FROM "runtime_fixture" RESTRICT;']);
  assert.ok(plan.unhandled_findings.length > 0);
  assert.doesNotMatch(plan.statements.join('\n'), /ALL|CASCADE|SET ROLE|ALTER ROLE|DROP|DELETE/);
});

test('catalog, policy, target, source, reviewer and evidence drift all refuse planning', () => {
  for (const mutate of [f => f.review.catalog_sha256 = 'b'.repeat(64), f => f.review.policy_sha256 = 'b'.repeat(64),
    f => f.review.source_sha256 = 'b'.repeat(64), f => f.review.target_sha256 = 'b'.repeat(64), f => f.review.reviewed_by = '',
    f => f.review.review_reference = '', f => f.audit.complete = false, f => f.review.reviewed_at = '2026-10-20T00:00:00.000Z',
    f => f.audit.generated_at = '2026-10-20T00:00:00.000Z', f => f.review.extra = 'unused']) {
    const f = fixture(); mutate(f);
    assert.throws(() => createRepairPlan({ audit: f.audit, policy: f.p, review: f.review, source: SOURCE, target: TARGET, now: NOW }));
  }
});

test('PUBLIC, owners, inherited membership, unknown grants, extensions and alternate grantor are refused', () => {
  for (const mutate of [op => op.grantee = 'PUBLIC', op => op.grantee = TARGET.operator,
    op => op.kind = 'membership', op => op.privilege = 'ALL', op => op.grantor = 'other_operator', op => op.schema = 'unmanaged']) {
    const f = fixture(); mutate(f.review.operations[0]);
    assert.throws(() => createRepairPlan({ audit: f.audit, policy: f.p, review: f.review, source: SOURCE, target: TARGET, now: NOW }));
  }
  const f = fixture(); f.i.relations[0].extension = true; f.audit = report(f.i, f.p, NOW); f.review.catalog_sha256 = catalogDigest(f.i);
  assert.throws(() => createRepairPlan({ audit: f.audit, policy: f.p, review: f.review, source: SOURCE, target: TARGET, now: NOW }), /extension-owned/);
});

test('required capability EXECUTE cannot be revoked by its direct grantee', () => {
  const f = fixture(); f.review.operations = [{ kind: 'routine', identity: 'private.safe()', grantee: 'rpc_fixture', grantor: TARGET.operator,
    privilege: 'EXECUTE', grant_option_only: false, reason: 'Synthetic attempted required capability removal.' }];
  assert.throws(() => createRepairPlan({ audit: f.audit, policy: f.p, review: f.review, source: SOURCE, target: TARGET, now: NOW }), /Required capability/);
});

test('grant-option removal retains ordinary data access', () => {
  const f = fixture(); f.review.operations[0].privilege = 'UPDATE'; f.review.operations[0].grant_option_only = true; f.review.expected_effective_losses = [];
  const plan = createRepairPlan({ audit: f.audit, policy: f.p, review: f.review, source: SOURCE, target: TARGET, now: NOW });
  assert.match(plan.statements[0], /^REVOKE GRANT OPTION FOR UPDATE/);
  const after = structuredClone(f.i); after.relations[0].acl.find(grant => grant.privilege === 'UPDATE').grantable = false;
  assert.deepEqual(verifyRepairResult(f.audit, report(after, f.p, NOW), plan).effective_losses, []);
});

test('exact loss verification preserves all other schema/table/column/capability access', () => {
  const f = fixture();
  assert.deepEqual(verifyRepairResult(f.audit, f.afterAudit, f.plan).effective_losses, f.review.expected_effective_losses);
  const changed = structuredClone(f.after); changed.effectiveRoutines[0].execute = false;
  assert.throws(() => verifyRepairResult(f.audit, report(changed, f.p, NOW), f.plan), /outside exact reviewed losses/);
  const ownerChanged = structuredClone(f.after); ownerChanged.relations[0].owner = 'runtime_fixture';
  assert.throws(() => verifyRepairResult(f.audit, report(ownerChanged, f.p, NOW), f.plan), /unreviewed object definitions/);
});

function clientFor(f, { mutateSql = false, failQuery = false, stale = false } = {}) {
  const calls = []; let mutated = false;
  return { calls, async query(sql) {
    calls.push(sql);
    if (sql === TARGET_SQL) return { rows: [TARGET] };
    if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
    if (sql.startsWith('REVOKE')) { if (failQuery) throw new Error('synthetic revoke failure'); mutated = true; return { rows: [] }; }
    const entry = Object.entries(QUERIES).find(([, value]) => sql.endsWith(value));
    if (entry) {
      const i = mutated ? f.after : f.i;
      const value = structuredClone(entry[0] === 'metadata' ? [i.metadata] : i[entry[0]]);
      if (stale && entry[0] === 'roles') value.push({ name: 'drift_role', login: false });
      return { rows: value };
    }
    return { rows: [] };
  } };
}

test('default rehearsal rolls back after proving exact catalog and effective-access result', async () => {
  const f = fixture(), client = clientFor(f);
  const receipt = await runRepair(client, { plan: f.plan, source: SOURCE, sourceProvider: () => SOURCE, policyProvider: () => f.p, quiesced: true, now: NOW });
  assert.equal(receipt.format, RECEIPT); assert.equal(receipt.rolled_back, true); assert.equal(receipt.committed, false);
  assert.equal(client.calls.at(-1), 'ROLLBACK'); assert.ok(!client.calls.includes('COMMIT'));
  assert.equal(receipt.strict_pass, false, 'unhandled grant-option finding stays blocking');
});

test('apply requires receipt for identical plan/catalog/source/target and its rehearsed result', async () => {
  const f = fixture(); const receipt = await runRepair(clientFor(f), { plan: f.plan, source: SOURCE, sourceProvider: () => SOURCE, policyProvider: () => f.p, quiesced: true, now: NOW });
  const client = clientFor(f); const result = await runRepair(client, { plan: f.plan, receipt, source: SOURCE, sourceProvider: () => SOURCE, policyProvider: () => f.p, quiesced: true, mode: 'apply', now: NOW });
  assert.equal(result.committed, true); assert.equal(client.calls.at(-1), 'COMMIT');
  for (const modified of [null, { ...receipt, plan_sha256: 'b'.repeat(64) }, { ...receipt, target_sha256: 'b'.repeat(64) }, { ...receipt, rolled_back: false }, { ...receipt, after_catalog_sha256: 'b'.repeat(64) }]) {
    const bad = clientFor(f);
    await assert.rejects(runRepair(bad, { plan: f.plan, receipt: modified, source: SOURCE, sourceProvider: () => SOURCE, policyProvider: () => f.p, quiesced: true, mode: 'apply', now: NOW }));
    assert.equal(bad.calls.at(-1), 'ROLLBACK'); assert.ok(!bad.calls.includes('COMMIT'));
  }
});

test('tampering, catalog drift, query failures and source changes all fail with rollback', async () => {
  for (const scenario of ['sql', 'catalog', 'query', 'source']) {
    const f = fixture(); if (scenario === 'sql') f.plan.statements[0] = 'DROP TABLE private.data;';
    const client = clientFor(f, { stale: scenario === 'catalog', failQuery: scenario === 'query' });
    await assert.rejects(runRepair(client, { plan: f.plan, source: SOURCE,
      sourceProvider: () => scenario === 'source' ? { candidate_sha256: 'b'.repeat(64) } : SOURCE, policyProvider: () => f.p, quiesced: true, now: NOW }));
    assert.equal(client.calls.at(-1), 'ROLLBACK'); assert.ok(!client.calls.includes('COMMIT'));
    if (['sql', 'catalog', 'source'].includes(scenario)) assert.ok(!client.calls.some(value => value.startsWith('REVOKE')));
  }
});

test('repair requires explicit maintenance acknowledgement and a source recheck dependency', async () => {
  const f = fixture(); await assert.rejects(runRepair(clientFor(f), { plan: f.plan, source: SOURCE, sourceProvider: () => SOURCE, policyProvider: () => f.p, now: NOW }), /quiesced/);
  await assert.rejects(runRepair(clientFor(f), { plan: f.plan, source: SOURCE, quiesced: true, now: NOW }), /snapshot provider/);
});

test('repair CLI never consumes ambient URLs or remotely disabled TLS', () => {
  assert.throws(() => connectionOptions({ DATABASE_URL: 'postgresql://operator:synthetic@example.test/db' }), /required/);
  assert.throws(() => connectionOptions({ PRIVILEGE_REPAIR_DATABASE_URL: 'postgresql://operator:synthetic@example.test/db', PRIVILEGE_REPAIR_DB_SSL: 'false', NODE_ENV: 'test' }), /local/);
  assert.equal(connectionOptions({ PRIVILEGE_REPAIR_DATABASE_URL: 'postgresql://operator:synthetic@127.0.0.1/db', PRIVILEGE_REPAIR_DB_SSL: 'false', NODE_ENV: 'test' }).ssl, false);
  assert.throws(() => parseArgs(['apply', '--plan', 'fixture.json']), /Missing explicit/);
  assert.throws(() => parseArgs(['apply', '--plan', 'fixture.json', '--receipt', 'receipt.json', '--database-url', 'secret']), /Invalid/);
  assert.equal(parseArgs(['rehearse', '--plan', 'fixture.json', '--quiesced']).quiesced, true);
});
