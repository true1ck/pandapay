"use strict";

// Re-checks the AI drafts that are already "ready" (the rules phones apply) with today's checks.
//
// 21 Nov 2026: 15 of the 123 ready drafts fail today's validator. They were accepted before the sanity checks existed
// (most take an account mask from a name slot, which attributes spending to the wrong account). A draft that fails is
// repaired the same way a new one is (draft_repair.js); if the repaired draft passes it replaces the old one (phones pick
// the new version up on their next sync). A draft that cannot be repaired is left exactly as it is and counted: nothing is
// ever deleted or re-queued here.
//
// Runs at most once an hour, from the worker loop when it is idle. Never throws. The replace is a compare-and-set on the
// draft as it was read, so a draft changed meanwhile (an admin decision, a redraft) is never overwritten.

const { repairEmit } = require("../draft_repair");
const { parseLayout } = require("../layout_matcher");
const { draftLayout } = require("../draft_layout");

const EVERY_MS = 60 * 60_000;

// mode: "on" repairs, "dry" only counts what it would repair, "off" does nothing (SMS_V2_DRAFT_AUDIT in the worker).
function createDraftAudit({ store, validate, now = Date.now, log = () => {}, everyMs = EVERY_MS, mode = "on" }) {
  const supported = mode !== "off" && typeof store?.readyDraftsForAudit === "function" && typeof store?.replaceReadyDraft === "function";
  let lastRun = -Infinity;
  const parse = (value) => (typeof value === "string" ? JSON.parse(value) : value);

  async function run() {
    const result = { checked: 0, valid: 0, repaired: 0, unrepairable: 0 };
    let skipped = 0;
    for (const row of await store.readyDraftsForAudit()) {
      const rule = parse(row.ai_draft);
      if (!rule || !Array.isArray(rule.emit)) continue;
      result.checked += 1;
      // The worker validated the cleaned layout (draft_layout.js), so the audit must too, or an old alias tag reads as a mismatch.
      const body = draftLayout(row.redacted_body);
      const template = { template_hash: row.template_hash, sender_brand: row.sender_brand, redacted_body: body };
      const model = String(rule.createdBy ?? row.ai_model ?? "").replace(/^ai:/, "");
      if (!(await validate(rule, template, model)).length) {
        result.valid += 1;
        continue;
      }
      let slots;
      try { slots = parseLayout(body).slots; } catch { slots = []; }
      const { emit } = repairEmit(rule.emit, slots);
      const repaired = { ...rule, emit };
      if ((await validate(repaired, template, model)).length) {
        result.unrepairable += 1;
        continue;
      }
      if (mode === "dry") {
        result.wouldRepair = (result.wouldRepair ?? 0) + 1;
        continue;
      }
      if (await store.replaceReadyDraft(row.template_hash, rule, repaired)) {
        result.repaired += 1;
        // What the draft meant before: enough to put it back by hand if a repair ever turns out wrong (no message text in it).
        log({ event: "sms_v2_ai_draft_replaced", template_hash: row.template_hash, before_emit: rule.emit });
      } else skipped += 1;
    }
    log({ event: "sms_v2_ai_draft_audit", ...result });
    return skipped ? { ...result, skipped } : result;
  }

  return {
    run,
    /** Call after each idle worker cycle; returns the result when it ran, else null. Never throws. */
    async check() {
      if (!supported || now() - lastRun < everyMs) return null;
      lastRun = now();
      try {
        return await run();
      } catch (error) {
        log({ event: "sms_v2_ai_draft_audit_failed", code: String(error?.code || error?.name || "error").slice(0, 40) });
        return null;
      }
    },
  };
}

module.exports = { createDraftAudit, EVERY_MS };
