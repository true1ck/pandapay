#!/usr/bin/env node
'use strict';

// Offline planning only: no environment loading, database calls or deployment.
const fs = require('node:fs');
const FORMAT = 'pandapay-connection-budget-v1';
const REPORT_FORMAT = 'pandapay-connection-budget-report-v1';
const ID = /^[a-z][a-z0-9_-]{0,47}$/;
const MAX_AGE_MS = 48 * 60 * 60 * 1000;
// Source-reviewed constructors: api/src/{db,service_pools}.js,
// auth/src/{db,services/consoleBrowserRuntime,services/accountLifecycleRuntime}.js,
// api/src/sms_learning_worker_runner.js and the two maintenance CLIs.
// rewards-worker imports api/src/db.js, including its optional service pools.
const MODELS = Object.freeze({
  api: { main: 'configured', partnerWebhook: 2, imapWorker: 2, accountLifecycle: 1 },
  auth: { main: 'configured', consoleSession: 3, authLifecycle: 2 },
  'rewards-worker': { main: 'configured', partnerWebhook: 2, imapWorker: 2, accountLifecycle: 1 },
  'sms-learning-worker': { main: 2 },
  'gemini-worker': {}, // HTTP fan-out is capacity work, but not a local PG pool.
  'product-maintenance': { main: 1 },
  'auth-retention-maintenance': { ledger: 1, retention: 1 },
  'backup-status-publisher': { main: 1 },
  'maintenance-alert-delivery': { main: 1 },
});

function fields(value, allowed, required = allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some(key => !allowed.includes(key)) ||
      required.some(key => !Object.hasOwn(value, key))) throw new Error('Invalid connection budget fields');
}
function integer(value, min = 0, max = 1000000, nullable = false) {
  if (nullable && value === null) return;
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error('Invalid connection budget number');
}
function date(value) {
  if (value !== null && (typeof value !== 'string' || value.length > 32 ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value) ||
      !Number.isFinite(Date.parse(value)))) throw new Error('Invalid connection budget timestamp');
}
function fresh(value, now) {
  const time = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(time) && time <= now + 300000 && time >= now - MAX_AGE_MS;
}

function template() {
  return {
    format: FORMAT, inventoryReviewed: false, reviewedAt: null, primaryCluster: 'primary',
    clusters: [{ id: 'primary', limitsVerified: false, verifiedAt: null, maxConnections: null,
      reservedConnections: null, providerConnections: null, operationalConnections: null, safetyConnections: null }],
    processes: Object.entries(MODELS).map(([kind, pools]) => ({
      id: kind, kind, replicas: ['api', 'auth', 'rewards-worker'].includes(kind) ? 1 : 0,
      overlapReplicas: 0,
      ...(Object.values(pools).includes('configured') ? { dbPoolMax: 10 } : {}),
      pools: Object.fromEntries(Object.keys(pools).map(pool => [pool, ['main', 'ledger', 'retention'].includes(pool) ? 'primary' : null])),
    })),
  };
}

function validateBudget(value) {
  fields(value, ['format', 'inventoryReviewed', 'reviewedAt', 'primaryCluster', 'clusters', 'processes']);
  if (value.format !== FORMAT || typeof value.inventoryReviewed !== 'boolean') throw new Error('Invalid connection budget format');
  date(value.reviewedAt);
  if (!Array.isArray(value.clusters) || value.clusters.length < 1 || value.clusters.length > 8 ||
      !Array.isArray(value.processes) || value.processes.length < 1 || value.processes.length > 64) throw new Error('Connection inventory exceeds bounds');
  const clusterIds = new Set(), processIds = new Set(), kinds = new Set();
  for (const cluster of value.clusters) {
    fields(cluster, ['id', 'limitsVerified', 'verifiedAt', 'maxConnections', 'reservedConnections', 'providerConnections', 'operationalConnections', 'safetyConnections']);
    if (typeof cluster.id !== 'string' || !ID.test(cluster.id) || clusterIds.has(cluster.id) || typeof cluster.limitsVerified !== 'boolean') throw new Error('Invalid cluster inventory');
    clusterIds.add(cluster.id); date(cluster.verifiedAt);
    integer(cluster.maxConnections, 1, 1000000, true);
    for (const key of ['reservedConnections', 'providerConnections', 'operationalConnections', 'safetyConnections']) integer(cluster[key], 0, 1000000, true);
  }
  if (!clusterIds.has(value.primaryCluster)) throw new Error('Unknown primary cluster');
  for (const process of value.processes) {
    const model = typeof process?.kind === 'string' && Object.hasOwn(MODELS, process.kind) ? MODELS[process.kind] : null;
    if (!model) throw new Error('Unknown process kind');
    const configured = Object.values(model).includes('configured');
    fields(process, ['id', 'kind', 'replicas', 'overlapReplicas', 'pools', ...(configured ? ['dbPoolMax'] : [])]);
    if (typeof process.id !== 'string' || !ID.test(process.id) || processIds.has(process.id)) throw new Error('Invalid process inventory');
    processIds.add(process.id); kinds.add(process.kind);
    integer(process.replicas, 0, 10000); integer(process.overlapReplicas, 0, 10000);
    if (configured) integer(process.dbPoolMax, 1, 100);
    if (process.replicas === 0 && process.overlapReplicas !== 0) throw new Error('Overlap requires a serving process');
    fields(process.pools, Object.keys(model));
    for (const [name, cluster] of Object.entries(process.pools)) {
      if (cluster !== null && !clusterIds.has(cluster)) throw new Error('Unknown pool cluster');
      if (process.replicas > 0 && ['main', 'ledger', 'retention'].includes(name) && cluster === null) throw new Error('Serving process needs its primary connections');
    }
  }
  if (Object.keys(MODELS).some(kind => !kinds.has(kind))) throw new Error('Every known process kind requires an explicit inventory entry, including disabled ones');
  return value;
}

function evaluateBudget(value, { now = Date.now() } = {}) {
  validateBudget(value);
  const issues = [], clusters = new Map(value.clusters.map(cluster => [cluster.id, {
    id: cluster.id, max_connections: cluster.maxConnections, steady_connections: 0, rollout_connections: 0,
    reserved_connections: cluster.reservedConnections, provider_connections: cluster.providerConnections,
    operational_connections: cluster.operationalConnections, safety_connections: cluster.safetyConnections,
  }]));
  if (!value.inventoryReviewed || !fresh(value.reviewedAt, now)) issues.push('inventory_review_missing_or_stale');
  for (const kind of ['api', 'auth']) if (!value.processes.some(process => process.kind === kind && process.replicas > 0)) issues.push(`${kind}_serving_inventory_missing`);
  const processes = value.processes.map(process => {
    const contributions = [];
    for (const [name, size] of Object.entries(MODELS[process.kind])) {
      const cluster = process.pools[name];
      if (cluster === null) continue;
      const maximum = size === 'configured' ? process.dbPoolMax : size;
      const steady = maximum * process.replicas, rollout = maximum * (process.replicas + process.overlapReplicas);
      const total = clusters.get(cluster); total.steady_connections += steady; total.rollout_connections += rollout;
      contributions.push({ pool: name, cluster, max_per_process: maximum, steady_connections: steady, rollout_connections: rollout });
    }
    return { id: process.id, kind: process.kind, replicas: process.replicas, overlap_replicas: process.overlapReplicas, contributions };
  });
  for (const input of value.clusters) {
    const output = clusters.get(input.id);
    const verified = input.limitsVerified && fresh(input.verifiedAt, now) &&
      ['maxConnections', 'reservedConnections', 'providerConnections', 'operationalConnections', 'safetyConnections'].every(key => Number.isSafeInteger(input[key])) &&
      input.operationalConnections >= 1 && input.safetyConnections >= 1;
    output.limits_verified = verified;
    output.total_reserved_connections = verified ? input.reservedConnections + input.providerConnections + input.operationalConnections + input.safetyConnections : null;
    output.rollout_required_connections = verified ? output.rollout_connections + output.total_reserved_connections : null;
    output.remaining_connections = verified ? input.maxConnections - output.rollout_required_connections : null;
    output.fits = verified && output.remaining_connections >= 0;
    if (!verified) issues.push(`${input.id}_limits_missing_or_stale`);
    else if (!output.fits) issues.push(`${input.id}_connection_budget_exceeded`);
  }
  return { format: REPORT_FORMAT, generated_at: new Date(now).toISOString(), read_only: true,
    model: 'Conservative maximum: every configured client slot counts as one backend connection. No transaction-pooler discount or throughput guarantee.',
    trust: 'Operator-reviewed aliases, replica ceilings and limits; actual running configuration and provider reserves are not discovered by this offline check.',
    primary_cluster: value.primaryCluster, processes, clusters: [...clusters.values()], issues, budget_ready: issues.length === 0 };
}

function readInput(filename) {
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.size > 128 * 1024) throw new Error('Budget input must be a bounded regular file');
    const bytes = Buffer.alloc(before.size + 1), size = fs.readSync(fd, bytes, 0, bytes.length, 0), after = fs.fstatSync(fd);
    if (size !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs) throw new Error('Budget input changed');
    return JSON.parse(bytes.subarray(0, size).toString('utf8'));
  } finally { fs.closeSync(fd); }
}
function main(args = process.argv.slice(2)) {
  if (args.length === 1 && args[0] === '--template') { process.stdout.write(JSON.stringify(template(), null, 2) + '\n'); return; }
  if (args.length < 2 || args.length > 3 || args[0] !== '--inputs' || (args.length === 3 && args[2] !== '--strict')) throw new Error('Usage: connection_budget.js --template | --inputs FILE [--strict]');
  const report = evaluateBudget(readInput(args[1]));
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  if (args.includes('--strict') && !report.budget_ready) process.exitCode = 2;
}
if (require.main === module) try { main(); } catch (_) { process.stderr.write('Connection budget review failed; no approval produced.\n'); process.exitCode = 1; }
module.exports = { FORMAT, REPORT_FORMAT, MODELS, template, validateBudget, evaluateBudget, readInput, main };
