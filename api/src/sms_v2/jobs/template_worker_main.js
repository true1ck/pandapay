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

const fs = require("node:fs");
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
  PROMPT_VERSION,
} = require("../template_worker");
const {
  createPgSuggestionStore,
  runSuggestionOnce,
} = require("../merchant_suggestions");
const {
  availableMbFromMeminfo,
  containerLimitMbFrom,
  guardSettings,
  memoryHeadroom,
  runResilientLoop,
  openPatiently,
} = require("./worker_resilience");

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

function readText(path) {
  try {
    return fs.readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

// Looked at before every job: this process's own memory and what the host has left.
function currentHeadroom(settings) {
  const rssMb = Math.round(process.memoryUsage().rss / 1048576);
  const availableMb = availableMbFromMeminfo(readText("/proc/meminfo"));
  return { ...memoryHeadroom({ rssMb, availableMb }, settings), rssMb };
}

async function main() {
  const once = process.argv.includes("--once");
  const config = workerConfig();
  const provider = createGeminiTemplateProvider();
  const stopping = new AbortController();
  const stopped = () => stopping.signal.aborted;
  const onSignal = () => stopping.abort();
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  // A wait ends at once when the process is told to stop, so a long wait never holds up a restart.
  const sleep = (ms) =>
    delay(ms, undefined, { signal: stopping.signal }).catch((error) => {
      if (error.name !== "AbortError") throw error;
    });
  // Metadata only. Templates, prompts and provider responses are private.
  const log = (line) => console.log(JSON.stringify(line));
  // A database login that fails or a connection that is down for a while is waited out, not a reason to exit.
  const opened = await openPatiently({
    open: () => openStores(),
    sleep,
    log,
    isStopped: stopped,
    once,
  });
  if (!opened) return "stopped"; // told to stop while still waiting for the database
  const { pool, store, suggestionStore } = opened;
  const settings = guardSettings(
    process.env,
    containerLimitMbFrom([
      () => readText("/sys/fs/cgroup/memory.max"),
      () => readText("/sys/fs/cgroup/memory/memory.limit_in_bytes"),
    ]),
  );
  let lastCleanup = 0;
  let consecutiveBusy = 0;
  try {
    return await runResilientLoop({
      once,
      isStopped: stopped,
      sleep,
      log,
      headroom: () => currentHeadroom(settings),
      runCycle: () => runWorkerCycle({ layoutStore: store, suggestionStore, provider, config }),
      // Housekeeping when nothing is waiting: at most hourly.
      afterCycle: async (result) => {
        consecutiveBusy = result.status === "provider_busy" ? consecutiveBusy + 1 : 0;
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
              console.log(JSON.stringify({ event: "sms_v2_ai_requeue", requeued: await store.requeueFailed(PROMPT_VERSION) }));
          } catch (error) {
            console.error("SMS v2 AI requeue failed", error.code || error.name);
          }
        }
      },
      // disabled: an admin switched AI drafting off. budget: this month's cap is
      // spent. Layouts wait in the queue meanwhile.
      // provider_busy: Gemini is overloaded; wait (longer each time in a row) rather than fail layouts.
      // capacity: Gemini's limits, or this host is short of memory: look again in a minute.
      // After a call to Gemini the worker rests for the console's gap (ai_min_gap_seconds), so a queue of layouts
      // reaches the provider one at a time, first in first out, never in a burst.
      nextDelayMs: (result) =>
        result.status === "provider_busy"
          ? busyWaitMs({ retryAfterMs: result.retryAfterMs }, consecutiveBusy)
          : result.status === "idle"
          ? 15000
          : result.gapSeconds > 0
            ? result.gapSeconds * 1000
            : result.status === "capacity" || result.status === "disabled"
              ? 60000
              : result.status === "budget"
                ? 600000
                : 1000,
    });
  } finally {
    process.removeListener("SIGINT", onSignal);
    process.removeListener("SIGTERM", onSignal);
    await pool.end().catch(() => {});
  }
}

if (require.main === module) {
  main()
    .then((outcome) => {
      // Near this container's memory limit: leave cleanly between jobs; the restart policy starts a fresh process.
      if (outcome === "recycle") process.exit(0);
    })
    .catch((error) => {
      console.error("SMS v2 template worker stopped", error.code || error.name, String(error.message).slice(0, 200));
      process.exitCode = 1;
    });
}

module.exports = { main, runWorkerCycle, openStores };
