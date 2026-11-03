'use strict';

// SMS pipeline v2 / WP-08: the feature-flag guard and the startup checks.
//
// requireSmsV2 answers 404 unless the `sms_pipeline_v2_enabled` row in
// feature_flags is on for the caller, using the same flag evaluation as the
// SMS intelligence rollout (sms_observation_migration.evaluateFeatureFlag).
// A missing row is off.

const fs = require('node:fs');
const path = require('node:path');
const { evaluateFeatureFlag } = require('../sms_observation_migration');
const { safeErrorCode } = require('../safeErrorCode');

const FLAG_KEY = 'sms_pipeline_v2_enabled';

async function readFlagRow(withUserClient) {
  const r = await withUserClient(null, (client) => client.query(
    'SELECT key, is_enabled, rollout_percent FROM feature_flags WHERE key = $1',
    [FLAG_KEY],
  ));
  return r.rows[0] || null;
}

/**
 * @param {object} o
 * @param {Function} o.withUserClient db.js helper (used by the default reader)
 * @param {Function} [o.readFlag] async () => {key,is_enabled,rollout_percent}|null
 * @param {number} [o.cacheMs] how long a read of the flag row is reused
 */
function createRequireSmsV2({ withUserClient, readFlag, cacheMs = 5000, now = Date.now }) {
  const read = readFlag || (() => readFlagRow(withUserClient));
  let cached = null;
  async function row() {
    if (cached && now() - cached.at < cacheMs) return cached.row;
    const value = await read();
    cached = { at: now(), row: value };
    return value;
  }
  return async function requireSmsV2(req, res, next) {
    let enabled;
    try {
      enabled = evaluateFeatureFlag(await row(), req.userId || null);
    } catch (err) {
      console.error('sms_v2 flag read failed', safeErrorCode(err));
      return res.status(503).json({ error: 'flag_unavailable' });
    }
    if (!enabled) return res.status(404).json({ error: 'not_found' });
    return next();
  };
}

// Where contracts.js will look (same resolution rule as contracts.js).
function contractsDir() {
  return process.env.SMS_V2_CONTRACTS_DIR
    ? path.resolve(process.env.SMS_V2_CONTRACTS_DIR)
    : path.resolve(__dirname, '../../../contracts/sms/v2');
}

/**
 * The server must not start without the contracts: every v2 route validates
 * against them. Throws a readable error instead of a bare ENOENT from Ajv.
 */
function assertContractsPresent(dir = contractsDir()) {
  const need = ['fact.schema.json', 'event.schema.json', path.join('api', 'facts_batch.request.schema.json')];
  const missing = need.filter((f) => !fs.existsSync(path.join(dir, f)));
  if (missing.length) {
    throw new Error(`SMS v2 contracts missing in ${dir} (${missing.join(', ')}); copy contracts/sms/v2 into the image or set SMS_V2_CONTRACTS_DIR`);
  }
  return dir;
}

module.exports = { FLAG_KEY, createRequireSmsV2, readFlagRow, contractsDir, assertContractsPresent };
