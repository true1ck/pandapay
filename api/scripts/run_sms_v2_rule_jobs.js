#!/usr/bin/env node
'use strict';
/**
 * Hourly SMS v2 rule jobs: roll up profile-level stats, then auto-pause any
 * testers/pct5/pct25 version with >= 50 hits in 24 hours whose correction rate
 * is above max(1%, 2x the previous version's rate), then re-mint bundles, then
 * re-sign every active cohort bundle whose served copy expires within
 * SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS (default 72) or was signed by another key id.
 * The public API serves only these pre-signed copies and holds no key (LO-09). A
 * failure exits non-zero: alert on it, a bundle that is not refreshed expires in 7 days.
 *
 *   node api/scripts/run_sms_v2_rule_jobs.js --admin-id <admin_users.id>
 *
 * Cron (UTC), on a private maintenance host with ADMIN_API_DATABASE_URL and the signing key:
 *   7 * * * *  cd /app/api && node scripts/run_sms_v2_rule_jobs.js --admin-id $SMS_V2_JOB_ADMIN_ID
 */
function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function main() {
  const adminId = arg('admin-id') || process.env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) { console.error('usage: run_sms_v2_rule_jobs.js --admin-id <uuid>'); process.exit(2); }
  const { signerFromEnv } = require('../src/sms_v2/signer');
  const signer = signerFromEnv();
  if (!signer) { console.error('SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID are required'); process.exit(2); }
  const { openRuleAdminStore } = require('../src/sms_v2/admin_store');
  const { runRuleJobs } = require('../src/sms_v2/rule_stats');
  const { store, pool } = await openRuleAdminStore();
  try {
    const hours = process.env.SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS;
    const refreshBeforeMs = hours === undefined ? undefined : Number(hours) * 3600 * 1000;
    if (refreshBeforeMs !== undefined && !(refreshBeforeMs >= 3600 * 1000 && refreshBeforeMs <= 120 * 3600 * 1000)) {
      console.error('SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS must be between 1 and 120'); process.exit(2);
    }
    const out = await runRuleJobs({ store, signer, adminId, refreshBeforeMs });
    console.log(JSON.stringify(out));
  } finally { await pool.end(); }
}

main().catch((err) => { console.error('rule jobs failed:', err && (err.code || err.message)); process.exit(1); });
