#!/usr/bin/env node
"use strict";

// SMS v2 AI template worker. Runs as the `sms-v2-template-worker` service on the
// private admin host only (deploy/admin/compose.private.yml):
//   node src/sms_v2/jobs/template_worker_main.js          (service, loops until SIGTERM)
//   node src/sms_v2/jobs/template_worker_main.js --once   (one claim, then exit)
// Needs ADMIN_API_DATABASE_URL, SMS_V2_JOB_ADMIN_ID, GEMINI_API_KEY (paid tier),
// SMS_V2_AI_MODEL and SMS_V2_AI_TPM. Gemini sees only redacted layouts that pass
// redactionError in ../ai_templates.js, never message text.

const { setTimeout: delay } = require("node:timers/promises");
const { openRuleAdminStore } = require("../admin_store");
const { createAdminDbHelpers } = require("../../admin/server");
const {
  workerConfig,
  createPgWorkerStore,
  createGeminiTemplateProvider,
  runTemplateWorkerOnce,
} = require("../template_worker");

async function main() {
  const adminId = process.env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) throw new Error("SMS_V2_JOB_ADMIN_ID_required");
  const config = workerConfig();
  const provider = createGeminiTemplateProvider();
  const { pool } = await openRuleAdminStore();
  const store = createPgWorkerStore({ ...createAdminDbHelpers(pool), adminId });
  let stopped = false;
  const stop = () => {
    stopped = true;
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    do {
      const result = await runTemplateWorkerOnce({ store, provider, config });
      // Metadata only. Templates, prompts and provider responses are private.
      console.log(
        JSON.stringify({
          event: "sms_v2_template_worker",
          status: result.status,
        }),
      );
      if (process.argv.includes("--once") || stopped) break;
      await delay(
        result.status === "idle"
          ? 15000
          : result.status === "capacity"
            ? 60000
            : 1000,
      );
    } while (!stopped);
  } finally {
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error("SMS v2 template worker stopped", error.code || error.name);
    process.exitCode = 1;
  });
}

module.exports = { main };
