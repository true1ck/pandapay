#!/usr/bin/env node
"use strict";

// SMS v2 AI template worker. Runs as the `sms-v2-template-worker` service, on the
// production backend host (docker-compose.prod.yml, opt-in) or the private admin
// host (deploy/admin/compose.private.yml):
//   node src/sms_v2/jobs/template_worker_main.js          (service, loops until SIGTERM)
//   node src/sms_v2/jobs/template_worker_main.js --once   (one claim, then exit)
// Uses SMS_AI_WORKER_DATABASE_URL (or ADMIN_API_DATABASE_URL + SMS_V2_JOB_ADMIN_ID).
// With SMS_V2_AI_SERVICE_URL and SMS_V2_AI_SERVICE_TOKEN, sends only redacted
// layouts to PandaPay AI. Without them (or with a malformed token or URL) the
// worker stays up and idle: drafting pauses, nothing else is affected.

const fs = require("node:fs");
const { setTimeout: delay } = require("node:timers/promises");
const { openRuleAdminStore } = require("../admin_store");
const { openAiWorkerStore } = require("../ai_worker_store");
const { createAdminDbHelpers } = require("../../admin/server");
const { createAiServiceProvider } = require("../ai_service_provider");
const {
  workerConfig,
  createPgWorkerStore,
  runTemplateWorkerOnce,
  busyWaitMs,
  validateDraftSafely,
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
const { createOutageRecovery } = require("./outage_recovery");
const { createDraftAudit } = require("./draft_audit");

// One pass of the worker: a layout first; when none is waiting, a shop left in
// "Other" (only if the admin switched shop suggestions on).
async function runWorkerCycle({ layoutStore, suggestionStore, provider, config, shutdown }) {
  const layout = await runTemplateWorkerOnce({ store: layoutStore, provider, config, shutdown });
  if (layout.status !== "idle" || !suggestionStore || typeof provider.generateLayout === "function") return layout;
  const shop = await runSuggestionOnce({ store: suggestionStore, provider, config });
  return shop.status === "disabled" ? layout : { ...shop, job: "shop" };
}

// Two ways to reach the database, chosen by which URL the host provides:
//  - SMS_AI_WORKER_DATABASE_URL: the least-privilege `sms_ai_worker` login. This
//    is the production path; it has no admin identity and no shop suggestions.
//  - ADMIN_API_DATABASE_URL + SMS_V2_JOB_ADMIN_ID: the private admin API login
//    (local console and tests).
async function openStores(env = process.env, draftingVersion) {
  if (env.SMS_AI_WORKER_DATABASE_URL) {
    const { pool, transaction } = await openAiWorkerStore({ env });
    return { pool, store: createPgWorkerStore({ transaction, draftingVersion }), suggestionStore: null };
  }
  const adminId = env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) throw new Error("SMS_V2_JOB_ADMIN_ID_required");
  const { pool } = await openRuleAdminStore({ env });
  const helpers = createAdminDbHelpers(pool);
  return {
    pool,
    store: createPgWorkerStore({ ...helpers, adminId, draftingVersion }),
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

// The PandaPay AI client, or null (with a metadata-only log) when it is not set up or its settings are malformed.
// Never throws: a bad setting must not crash-loop the container.
function chooseProvider(log, env = process.env) {
  try {
    const provider = createAiServiceProvider({ env, logger: log });
    if (provider) return provider;
    log({ event: "sms_v2_ai_service", status: "not_configured" });
  } catch (error) {
    log({ event: "sms_v2_ai_service", status: "misconfigured", code: String(error?.message).slice(0, 60) });
  }
  return null;
}

async function main() {
  const once = process.argv.includes("--once");
  const config = workerConfig();
  const log = (line) => console.log(JSON.stringify(line));
  const provider = chooseProvider(log);
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
  // No usable provider: idle until told to stop (the database is not touched). A fixed setting needs a restart.
  if (!provider) {
    if (once) return "stopped";
    while (!stopped()) {
      await sleep(300000);
      if (!stopped()) log({ event: "sms_v2_ai_service", status: "idle_no_provider" });
    }
    return "stopped";
  }
  // Durable jobs: layouts are stamped with this version, and an operator bumps it to have failed layouts drafted again.
  const draftingVersion = process.env.SMS_V2_AI_DRAFTING_VERSION || provider.promptVersion;
  if (!/^[a-zA-Z0-9_.-]{1,64}$/.test(draftingVersion)) throw new Error("SMS_V2_AI_DRAFTING_VERSION_invalid");
  // A database login that fails or a connection that is down for a while is waited out, not a reason to exit.
  const opened = await openPatiently({
    open: () => openStores(process.env, draftingVersion),
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
  // Ready drafts are re-checked hourly with today's checks and repaired when they can be (draft_audit.js).
  const audit = createDraftAudit({ store, validate: (rule, template, model) => validateDraftSafely(rule, template, model, []), log,
    mode: ["off", "dry"].includes(process.env.SMS_V2_DRAFT_AUDIT) ? process.env.SMS_V2_DRAFT_AUDIT : "on" });
  // Layouts held back by an AI service outage are released as soon as the service answers again (not after 24 h).
  const recovery = createOutageRecovery({
    store,
    probe: typeof provider.isUp === "function" ? () => provider.isUp() : null,
    log,
  });
  try {
    return await runResilientLoop({
      once,
      isStopped: stopped,
      sleep,
      log,
      headroom: () => currentHeadroom(settings),
      runCycle: () => runWorkerCycle({ layoutStore: store, suggestionStore, provider, config, shutdown: stopping.signal }),
      // Housekeeping when nothing is waiting: at most hourly.
      afterCycle: async (result) => {
        // A durable job that was rescheduled has its own due time, so only an unscheduled busy answer is waited out here.
        consecutiveBusy = result.status === "provider_busy" && !result.rescheduled ? consecutiveBusy + 1 : 0;
        // Looks at most every 2 minutes and never throws (jobs/outage_recovery.js).
        await recovery.check();
        if (result.status === "idle") await audit.check();
        if (result.status === "idle" && Date.now() - lastCleanup > 3600000) {
          lastCleanup = Date.now();
          try {
            console.log(JSON.stringify({ event: "sms_v2_ai_cleanup", cleared: await store.cleanupDecided() }));
          } catch (error) {
            console.error("SMS v2 AI cleanup failed", error.code || error.name);
          }
          // Layouts that failed through no fault of their own get another go (a few times each).
          try {
            // Slow retry of layouts that failed for reasons that can pass (the AI was down or answered badly): 1, 3, 9 and 27 days.
            if (typeof store.requeueStale === "function")
              console.log(JSON.stringify({ event: "sms_v2_ai_requeue_stale", requeued: await store.requeueStale() }));
            if (typeof store.requeueFailed === "function")
              console.log(JSON.stringify({ event: "sms_v2_ai_requeue", requeued: await store.requeueFailed(provider.promptVersion ?? PROMPT_VERSION) }));
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
        result.status === "provider_busy" && !result.rescheduled
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

module.exports = { main, runWorkerCycle, openStores, chooseProvider };
