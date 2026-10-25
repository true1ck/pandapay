#!/usr/bin/env node
'use strict';

// Operator-only, exact-grant repair. Inspect/plan are read-only; rehearsal
// always rolls back. Commit requires a matching rehearsal receipt and an
// explicit quiesced maintenance acknowledgement. No .env is loaded.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { QUERIES, validatePolicy, evaluatePolicy, fingerprint, loadPolicy } = require('./audit_runtime_privileges');
const { sourceSnapshot, stableJson, readBounded } = require('./release_security_check');
const { resolveDatabaseTls } = require('../../api/src/db_tls');

const REVIEW = 'pandapay-runtime-privilege-repair-review-v1';
const FORMAT = 'pandapay-runtime-privilege-repair-plan-v1';
const RECEIPT = 'pandapay-runtime-privilege-repair-rehearsal-v1';
const DIGEST = /^[a-f0-9]{64}$/;
const MAX_OPERATIONS = 100;
const LIMIT = 10000;
const MAX_AGE_MS = 24 * 3600000;
const hash = value => crypto.createHash('sha256').update(stableJson(value)).digest('hex');
const same = (a, b) => stableJson(a) === stableJson(b);
const TARGET_SQL = `SELECT current_database() AS database,
  (SELECT oid::text FROM pg_database WHERE datname=current_database()) AS database_oid,
  current_user AS operator,inet_server_addr()::text AS server_address,
  inet_server_port() AS server_port,current_setting('server_version_num')::integer AS server_version_num`;

function fail(message) { throw new Error(message); }
function name(value) {
  if (typeof value !== 'string' || !value || Buffer.byteLength(value) > 63 || /[\x00-\x1f\x7f]/.test(value)) fail('Invalid exact identifier');
  return value;
}
function quote(value) { return '"' + name(value).replaceAll('"', '""') + '"'; }
function fields(value, allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !allowed.includes(key))) fail('Unknown repair input fields');
}
function digest(value) { if (!DIGEST.test(value || '')) fail('A SHA-256 review binding is required'); return value; }
function fresh(timestamp, now) {
  const time = Date.parse(timestamp);
  return Number.isFinite(time) && time <= now + 300000 && time >= now - MAX_AGE_MS;
}
function catalogDigest(inventory) {
  // Read-only vs read-write is a transaction property, not catalog drift.
  const copy = structuredClone(inventory);
  copy.metadata = { server_version_num: copy.metadata.server_version_num };
  return hash(copy);
}
function targetDigest(target) { return hash(target); }
function sourceDigest(source) { return digest(source?.candidate_sha256); }
function grantMatches(grant, op) { return grant.grantee === op.grantee && grant.grantor === op.grantor && grant.privilege === op.privilege; }
function operationKey(op) { const { reason, ...rest } = op; return hash(rest); }

function validateReview(review, { audit, policy, source, target, now = Date.now() }) {
  fields(review, ['format', 'scope', 'catalog_sha256', 'policy_sha256', 'source_sha256', 'target_sha256', 'reviewed_by', 'review_reference', 'reviewed_at', 'runtime_roles', 'operations', 'expected_effective_losses']);
  validatePolicy(policy);
  if (review.format !== REVIEW || review.scope !== policy.scope || !audit?.complete || !audit.inventory || audit.scope !== policy.scope) fail('Repair review requires a complete scoped audit');
  if (!fresh(audit.generated_at, now) || !fresh(review.reviewed_at, now)) fail('Repair audit/review is stale');
  if (digest(review.catalog_sha256) !== catalogDigest(audit.inventory) || digest(review.policy_sha256) !== fingerprint(policy) || audit.policy_sha256 !== fingerprint(policy) ||
      digest(review.source_sha256) !== sourceDigest(source) || digest(review.target_sha256) !== targetDigest(target)) fail('Repair review does not match exact catalog, policy, source and target');
  for (const key of ['reviewed_by', 'review_reference']) if (typeof review[key] !== 'string' || review[key].length < 3 || review[key].length > 200 || /[\x00-\x1f\x7f]/.test(review[key])) fail('Repair requires reviewer and external review reference');
  if (!Array.isArray(review.operations) || !review.operations.length || review.operations.length > MAX_OPERATIONS || !Array.isArray(review.expected_effective_losses) || review.expected_effective_losses.length > 5000) fail('Repair operation/loss inventory exceeds bounds');
  if (!Array.isArray(review.runtime_roles) || review.runtime_roles.length > 16 || new Set(review.runtime_roles).size !== review.runtime_roles.length || review.runtime_roles.some(value => !policy.roles.some(role => role.name === value && role.kind === 'runtime' && role.required))) fail('Repair requires exact reviewed runtime role names');
  const before = effectiveAccess(audit.inventory);
  if (new Set(review.expected_effective_losses).size !== review.expected_effective_losses.length || review.expected_effective_losses.some(key => typeof key !== 'string' || !before.has(key))) fail('Expected losses must name exact existing effective permissions');
  const keys = review.operations.map(operationKey);
  if (new Set(keys).size !== keys.length) fail('Duplicate repair operation');
}

function compileOperation(op, inventory, policy, target) {
  fields(op, ['kind', 'schema', 'name', 'column', 'identity', 'grantee', 'grantor', 'privilege', 'grant_option_only', 'reason', 'default_owner', 'default_kind']);
  if (typeof op.reason !== 'string' || op.reason.length < 20 || op.reason.length > 500 || typeof op.grant_option_only !== 'boolean') fail('Each exact grant removal requires a review reason and explicit grant-option mode');
  // PUBLIC, ownership, RLS, memberships and role attributes have wider effects
  // than this first repair model. They remain blocking findings for a separate
  // restored-copy change with a full application/provider access matrix.
  const role = policy.roles.find(value => value.name === op.grantee);
  if (!role || !['runtime', 'capability', 'exposure'].includes(role.kind) || op.grantee.toLowerCase() === 'public') fail('Unmodelled grantee; no PUBLIC/owner/inherited blanket repair');
  name(op.grantee); name(op.grantor);
  if (op.grantor !== target.operator) fail('Repair requires the exact original grantor login; no SET ROLE or alternate-grantor fallback');
  const grantOption = op.grant_option_only ? 'GRANT OPTION FOR ' : '';
  const suffix = ` FROM ${quote(op.grantee)} RESTRICT`;
  const managed = schema => { name(schema); if (!policy.managedSchemas.includes(schema)) fail('Repair target schema is outside reviewed policy'); return quote(schema); };
  const ensureGrant = (object, allowed) => {
    if (!object || object.extension || !allowed.includes(op.privilege) || !object.acl?.some(grant => grantMatches(grant, op) && (!op.grant_option_only || grant.grantable))) fail('Exact direct grant is absent, unmodelled or extension-owned');
    if (object.owner === op.grantee) fail('Owner privileges cannot be repaired with REVOKE');
  };
  let sql;
  if (op.kind === 'relation') {
    const object = inventory.relations.find(value => value.schema === op.schema && value.name === op.name);
    const allowed = object?.kind === 'S' ? ['SELECT', 'UPDATE', 'USAGE'] : ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'];
    ensureGrant(object, allowed);
    sql = `REVOKE ${grantOption}${op.privilege} ON ${object.kind === 'S' ? 'SEQUENCE' : 'TABLE'} ${managed(op.schema)}.${quote(op.name)}${suffix}`;
  } else if (op.kind === 'column') {
    const object = inventory.columns.find(value => value.schema === op.schema && value.relation === op.name && value.name === op.column);
    const relation = inventory.relations.find(value => value.schema === op.schema && value.name === op.name);
    if (!relation || relation.extension || !['r', 'p', 'v', 'f'].includes(relation.kind)) fail('Unmodelled column relation');
    ensureGrant(object, ['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']);
    if (relation.owner === op.grantee) fail('Owner privileges cannot be repaired with REVOKE');
    sql = `REVOKE ${grantOption}${op.privilege} (${quote(op.column)}) ON TABLE ${managed(op.schema)}.${quote(op.name)}${suffix}`;
  } else if (op.kind === 'routine') {
    const object = inventory.routines.find(value => value.identity === op.identity);
    ensureGrant(object, ['EXECUTE']);
    if (policy.requiredRoutineAccess.some(value => value.identity === op.identity && value.role === op.grantee) && !op.grant_option_only) fail('Required capability routine cannot be removed');
    managed(object.schema);
    // identity is selected from the hash-bound pg_catalog inventory, never
    // interpolated from free-form review text. Still require a single parsed
    // signature and refuse statement/comment syntax as an extra guard.
    if (/[;\n\r]|--|\/\*/.test(object.identity) || !object.identity.endsWith(')')) fail('Unmodelled routine signature');
    sql = `REVOKE ${grantOption}EXECUTE ON FUNCTION ${object.identity}${suffix}`;
  } else if (op.kind === 'schema') {
    const object = inventory.schemas.find(value => value.name === op.schema);
    ensureGrant(object, ['CREATE']);
    sql = `REVOKE ${grantOption}CREATE ON SCHEMA ${managed(op.schema)}${suffix}`;
  } else if (op.kind === 'default') {
    // Only explicit default ACL entries can be removed. Implicit PUBLIC
    // function defaults and absent ACLs require separate manual review.
    if (op.grant_option_only) fail('Default grant-option repairs are not modelled');
    name(op.default_owner);
    if (op.default_owner !== target.operator) fail('Default owner must be the exact operator');
    const object = inventory.defaults.find(value => value.owner === op.default_owner && value.schema === op.schema && value.kind === op.default_kind);
    const allowed = { r: ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'], S: ['USAGE', 'SELECT', 'UPDATE'], f: ['EXECUTE'] };
    ensureGrant(object, allowed[op.default_kind] || []);
    const kind = { r: 'TABLES', S: 'SEQUENCES', f: 'FUNCTIONS' }[op.default_kind];
    sql = `ALTER DEFAULT PRIVILEGES FOR ROLE ${quote(op.default_owner)}${op.schema === null ? '' : ` IN SCHEMA ${managed(op.schema)}`} REVOKE ${op.privilege} ON ${kind}${suffix}`;
  } else fail('Unmodelled repair operation; no mutation generated');
  // PostgreSQL RESTRICT refuses dependent downstream grants. No CASCADE is
  // generated, and the executor checks that REVOKE actually changed catalog.
  return sql + ';';
}

function createRepairPlan({ audit, policy, review, source, target, now = Date.now() }) {
  validateReview(review, { audit, policy, source, target, now });
  const statements = review.operations.map(op => compileOperation(op, audit.inventory, policy, target));
  return { format: FORMAT, scope: policy.scope, generated_at: new Date(now).toISOString(),
    review_sha256: hash(review), source_sha256: sourceDigest(source), target_sha256: targetDigest(target),
    before_catalog_sha256: catalogDigest(audit.inventory), policy_sha256: fingerprint(policy),
    audit, policy, review, statements,
    unhandled_findings: audit.findings,
    limitations: ['Exact direct ACL removals only; PUBLIC, memberships, ownership, RLS and definer rewrites are refused.',
      'Successful rehearsal proves catalog/effective-access invariants, not all application/provider flows. Complete restored-copy regression remains required.'] };
}

function effectiveAccess(inventory) {
  const keys = new Set();
  const add = (...parts) => keys.add(stableJson(parts));
  for (const value of inventory.effectiveDatabase) for (const privilege of ['connect', 'create', 'temporary']) if (value[privilege]) add('database', value.role, privilege.toUpperCase());
  for (const value of inventory.effectiveSchemas) for (const privilege of ['usage', 'create']) if (value[privilege]) add('schema', value.role, value.schema, privilege.toUpperCase());
  for (const value of inventory.effectiveRelations) for (const privilege of value.privileges) add('relation', value.role, value.schema, value.relation, privilege);
  for (const value of inventory.effectiveColumns) for (const privilege of value.privileges) add('column', value.role, value.schema, value.relation, value.column, privilege);
  for (const value of inventory.effectiveRoutines) if (value.execute) add('routine', value.role, value.identity, 'EXECUTE');
  return keys;
}
function structuralInventory(inventory) {
  const result = structuredClone(inventory);
  for (const name of ['databases', 'schemas', 'relations', 'columns', 'routines']) result[name] = result[name].map(({ acl, ...rest }) => rest);
  // Revoking the final explicit column/default grant removes that catalog ACL
  // row. Relation/schema/routine definitions remain independently compared.
  delete result.columns; delete result.defaults; delete result.routineCreationDefaults;
  for (const name of ['effectiveDatabase', 'effectiveSchemas', 'effectiveRelations', 'effectiveColumns', 'effectiveRoutines']) delete result[name];
  result.metadata = { server_version_num: result.metadata.server_version_num };
  return result;
}
function findingKey(value) { return stableJson([value.code, value.object, value.role]); }
function verifyRepairResult(before, after, plan) {
  if (!same(structuralInventory(before.inventory), structuralInventory(after.inventory))) fail('Repair changed unreviewed object definitions, owners, roles, memberships or RLS');
  const prior = effectiveAccess(before.inventory), current = effectiveAccess(after.inventory);
  const lost = [...prior].filter(key => !current.has(key)).sort();
  const gained = [...current].filter(key => !prior.has(key));
  if (gained.length || !same(lost, [...plan.review.expected_effective_losses].sort())) fail('Repair changed effective access outside exact reviewed losses');
  const beforeFindings = new Set(before.findings.map(findingKey));
  if (after.findings.some(value => !beforeFindings.has(findingKey(value)))) fail('Repair introduced an unreviewed privilege finding');
  if (catalogDigest(before.inventory) === catalogDigest(after.inventory)) fail('Repair had no catalog effect; grantor/target review is stale');
  if (after.summary.blocking >= before.summary.blocking) fail('Repair did not reduce blocking privilege findings');
  return { effective_losses: lost, remaining_blocking: after.summary.blocking, strict_pass: after.strict_pass };
}

async function readInventory(client, policy, { limit = LIMIT } = {}) {
  validatePolicy(policy);
  const inventory = {};
  const roles = policy.roles.map(value => value.name);
  for (const [key, sql] of Object.entries(QUERIES)) {
    const actual = key === 'metadata' || sql.includes('$1') ? sql : `WITH audit_parameters AS (SELECT $1::text[] AS roles) ${sql}`;
    const result = await client.query(actual, key === 'metadata' ? [] : [roles, limit + 1]);
    if (key === 'metadata') {
      inventory.metadata = result.rows[0];
      if (!inventory.metadata || inventory.metadata.isolation !== 'repeatable read' || inventory.metadata.server_version_num < 150000) fail('Unsupported privilege repair transaction');
    } else {
      if (result.rows.length > limit) fail('Catalog inventory bound exceeded');
      inventory[key] = result.rows;
    }
  }
  return inventory;
}
function report(inventory, policy, now) { return { complete: true, scope: policy.scope, generated_at: new Date(now).toISOString(), policy_sha256: fingerprint(policy), inventory, ...evaluatePolicy(inventory, policy, now) }; }
function validatePlan(plan, source, target, now) {
  if (plan?.format !== FORMAT || !fresh(plan.generated_at, now) || !fresh(plan.audit?.generated_at, now) || !fresh(plan.review?.reviewed_at, now)) fail('Invalid or stale privilege repair plan');
  const canonical = createRepairPlan({ audit: plan.audit, policy: plan.policy, review: plan.review, source, target, now: Date.parse(plan.generated_at) });
  if (!same(plan, canonical)) fail('Privilege repair plan was modified or does not match current source/target');
}

async function runRepair(client, { plan, source, sourceProvider, policyProvider, mode = 'rehearse', receipt = null, quiesced = false, now = Date.now() } = {}) {
  if (!['rehearse', 'apply'].includes(mode) || quiesced !== true) fail('Repair requires explicit quiesced maintenance acknowledgement');
  if (typeof sourceProvider !== 'function') fail('Repair requires a fresh source snapshot provider');
  if (typeof policyProvider !== 'function') fail('Repair requires a repository policy provider');
  let begun = false;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ'); begun = true;
    await client.query("SET LOCAL statement_timeout='5000ms'");
    await client.query("SET LOCAL lock_timeout='1000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout='15000ms'");
    await client.query('SET LOCAL search_path=pg_catalog');
    // Cooperative operator serialization only. Offline/quiesced restored-copy
    // acceptance is required; this advisory lock is not a hostile-DDL fence.
    const lock = await client.query('SELECT pg_try_advisory_xact_lock(1346458690,71) AS acquired');
    if (lock.rows[0]?.acquired !== true) fail('Another privilege repair is active');
    const target = (await client.query(TARGET_SQL)).rows[0];
    validatePlan(plan, source, target, now);
    if (!same(plan.policy, policyProvider())) fail('Repair policy differs from reviewed repository policy');
    if (!same(sourceDigest(sourceProvider()), sourceDigest(source))) fail('Source changed before privilege repair');
    if (mode === 'apply') {
      if (receipt?.format !== RECEIPT || receipt.rolled_back !== true || !fresh(receipt.verified_at, now) || receipt.plan_sha256 !== hash(plan) ||
          receipt.source_sha256 !== sourceDigest(source) || receipt.target_sha256 !== targetDigest(target) || receipt.before_catalog_sha256 !== plan.before_catalog_sha256 || !DIGEST.test(receipt.after_catalog_sha256 || '')) fail('Commit requires a fresh exact-plan, exact-source, exact-target rehearsal receipt');
    }
    const before = report(await readInventory(client, plan.policy, {}), plan.policy, now);
    if (catalogDigest(before.inventory) !== plan.before_catalog_sha256) fail('Catalog drift since privilege review; regenerate and review plan');
    for (const statement of plan.statements) await client.query(statement);
    const after = report(await readInventory(client, plan.policy, {}), plan.policy, now);
    const result = verifyRepairResult(before, after, plan);
    const afterDigest = catalogDigest(after.inventory);
    if (mode === 'apply' && receipt.after_catalog_sha256 !== afterDigest) fail('Applied result differs from rehearsed catalog');
    if (sourceDigest(sourceProvider()) !== sourceDigest(source)) fail('Source changed during privilege repair');
    if (!same(plan.policy, policyProvider())) fail('Repository policy changed during privilege repair');
    await client.query(mode === 'apply' ? 'COMMIT' : 'ROLLBACK'); begun = false;
    return { format: mode === 'rehearse' ? RECEIPT : 'pandapay-runtime-privilege-repair-result-v1', verified_at: new Date(now).toISOString(),
      plan_sha256: hash(plan), source_sha256: sourceDigest(source), target_sha256: targetDigest(target), before_catalog_sha256: plan.before_catalog_sha256,
      after_catalog_sha256: afterDigest, rolled_back: mode === 'rehearse', committed: mode === 'apply', ...result,
      remaining_findings: after.findings, application_acceptance_required: true };
  } catch (error) { if (begun) await client.query('ROLLBACK').catch(() => {}); throw error; }
}

function reviewTemplate({ audit, policy, source, target, now = Date.now() }) {
  return { format: REVIEW, scope: policy.scope, catalog_sha256: catalogDigest(audit.inventory), policy_sha256: fingerprint(policy),
    source_sha256: sourceDigest(source), target_sha256: targetDigest(target), reviewed_by: '', review_reference: '', reviewed_at: new Date(now).toISOString(), runtime_roles: policy.roles.filter(value => value.kind === 'runtime' && value.required).map(value => value.name), operations: [], expected_effective_losses: [] };
}
function connectionOptions(env = process.env) {
  if (!env.PRIVILEGE_REPAIR_DATABASE_URL) fail('PRIVILEGE_REPAIR_DATABASE_URL is required');
  return { ...resolveDatabaseTls(env.PRIVILEGE_REPAIR_DATABASE_URL, { NODE_ENV: env.NODE_ENV, DB_SSL: env.PRIVILEGE_REPAIR_DB_SSL,
    DB_SSL_CA: env.PRIVILEGE_REPAIR_DB_SSL_CA, DB_SSL_CA_FILE: env.PRIVILEGE_REPAIR_DB_SSL_CA_FILE }), connectionTimeoutMillis: 5000, query_timeout: 7000, application_name: 'pandapay-privilege-repair' };
}
function parseArgs(argv) {
  const result = { mode: argv[0], root: path.resolve(__dirname, '../..'), quiesced: false, scope: 'product', runtimeRoles: [] };
  if (!['inspect', 'plan', 'rehearse', 'apply'].includes(result.mode)) fail('Usage: runtime_privilege_repair.js inspect|plan|rehearse|apply [--scope product|auth --runtime-role ROLE] [--review FILE --inspection FILE | --plan FILE --receipt FILE] [--root DIR] [--quiesced]');
  for (let i = 1; i < argv.length; i++) {
    const item = argv[i];
    if (item === '--quiesced') result.quiesced = true;
    else if (item === '--runtime-role' && argv[i + 1]) result.runtimeRoles.push(name(argv[++i]));
    else if (['--scope', '--review', '--inspection', '--plan', '--receipt', '--root'].includes(item) && argv[i + 1]) result[item.slice(2)] = argv[++i];
    else fail('Invalid privilege repair arguments');
  }
  if (!['product', 'auth'].includes(result.scope) || result.runtimeRoles.length > 16 || new Set(result.runtimeRoles).size !== result.runtimeRoles.length) fail('Invalid privilege repair policy scope/roles');
  if ((result.mode === 'inspect' && result.scope === 'auth' && !result.runtimeRoles.length) || (result.mode === 'plan' && (!result.review || !result.inspection)) || (['rehearse', 'apply'].includes(result.mode) && !result.plan) || (result.mode === 'apply' && !result.receipt)) fail('Missing explicit privilege repair input');
  return result;
}
function repositoryPolicy(root, scope, runtimeRoles) {
  if (!['product', 'auth'].includes(scope) || !Array.isArray(runtimeRoles) || (scope === 'auth' && !runtimeRoles.length)) fail('Production repair requires explicit repository scope and auth runtime role');
  return loadPolicy({ scope, runtimeRoles, policy: path.join(root, 'db/security', `${scope}-runtime-privileges.json`) });
}
const readJson = filename => JSON.parse(readBounded(filename, 16 * 1024 * 1024).toString('utf8'));
async function main(argv = process.argv.slice(2), env = process.env) {
  const options = parseArgs(argv), source = sourceSnapshot(options.root);
  if (options.mode === 'plan') {
    const inspection = readJson(options.inspection), review = readJson(options.review);
    const policy = repositoryPolicy(options.root, review.scope, review.runtime_roles);
    if (!same(policy, inspection.policy)) fail('Inspection policy differs from reviewed repository policy');
    const result = createRepairPlan({ audit: inspection.audit, policy, source, target: inspection.target, review });
    process.stdout.write(JSON.stringify(result, null, 2) + '\n'); return;
  }
  const { Client } = require('../../api/node_modules/pg');
  const client = new Client(connectionOptions(env)); client.on('error', () => {});
  try {
    await client.connect();
    let result;
    if (options.mode === 'inspect') {
      const policy = repositoryPolicy(options.root, options.scope, options.runtimeRoles);
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      try {
        await client.query("SET LOCAL statement_timeout='5000ms'"); await client.query("SET LOCAL lock_timeout='1000ms'"); await client.query('SET LOCAL search_path=pg_catalog');
        const target = (await client.query(TARGET_SQL)).rows[0], audit = report(await readInventory(client, policy), policy, Date.now());
        result = { format: 'pandapay-runtime-privilege-repair-inspection-v1', target, audit, policy, review_template: reviewTemplate({ audit, policy, source, target }) };
        await client.query('COMMIT');
      } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
    } else {
      const plan = readJson(options.plan);
      result = await runRepair(client, { plan, receipt: options.receipt ? readJson(options.receipt) : null,
        source, sourceProvider: () => sourceSnapshot(options.root),
        policyProvider: () => repositoryPolicy(options.root, plan.scope, plan.review.runtime_roles), mode: options.mode, quiesced: options.quiesced });
    }
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } finally { await client.end().catch(() => {}); }
}
if (require.main === module) main().catch(() => { process.stderr.write('Runtime privilege repair failed; no successful repair receipt produced.\n'); process.exitCode = 1; });
module.exports = { REVIEW, FORMAT, RECEIPT, TARGET_SQL, hash, catalogDigest, targetDigest, createRepairPlan, compileOperation, effectiveAccess,
  verifyRepairResult, readInventory, report, reviewTemplate, validatePlan, runRepair, connectionOptions, parseArgs, repositoryPolicy };
