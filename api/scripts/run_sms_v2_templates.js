#!/usr/bin/env node
'use strict';
// Kept so existing runbook commands work. The worker lives in
// src/sms_v2/jobs/template_worker_main.js, which ships in the API image; the
// private admin host runs it as the `sms-v2-template-worker` service.
require('../src/sms_v2/jobs/template_worker_main').main().catch((error) => {
  console.error('SMS v2 template worker stopped', error.code || error.name);
  process.exitCode = 1;
});
