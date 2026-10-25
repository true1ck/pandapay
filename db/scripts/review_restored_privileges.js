'use strict';

// Optional read-only catalogue/history review of an already verified restore.
// No migration, grant repair, app function call, source connection or .env.
const fs = require('node:fs'), path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { auditRuntimePrivileges, loadPolicy } = require('./audit_runtime_privileges');
const { migrationInventory } = require('./product_migrate');
const ROLE = /^[A-Za-z_][A-Za-z0-9_]{0,62}$/;

function inputs(env) {
  let restoreId;
  for (const [scope, suffix] of [['PRODUCT', 'p'], ['AUTH', 'a']]) {
    let url; try { url = new URL(env[`RESTORE_${scope}_TARGET_URL`]); } catch { throw new Error('Verified local restore required'); }
    if (!['postgres:', 'postgresql:'].includes(url.protocol) || url.hostname !== '127.0.0.1' ||
        !new RegExp(`^/pprestore_[a-f0-9]{20}_${suffix}$`).test(url.pathname) || url.hash ||
        [...url.searchParams.keys()].some(key => !['sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'sslpassword'].includes(key.toLowerCase())) ||
        env[`RESTORE_${scope}_EXACT_COMPARISON`] !== 'passed') throw new Error('Verified local restore required');
    const pair = url.pathname.slice(0, -2);
    if (restoreId && restoreId !== pair) throw new Error('Matched paired restore required');
    restoreId = pair;
    if (!ROLE.test(env[`RESTORE_${scope}_RUNTIME_ROLE`] || '')) throw new Error('Explicit runtime role required');
  }
  if (env.RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION !== 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER') throw new Error('Isolated restore attestation required');
  for (const name of ['RESTORE_PRIVILEGE_REVIEW_FILE', 'RESTORE_DIAGNOSTIC_RECIPIENTS_FILE']) {
    if (!path.isAbsolute(env[name] || '')) throw new Error('Private absolute output/recipient paths required');
  }
  if (!env.RESTORE_PRIVILEGE_REVIEW_FILE.endsWith('.json.age')) throw new Error('Encrypted review output required');
  return { productRole: env.RESTORE_PRODUCT_RUNTIME_ROLE, authRole: env.RESTORE_AUTH_RUNTIME_ROLE };
}
function compareLedger(rows, files) {
  const known = new Map(files.map(([name, filename]) => [name, createHash('sha256').update(fs.readFileSync(filename)).digest('hex')]));
  const seen = new Set(), unknown = [], mismatched = [], missingChecksum = [], duplicate = [];
  for (const row of rows) {
    if (typeof row.filename !== 'string' || row.filename.length > 256) throw new Error('Invalid migration ledger');
    if (seen.has(row.filename)) duplicate.push(row.filename); seen.add(row.filename);
    if (!known.has(row.filename)) unknown.push(row.filename);
    else if (!row.checksum) missingChecksum.push(row.filename);
    else if (row.checksum !== known.get(row.filename)) mismatched.push(row.filename);
  }
  return { entries: rows.length, unknown, mismatched, missingChecksum, duplicate,
    pending: [...known.keys()].filter(name => !seen.has(name)),
    history_known: unknown.length === 0 && mismatched.length === 0 && duplicate.length === 0 };
}
async function reviewRestoredPrivileges({ product, auth, env = process.env, encrypt = spawnSync } = {}) {
  const roles = inputs(env), reports = {};
  for (const [scope, pool, role] of [['product', product, roles.productRole], ['auth', auth, roles.authRole]]) {
    const policy = loadPolicy({ scope, runtimeRoles: [role] });
    const client = await pool.connect();
    try { reports[scope] = await auditRuntimePrivileges(client, { policy, limit: 50000 }); }
    finally { client.release(); }
  }
  // Explicit fresh read-only snapshot; a historical ledger cannot be adopted
  // merely because it was present in an otherwise valid archive.
  const client = await product.connect(); let begun = false, history;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'); begun = true;
    await client.query("SET LOCAL statement_timeout='5000ms'");
    const exists = (await client.query("SELECT to_regclass('public.schema_migrations') IS NOT NULL AS present")).rows[0]?.present;
    const rows = exists ? (await client.query("SELECT filename,to_jsonb(t)->>'checksum' AS checksum FROM public.schema_migrations t ORDER BY filename LIMIT 20001")).rows : [];
    if (rows.length > 20000) throw new Error('Ledger review exceeds bounds');
    history = compareLedger(rows, migrationInventory(path.resolve(__dirname, '..')));
    history.ledger_present = exists === true;
    await client.query('COMMIT'); begun = false;
  } finally { if (begun) await client.query('ROLLBACK').catch(() => {}); client.release(); }
  const review = { format: 'pandapay-protected-restored-privilege-review-v1', generated_at: new Date().toISOString(),
    read_only: true, live_connection_opened: false, reports, product_history: history };
  const serialized = JSON.stringify(review);
  if (Buffer.byteLength(serialized) > 16 * 1024 * 1024) throw new Error('Protected review exceeds bounds');
  const encrypted = encrypt('age', ['-R', env.RESTORE_DIAGNOSTIC_RECIPIENTS_FILE], { input: serialized, timeout: 30000,
    maxBuffer: 17 * 1024 * 1024, env: { PATH: env.PATH, HOME: env.HOME } });
  if (encrypted.status !== 0 || !encrypted.stdout?.length) throw new Error('Protected review encryption failed');
  const filename = env.RESTORE_PRIVILEGE_REVIEW_FILE, pending = filename + '.pending';
  const fd = fs.openSync(pending, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, encrypted.stdout); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(pending, filename);
  return { product_blocking: reports.product.summary.blocking, auth_blocking: reports.auth.summary.blocking,
    history_unknown: history.unknown.length, history_mismatched: history.mismatched.length, history_duplicate: history.duplicate.length,
    strict_pass: reports.product.strict_pass && reports.auth.strict_pass && history.history_known && history.ledger_present };
}
module.exports = { inputs, compareLedger, reviewRestoredPrivileges };
