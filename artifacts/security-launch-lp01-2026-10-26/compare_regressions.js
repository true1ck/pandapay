'use strict';

// Run in an empty temporary directory with synthetic environment variables.
// Compile baseline modules in memory; never rewrite the shared working tree.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const ROOT = path.resolve(__dirname, '../..');

function baseline(relative) {
  const filename = path.join(ROOT, relative);
  const source = execFileSync('git', ['show', '75ab2c4:' + relative], { cwd: ROOT, encoding: 'utf8' });
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded._compile(source, filename);
  return loaded.exports;
}

async function cacheProof(auth) {
  auth._sessionCache.clear();
  const actualNow = Date.now;
  let now = 10_000, requests = 0;
  Date.now = () => now;
  const fetch = async () => {
    requests++;
    return { ok: true, json: async () => ({ token_valid: true, valid: true,
      subject: 'synthetic-profile', session: { active: true, revoked: false } }) };
  };
  try {
    for (let index = 0; index < 999; index++) await auth.fetchCurrentSession('synthetic-' + index, fetch);
    now = -10_000;
    await auth.fetchCurrentSession('expired-late-entry', fetch);
    now = 10_000;
    await auth.fetchCurrentSession('new-entry', fetch);
    const size = auth._sessionCache.size, before = requests;
    await auth.fetchCurrentSession('synthetic-0', fetch);
    return { size_after_insert: size, oldest_live_entry_required_refetch: requests !== before };
  } finally { Date.now = actualNow; auth._sessionCache.clear(); }
}

async function main() {
  const relative = 'db/scripts/audit_runtime_privileges.js';
  const oldAudit = baseline(relative), currentAudit = require(path.join(ROOT, relative));
  const policy = { format: 'pandapay-runtime-privilege-policy-v1', scope: 'fixture', managedSchemas: ['private'],
    roles: [{ name: 'runtime_fixture', kind: 'runtime', required: true }, { name: 'anon_fixture', kind: 'exposure', required: true }],
    ledgers: [], memberships: [], restrictedRoles: [], requiredRoutineAccess: [], acceptedFindings: [] };
  const inventory = Object.fromEntries(Object.keys(currentAudit.QUERIES).map(key => [key,
    key === 'metadata' ? { server_version_num: 180004, read_only: 'on', isolation: 'repeatable read' } :
    key === 'roles' ? [{ name: 'runtime_fixture', login: true }, { name: 'anon_fixture', login: false, bypass_rls: true }] : []]));
  const oldRole = oldAudit.evaluatePolicy(inventory, policy), newRole = currentAudit.evaluatePolicy(inventory, policy);
  assert.equal(oldRole.strict_pass, true);
  assert.equal(newRole.strict_pass, false);
  assert.ok(newRole.findings.some(item => item.code === 'privileged_role' && item.role === 'anon_fixture'));
  const oldCache = await cacheProof(baseline('api/src/auth.js'));
  const newCache = await cacheProof(require(path.join(ROOT, 'api/src/auth.js')));
  assert.deepEqual(oldCache, { size_after_insert: 999, oldest_live_entry_required_refetch: true });
  assert.deepEqual(newCache, { size_after_insert: 1000, oldest_live_entry_required_refetch: false });
  const proof = { baseline: '75ab2c4', exposure_role: { old_strict_pass: oldRole.strict_pass, new_strict_pass: newRole.strict_pass },
    clock_adjusted_cache: { before: oldCache, after: newCache }, live_network_calls: false,
    scope: 'Synthetic in-memory regression; does not prove production capacity or revocation latency' };
  fs.writeFileSync(path.join(__dirname, 'before-after-regressions.json'), JSON.stringify(proof, null, 2) + '\n');
  process.stdout.write(JSON.stringify(proof) + '\n');
}

main().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
