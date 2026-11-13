#!/usr/bin/env node
"use strict";

// SMS v2 AI template worker. Runs as the `sms-v2-template-worker` service, on the
// production backend host (docker-compose.prod.yml, opt-in) or the private admin
// host (deploy/admin/compose.private.yml):
//   node src/sms_v2/jobs/template_worker_main.js          (service, loops until SIGTERM)
//   node src/sms_v2/jobs/template_worker_main.js --once   (one claim, then exit)
// Needs SMS_AI_WORKER_DATABASE_URL (or ADMIN_API_DATABASE_URL + SMS_V2_JOB_ADMIN_ID), GEMINI_API_KEY (paid tier),
// SMS_V2_AI_MODEL and SMS_V2_AI_TPM. Gemini sees only redacted layouts that pass
// redactionError in ../ai_templates.js, never message text.

const { setTimeout: delay } = require("node:timers/promises");
const { openRuleAdminStore } = require("../admin_store");
const { openAiWorkerStore } = require("../ai_worker_store");
const { createAdminDbHelpers } = require("../../admin/server");
const {
  workerConfig,
  createPgWorkerStore,
  createGeminiTemplateProvider,
  runTemplateWorkerOnce,
  busyWaitMs,
} = require("../template_worker");
const {
  createPgSuggestionStore,
  runSuggestionOnce,
} = require("../merchant_suggestions");

// One pass of the worker: a layout first; when none is waiting, a shop left in
// "Other" (only if the admin switched shop suggestions on).
async function runWorkerCycle({ layoutStore, suggestionStore, provider, config }) {
  const layout = await runTemplateWorkerOnce({ store: layoutStore, provider, config });
  if (layout.status !== "idle" || !suggestionStore) return layout;
  const shop = await runSuggestionOnce({ store: suggestionStore, provider, config });
  return shop.status === "disabled" ? layout : { ...shop, job: "shop" };
}

// Two ways to reach the database, chosen by which URL the host provides:
//  - SMS_AI_WORKER_DATABASE_URL: the least-privilege `sms_ai_worker` login. This
//    is the production path; it has no admin identity and no shop suggestions.
//  - ADMIN_API_DATABASE_URL + SMS_V2_JOB_ADMIN_ID: the private admin API login
//    (local console and tests).
async function openStores(env = process.env) {
  if (env.SMS_AI_WORKER_DATABASE_URL) {
    const { pool, transaction } = await openAiWorkerStore({ env });
    return { pool, store: createPgWorkerStore({ transaction }), suggestionStore: null };
  }
  const adminId = env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) throw new Error("SMS_V2_JOB_ADMIN_ID_required");
  const { pool } = await openRuleAdminStore({ env });
  const helpers = createAdminDbHelpers(pool);
  return {
    pool,
    store: createPgWorkerStore({ ...helpers, adminId }),
    suggestionStore: createPgSuggestionStore({ ...helpers, adminId }),
  };
}

async function main() {
  const config = workerConfig();
  const provider = createGeminiTemplateProvider();
  const { pool, store, suggestionStore } = await openStores();
  let stopped = false;
  let lastCleanup = 0;
  let consecutiveBusy = 0;
  const stop = () => {
    stopped = true;
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    do {
      const result = await runWorkerCycle({ layoutStore: store, suggestionStore, provider, config });
      // Metadata only. Templates, prompts and provider responses are private.
      console.log(
        JSON.stringify({
          event: "sms_v2_template_worker",
          status: result.status,
        }),
      );
      // Housekeeping when nothing is waiting: at most hourly.
      if (result.status === "idle" && Date.now() - lastCleanup > 3600000) {
        lastCleanup = Date.now();
        try {
          console.log(JSON.stringify({ event: "sms_v2_ai_cleanup", cleared: await store.cleanupDecided() }));
        } catch (error) {
          console.error("SMS v2 AI cleanup failed", error.code || error.name);
        }
        // Layouts that failed through no fault of their own get another go (a few times each).
        try {
          if (typeof store.requeueFailed === "function")
            console.log(JSON.stringify({ event: "sms_v2_ai_requeue", requeued: await store.requeueFailed() }));
        } catch (error) {
          console.error("SMS v2 AI requeue failed", error.code || error.name);
        }
      }
      consecutiveBusy = result.status === "provider_busy" ? consecutiveBusy + 1 : 0;
      if (process.argv.includes("--once") || stopped) break;
      // disabled: an admin switched AI drafting off. budget: this month's cap is
      // spent. Layouts wait in the queue meanwhile.
      // provider_busy: Gemini is overloaded; wait (longer each time in a row) rather than fail layouts.
      await delay(
        result.status === "provider_busy"
          ? busyWaitMs({ retryAfterMs: result.retryAfterMs }, consecutiveBusy)
          : result.status === "idle"
          ? 15000
          : result.status === "capacity" || result.status === "disabled"
            ? 60000
            : result.status === "budget"
              ? 600000
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
    console.error("SMS v2 template worker stopped", error.code || error.name, String(error.message).slice(0, 200));
    process.exitCode = 1;
  });
}

module.exports = { main, runWorkerCycle, openStores };
