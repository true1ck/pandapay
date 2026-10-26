'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawnSync } = require('node:child_process');
const { template, validateBudget, evaluateBudget, readInput } = require('../scripts/connection_budget');
const NOW = Date.parse('2026-10-25T10:00:00Z');
function fixture() {
  const value = template(); value.inventoryReviewed = true; value.reviewedAt = new Date(NOW).toISOString();
  Object.assign(value.clusters[0], { limitsVerified: true, verifiedAt: value.reviewedAt,
    maxConnections: 60, reservedConnections: 3, providerConnections: 6, operationalConnections: 2, safetyConnections: 2 });
  return value;
}
function processOf(value, kind) { return value.processes.find(process => process.kind === kind); }

test('unknown host limits and unreviewed inventory remain blocking without credentials or I/O', () => {
  const report = evaluateBudget(template(), { now: NOW });
  assert.equal(report.budget_ready, false); assert.equal(report.read_only, true);
  assert.equal(report.clusters[0].remaining_connections, null);
  assert.ok(report.issues.includes('inventory_review_missing_or_stale'));
  assert.ok(report.issues.includes('primary_limits_missing_or_stale'));
});
test('50 application slots do not fit a 60-slot cluster once 13 reserves are included', () => {
  const value = fixture(); processOf(value, 'api').replicas = 2; processOf(value, 'auth').replicas = 2;
  const report = evaluateBudget(value, { now: NOW }), cluster = report.clusters[0];
  assert.equal(cluster.steady_connections, 50); assert.equal(cluster.rollout_connections, 50);
  assert.equal(cluster.rollout_required_connections, 63); assert.equal(cluster.remaining_connections, -3);
  assert.equal(report.budget_ready, false);
});
test('rollout overlap can exhaust a topology whose steady-state budget fits', () => {
  const value = fixture(); assert.equal(evaluateBudget(value, { now: NOW }).budget_ready, true);
  for (const kind of ['api', 'auth', 'rewards-worker']) processOf(value, kind).overlapReplicas = 1;
  const cluster = evaluateBudget(value, { now: NOW }).clusters[0];
  assert.equal(cluster.steady_connections, 30); assert.equal(cluster.rollout_connections, 60);
  assert.equal(cluster.fits, false);
});
test('optional pools and rewards-worker imported pools count per process even when separate logical databases are used', () => {
  const value = fixture();
  Object.assign(processOf(value, 'api').pools, { partnerWebhook: 'primary', imapWorker: 'primary', accountLifecycle: 'primary' });
  Object.assign(processOf(value, 'rewards-worker').pools, { partnerWebhook: 'primary', imapWorker: 'primary', accountLifecycle: 'primary' });
  Object.assign(processOf(value, 'auth').pools, { consoleSession: 'primary', authLifecycle: 'primary' });
  const report = evaluateBudget(value, { now: NOW });
  assert.equal(report.clusters[0].rollout_connections, 45);
  assert.equal(report.clusters[0].rollout_required_connections, 58);
  assert.equal(report.budget_ready, true);
});
test('physical clusters have independent limits and each pool is counted exactly once', () => {
  const value = fixture(); value.clusters.push({ ...value.clusters[0], id: 'identity', maxConnections: 16, providerConnections: 0 });
  processOf(value, 'auth').pools.main = 'identity';
  let report = evaluateBudget(value, { now: NOW });
  assert.equal(report.clusters[0].steady_connections, 20); assert.equal(report.clusters[1].steady_connections, 10);
  assert.equal(report.budget_ready, false); // identity needs 17 including its reserves.
  value.clusters[1].maxConnections = 17; report = evaluateBudget(value, { now: NOW });
  assert.equal(report.budget_ready, true); assert.equal(report.clusters[1].remaining_connections, 0);
});
test('maintenance holds both auth-retention clients; HTTP-only Gemini adds no local PG connection', () => {
  const value = fixture();
  for (const process of value.processes) if (!['api', 'auth', 'rewards-worker'].includes(process.kind)) process.replicas = 1;
  const report = evaluateBudget(value, { now: NOW });
  assert.equal(report.clusters[0].steady_connections, 38);
  assert.equal(report.processes.find(process => process.kind === 'notification-health-monitor').contributions[0].steady_connections, 1);
  assert.deepEqual(report.processes.find(process => process.kind === 'gemini-worker').contributions, []);
  assert.equal(report.processes.find(process => process.kind === 'auth-retention-maintenance').contributions.length, 2);
});
test('stale reviews, future reviews, unknown reserves and missing operational/safety headroom cannot approve', () => {
  for (const mutate of [
    value => value.reviewedAt = '2026-10-20T10:00:00Z', value => value.clusters[0].verifiedAt = '2026-10-26T10:00:00Z',
    value => value.clusters[0].providerConnections = null, value => value.clusters[0].operationalConnections = 0,
    value => value.clusters[0].safetyConnections = 0, value => value.inventoryReviewed = false,
    value => processOf(value, 'api').replicas = 0,
  ]) { const value = fixture(); mutate(value); assert.equal(evaluateBudget(value, { now: NOW }).budget_ready, false); }
});
test('omitted workers, duplicated IDs, unknown aliases, unexpected secrets and malformed/huge counts are rejected', () => {
  for (const mutate of [
    value => { value.processes = value.processes.filter(p => p.kind !== 'maintenance-alert-delivery'); }, value => value.processes.push(value.processes[0]), value => value.clusters.push(value.clusters[0]),
    value => processOf(value, 'api').pools.main = 'absent', value => delete processOf(value, 'api').pools.imapWorker,
    value => processOf(value, 'api').pools.main = null, value => value.password = 'never-output',
    value => value.clusters[0].url = 'postgresql://never-output', value => processOf(value, 'api').dbPoolMax = 2.5,
    value => processOf(value, 'api').replicas = Number.MAX_SAFE_INTEGER, value => processOf(value, 'api').overlapReplicas = -1,
    value => { processOf(value, 'gemini-worker').overlapReplicas = 1; },
    value => processOf(value, 'api').kind = '__proto__', value => value.clusters[0].maxConnections = true,
    value => value.clusters[0].id = 'https://never-output', value => processOf(value, 'api').dbPoolMax = Infinity,
  ]) { const value = fixture(); mutate(value); assert.throws(() => validateBudget(value)); }
});
test('distinct old/new configurations can be inventoried as separate entries of the same process kind', () => {
  const value = fixture(); value.processes.push({ ...processOf(value, 'api'), id: 'api-old', dbPoolMax: 4 });
  assert.equal(evaluateBudget(value, { now: NOW }).clusters[0].rollout_connections, 34);
});
test('CLI strict mode fails closed, ignores saved env and never echoes malformed input contents', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-budget-'));
  const script = path.join(__dirname, '../scripts/connection_budget.js');
  const run = args => spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', env: { PATH: process.env.PATH, DATABASE_URL: 'postgresql://never-output', ENCRYPTION_KEY: 'never-output' } });
  try {
    const filename = path.join(dir, 'inputs.json'); fs.writeFileSync(filename, JSON.stringify(template()));
    let result = run(['--inputs', filename, '--strict']); assert.equal(result.status, 2);
    assert.equal(JSON.parse(result.stdout).budget_ready, false); assert.equal(result.stdout.includes('never-output'), false);
    fs.writeFileSync(filename, '{"password":"never-output"}'); result = run(['--inputs', filename]);
    assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr.includes('never-output'), false);
    fs.writeFileSync(filename, ' '.repeat(128 * 1024 + 1)); assert.throws(() => readInput(filename));
    fs.symlinkSync(filename, path.join(dir, 'link.json')); assert.throws(() => readInput(path.join(dir, 'link.json')));
    assert.equal(run(['--template']).status, 0); assert.equal(run(['--inputs', filename, '--ignore']).status, 1);
  } finally { fs.rmSync(dir, { recursive: true }); }
});
