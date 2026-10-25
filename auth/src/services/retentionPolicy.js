'use strict';

// No retention policy is enabled implicitly. Database-access diagnostics are
// distinct from the security audit ledger, which this tool never deletes.
const SCOPES = Object.freeze({
  db_access_log: Object.freeze({ variable: 'AUTH_DB_ACCESS_LOG_RETENTION_DAYS', minimum: 30, maximum: 3650 }),
  expired_abuse_state: Object.freeze({ variable: 'AUTH_ABUSE_STATE_RETENTION_DAYS', minimum: 1, maximum: 365 }),
});

function boundedInteger(value, name, minimum, maximum, fallback) {
  if (value === undefined || value === '') return fallback;
  if (!/^[1-9][0-9]*$/.test(String(value))) throw new Error(`${name} must be a positive integer`);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) throw new Error(`${name} is outside its supported range`);
  return number;
}

function validateRetentionPolicy(policy) {
  if (!policy || !Array.isArray(policy.scopes) || policy.scopes.length > Object.keys(SCOPES).length) throw new Error('Invalid retention policy');
  const seen = new Set();
  for (const item of policy.scopes) {
    const rule = item && Object.hasOwn(SCOPES, item.scope) ? SCOPES[item.scope] : undefined;
    if (!rule || seen.has(item.scope) || !Number.isInteger(item.days) || item.days < rule.minimum || item.days > rule.maximum) throw new Error('Invalid retention scope');
    seen.add(item.scope);
  }
  for (const [name, minimum, maximum] of [['batchSize', 1, 1000], ['maxBatches', 1, 100], ['maxDurationMs', 100, 60000]]) {
    if (!Number.isInteger(policy[name]) || policy[name] < minimum || policy[name] > maximum) throw new Error('Invalid retention resource limit');
  }
  return policy;
}

function readRetentionPolicy(env = process.env) {
  const scopes = [];
  for (const [scope, rule] of Object.entries(SCOPES)) {
    const days = boundedInteger(env[rule.variable], rule.variable, rule.minimum, rule.maximum);
    if (days !== undefined) scopes.push(Object.freeze({ scope, days }));
  }
  return Object.freeze(validateRetentionPolicy({
    scopes: Object.freeze(scopes),
    batchSize: boundedInteger(env.AUTH_RETENTION_BATCH_SIZE, 'AUTH_RETENTION_BATCH_SIZE', 1, 1000, 100),
    maxBatches: boundedInteger(env.AUTH_RETENTION_MAX_BATCHES, 'AUTH_RETENTION_MAX_BATCHES', 1, 100, 10),
    maxDurationMs: boundedInteger(env.AUTH_RETENTION_MAX_DURATION_MS, 'AUTH_RETENTION_MAX_DURATION_MS', 100, 60000, 10000),
  }));
}

module.exports = { readRetentionPolicy, validateRetentionPolicy };
