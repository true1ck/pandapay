#!/usr/bin/env node
'use strict';
/**
 * Hourly SMS v2 rule jobs: roll up profile-level stats, then auto-pause any
 * testers/pct5/pct25 version with >= 50 hits in 24 hours whose correction rate
 * is above max(1%, 2x the previous version's rate), then re-mint bundles.
 *
 *   node api/scripts/run_sms_v2_rule_jobs.js --admin-id <admin_users.id>
 *
 * Cron (UTC), on any host with DATABASE_URL and the signing key:
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
  const { withUserClient, pool } = require('../src/db');
  const { createPgStore } = require('../src/sms_v2/rules_store');
  const { runRuleJobs } = require('../src/sms_v2/rule_stats');
  const store = createPgStore({ withUserClient });
  const out = await runRuleJobs({ store, signer, adminId });
  console.log(JSON.stringify(out));
  await pool.end();
}

main().catch((err) => { console.error('rule jobs failed:', err && (err.code || err.message)); process.exit(1); });
