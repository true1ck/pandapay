#!/usr/bin/env node
'use strict';
// Kept so existing runbook commands work. The job lives in
// src/sms_v2/jobs/rule_jobs_main.js, which ships in the API image; the private
// admin host runs it as the `sms-v2-rule-jobs` service with --loop.
//   node api/scripts/run_sms_v2_rule_jobs.js --admin-id <admin_users.id>
require('../src/sms_v2/jobs/rule_jobs_main').main().catch((error) => {
  console.error('rule jobs failed:', error.code || error.message);
  process.exit(error.exitCode || 1);
});
