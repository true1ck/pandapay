#!/usr/bin/env node
"use strict";

const { setTimeout: delay } = require("node:timers/promises");
const { openRuleAdminStore } = require("../src/sms_v2/admin_store");
const { createAdminDbHelpers } = require("../src/admin/server");
const {
  workerConfig,
  createPgWorkerStore,
  createGeminiTemplateProvider,
  runTemplateWorkerOnce,
} = require("../src/sms_v2/template_worker");

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
main().catch((error) => {
  console.error("SMS v2 template worker stopped", error.code || error.name);
  process.exitCode = 1;
});
