'use strict';

/**
 * SMS v2 rule job: roll up profile-level stats, then auto-pause any
 * testers/pct5/pct25 version with >= 50 hits in 24 hours whose correction rate
 * is above max(1%, 2x the previous version's rate), then re-mint bundles, then
 * re-sign every active cohort bundle whose served copy expires within
 * SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS (default 72) or was signed by another key id.
 * The public API serves only these pre-signed copies and holds no key (LO-09).
 *
 * Service mode (private admin host, `sms-v2-rule-jobs` in deploy/admin/compose.private.yml):
 *   node src/sms_v2/jobs/rule_jobs_main.js --loop
 * runs at start-up and then at minute 7 of every hour (UTC). A failed run is
 * logged as {"event":"sms_v2_rule_jobs","status":"failed"} and retried next hour.
 *
 * One run (operator checkout or `docker compose run`):
 *   node src/sms_v2/jobs/rule_jobs_main.js --admin-id <admin_users.id>
 * exits non-zero on failure. A bundle that is not refreshed expires in 7 days.
 *
 * Needs ADMIN_API_DATABASE_URL, SMS_RULES_SIGNING_KEY, SMS_RULES_KEY_ID and
 * SMS_V2_JOB_ADMIN_ID (or --admin-id).
 */

const { setTimeout: delay } = require('node:timers/promises');
const { runRuleJobsLoop } = require('./schedule');

function configError(code) {
  return Object.assign(new Error(code), { code, exitCode: 2 });
}

function settings(argv, env) {
  const i = argv.indexOf('--admin-id');
  const adminId = (i >= 0 ? argv[i + 1] : undefined) || env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) throw configError('SMS_V2_JOB_ADMIN_ID_required');
  const hours = env.SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS;
  const refreshBeforeMs = hours === undefined || hours === '' ? undefined : Number(hours) * 3_600_000;
  if (refreshBeforeMs !== undefined && !(refreshBeforeMs >= 3_600_000 && refreshBeforeMs <= 120 * 3_600_000)) {
    throw configError('SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS_invalid');
  }
  const { signerFromEnv, SigningConfigError } = require('../signer');
  let signer;
  try {
    signer = signerFromEnv(env);
  } catch (error) {
    if (!(error instanceof SigningConfigError)) throw error;
    throw configError(env.SMS_RULES_SIGNING_KEY && env.SMS_RULES_KEY_ID
      ? 'SMS_RULES_SIGNING_KEY_invalid' : 'SMS_RULES_SIGNING_KEY_required');
  }
  if (!signer) throw configError('SMS_RULES_SIGNING_KEY_required');
  return { adminId, refreshBeforeMs, signer };
}

async function runOnce({ adminId, refreshBeforeMs, signer }, env = process.env) {
  const { openRuleAdminStore } = require('../admin_store');
  const { runRuleJobs } = require('../rule_stats');
  const { store, pool } = await openRuleAdminStore({ env });
  try {
    return await runRuleJobs({ store, signer, adminId, refreshBeforeMs });
  } finally {
    await pool.end();
  }
}

async function main(argv = process.argv, env = process.env) {
  const config = settings(argv, env);
  if (!argv.includes('--loop')) {
    console.log(JSON.stringify(await runOnce(config, env)));
    return;
  }
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
  try {
    await runRuleJobsLoop({
      runOnce: () => runOnce(config, env),
      sleep: (ms) => delay(ms, undefined, { signal: controller.signal }).catch(() => {}),
      log: (entry) => console.log(JSON.stringify(entry)),
      stopped: () => controller.signal.aborted,
    });
  } finally {
    process.removeListener('SIGTERM', stop);
    process.removeListener('SIGINT', stop);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error('rule jobs failed:', error.code || error.message);
    process.exit(error.exitCode || 1);
  });
}

module.exports = { main, runOnce, settings };
