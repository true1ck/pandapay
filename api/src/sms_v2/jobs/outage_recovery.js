"use strict";

// Releases layouts that are waiting only because the AI service was down, as soon as it answers again.
//
// A layout whose drafting failed because the service was unavailable waits 5 min, then 30 min, then 24 hours
// (pandapay.sms_v2_draft_retry_delay). On 20 Nov 2026 a short outage parked every pending layout for a day although the
// service was back within the hour. This looks every 2 minutes: when such layouts are waiting (store.outageDeferredCount)
// and the service answers its health check, they become due at once (store.releaseAfterOutage). Only systemic failures
// are released, never bad drafts; at most one release every 10 minutes, so a flapping service cannot burn their tries.
// Sujay's limits still apply after a release (tries per cycle, exhausted cycles, versions).

const CHECK_EVERY_MS = 2 * 60_000;
const MIN_RELEASE_GAP_MS = 10 * 60_000;

function createOutageRecovery({ store, probe, now = Date.now, log = () => {}, checkEveryMs = CHECK_EVERY_MS, minGapMs = MIN_RELEASE_GAP_MS }) {
  const supported = typeof store?.outageDeferredCount === "function" && typeof store?.releaseAfterOutage === "function"
    && typeof probe === "function";
  let lastCheck = -Infinity;
  let lastRelease = -Infinity;
  return {
    /** Call after each worker cycle; returns { waiting, released } when it looked, else null. Never throws. */
    async check() {
      if (!supported || now() - lastCheck < checkEveryMs) return null;
      lastCheck = now();
      try {
        const waiting = Number(await store.outageDeferredCount());
        if (!(waiting > 0) || now() - lastRelease < minGapMs) return null;
        if (!(await probe())) {
          log({ event: "sms_v2_ai_outage", waiting, serviceUp: false });
          return { waiting, released: 0 };
        }
        const released = Number(await store.releaseAfterOutage());
        lastRelease = now();
        log({ event: "sms_v2_ai_recovered", waiting, released });
        return { waiting, released };
      } catch (error) {
        log({ event: "sms_v2_ai_outage_check_failed", code: String(error?.code || error?.name || "error").slice(0, 40) });
        return null;
      }
    },
  };
}

module.exports = { createOutageRecovery, CHECK_EVERY_MS, MIN_RELEASE_GAP_MS };
