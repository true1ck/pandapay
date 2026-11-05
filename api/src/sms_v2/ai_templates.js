"use strict";

const { validateRequest } = require("./contracts");
const { createRequireSmsV2 } = require("./guard");
const { createPgStore } = require("./rules_store");
const { saveDraft, HttpError } = require("./rules_admin_route");
const { intakeOpen } = require("./settings");

const MAX_BODY = 20000;
// Every state a layout can be shown in. "rejected" is an admin decision on a
// draft; "blocked" is set by an admin and never reaches the AI.
const TEMPLATE_STATUSES = ["held", "queued", "working", "ready", "failed", "covered", "rejected", "blocked"];
const REJECT_REASONS = ["wrong_fact_type", "wrong_amount_role", "overmatches", "misses_fields", "should_be_ignored", "other"];
const UNREDACTED =
  /\d{6,}|[\w.+-]+@[\w.-]+|https?:\/\/|\bwww\.|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:\b|\/)|\+?\d(?:[ -]?\d){9,}/i;
const denied = (value) => value === false || value?.ok === false;

function redactionError(body) {
  if (typeof body !== "string" || !body.length || body.length > MAX_BODY)
    return "template_body_invalid";
  return UNREDACTED.test(body) ? "template_redaction_required" : null;
}

function createTemplateStore({ withUserClient }) {
  return {
    submit(profileId, items, eligible) {
      return withUserClient(profileId, async (client) => {
        const rows = await client.query(
          "SELECT pandapay.sms_v2_submit_templates($1::jsonb,$2) AS hash",
          [JSON.stringify(items), eligible === true],
        );
        return rows.rows.map((row) => row.hash);
      });
    },
    async results(profileId, cursor) {
      if (
        cursor !== null &&
        (typeof cursor !== "string" ||
          !/^[0-9]{1,19}$/.test(cursor) ||
          BigInt(cursor) > 9223372036854775807n)
      ) {
        throw new HttpError(400, "template_cursor_invalid");
      }
      return withUserClient(profileId, async (client) => {
        const rows = (
          await client.query(
            "SELECT * FROM pandapay.sms_v2_template_results($1::bigint)",
            [cursor || "0"],
          )
        ).rows;
        return {
          items: rows.map((row) => ({
            templateHash: row.template_hash,
            status:
              row.ai_status === "ready"
                ? "ready"
                : row.ai_status === "failed"
                  ? "failed"
                  : "queued",
            ruleId: row.ai_draft?.id || null,
            ruleVersion: row.ai_draft?.version || null,
            ...(row.ai_status === "ready" && row.ai_draft
              ? { rule: row.ai_draft }
              : {}),
          })),
          cursor: rows.at(-1)?.revision?.toString() || cursor || "0",
        };
      });
    },
  };
}

function createTemplateHandler({ store, security }) {
  return async (req, res) => {
    const check = validateRequest("unknown_templates", req.body);
    if (!check.ok) return res.status(400).json({ error: check.errors[0].code });
    const items = req.body.items;
    for (const item of items) {
      const error = redactionError(item.redactedBody);
      if (error || item.senderBrand.length > 32)
        return res.status(400).json({ error: error || "sender_brand_invalid" });
    }
    try {
      // An admin can pause all intake from the console (setting intake_enabled).
      // Phones keep their outbox and try again later.
      if (!(await intakeOpen(security, req))) {
        res.set("Retry-After", "3600");
        return res.status(503).json({ error: "learning_paused" });
      }
      if (denied(await security.verifyAttestation(req)))
        return res.status(403).json({ error: "attestation_required" });
      if (
        items.length &&
        denied(await security.checkRate(req, "unknown-templates", items.length))
      )
        return res.status(429).json({ error: "rate_limited" });
      const accepted = await store.submit(
        req.userId,
        items,
        req.smsV2Security?.sharedLearningEligible === true,
      );
      return res.status(202).json({ accepted });
    } catch (error) {
      if (error.code === "42501")
        return res
          .status(403)
          .json({ error: "sms_shared_learning_consent_required" });
      if (error.code === "P0050") {
        res.set("Retry-After", "86400");
        return res.status(429).json({ error: "template_daily_cap" });
      }
      if (error.code === "22023")
        return res.status(400).json({ error: "template_invalid" });
      console.error("sms_v2 templates unavailable", error.code || error.name);
      return res.status(503).json({ error: "templates_unavailable" });
    }
  };
}

function registerTemplates(
  app,
  { requireSmsV2, requireMember, withUserClient, hooks },
) {
  const store = createTemplateStore({ withUserClient });
  app.post(
    "/sms/v2/unknown-templates",
    requireSmsV2,
    requireMember,
    createTemplateHandler({ store, security: hooks.security }),
  );
  hooks.aiResultsSince = (profileId, cursor) =>
    store.results(profileId, cursor);
}

function registerPrivateTemplateRoutes(api) {
  const register = (method, path, operation) =>
    api.route(method, path, async (req, res, ctx) => {
      const withPrivateClient = (_id, fn) => ctx.withAdminClient(fn);
      const guard = createRequireSmsV2({
        withUserClient: withPrivateClient,
        cacheMs: 0,
      });
      return guard(req, res, async () => {
        try {
          return await operation(req, res, ctx);
        } catch (error) {
          if (error instanceof HttpError)
            return res.status(error.status).json({ error: error.code });
          if (error.code === "ADMIN_PERMISSION_DENIED")
            return res.status(403).json({ error: "admin_permission_required" });
          console.error(
            "sms_v2 template admin failed",
            error.code || error.name,
          );
          return res.status(500).json({ error: "templates_unavailable" });
        }
      });
    });
  register("GET", "/admin/sms/v2/templates", async (req, res, ctx) => {
    const status = req.query.status;
    if (status && !TEMPLATE_STATUSES.includes(status))
      throw new HttpError(400, "template_status_invalid");
    // "rejected" is a decision on a draft that now sits at ai_status failed.
    const rows = await ctx.withAdminClient((client) =>
      client.query(
        `SELECT t.template_hash,t.sender_brand,t.redacted_body,t.seen_count,t.distinct_profiles,t.ai_status,t.ai_draft,t.ai_model,t.failure_code,t.first_seen,t.last_seen,
                t.covered_by,t.admin_decision,t.admin_reason,t.admin_note,t.decided_at,
                p.hits::int AS "privateHits",p.corrected::int AS "privateCorrected",p.phones::int AS "privatePhones"
       FROM sms_v2_unknown_templates t
       LEFT JOIN LATERAL (
         SELECT sum(d.hits) AS hits,sum(d.corrected) AS corrected,max(d.devices) AS phones
           FROM sms_v2_rule_stats_daily d
          WHERE d.rule_id='AI-'||t.template_hash AND d.day>=(now() AT TIME ZONE 'utc')::date-30
       ) p ON p.phones IS NOT NULL
      WHERE ($1::text IS NULL
         OR ($1='rejected' AND t.admin_decision='rejected')
         OR ($1='failed' AND t.ai_status='failed' AND t.admin_decision IS DISTINCT FROM 'rejected')
         OR ($1 NOT IN ('rejected','failed') AND t.ai_status=$1))
      ORDER BY t.first_seen,t.template_hash LIMIT 200`,
        [status || null],
      ),
    );
    return res.json({ templates: rows.rows });
  });
  register(
    "POST",
    "/admin/sms/v2/templates/:hash/draft",
    async (req, res, ctx) => {
      if (!/^[a-f0-9]{64}$/.test(req.params.hash))
        throw new HttpError(400, "template_hash_invalid");
      const result = await ctx.withAdminClient(async (client) => {
        const template = (
          await client.query(
            "SELECT ai_draft FROM sms_v2_unknown_templates WHERE template_hash=$1 AND ai_status='ready' FOR SHARE",
            [req.params.hash],
          )
        ).rows[0];
        if (!template?.ai_draft)
          throw new HttpError(404, "template_draft_not_ready");
        const rule = {
          ...template.ai_draft,
          status: "draft",
          createdBy: `admin:${req.admin.userId}`,
        };
        // Promotion removes the private hash restriction so golden evaluation can
        // cover this format across messages, before normal reviewed publication.
        rule.match = { ...rule.match };
        delete rule.match.templateHash;
        const store = createPgStore({
          withUserClient: (_actor, fn) => fn(client),
        });
        const saved = await store.tx(req.admin.userId, (tx) =>
          saveDraft(tx, rule.id, rule, {
            adminId: req.admin.userId,
            now: new Date(),
          }),
        );
        // Creating the draft is the approval; later prompt changes are
        // evaluated against these approved drafts (dry run --eval).
        await client.query(
          `UPDATE sms_v2_unknown_templates SET admin_decision='approved',admin_reason=NULL,admin_note=NULL,decided_by=$2,decided_at=clock_timestamp()
            WHERE template_hash=$1`,
          [req.params.hash, req.admin.userId],
        );
        await client.query(
          "INSERT INTO admin_audit_log (admin_id,action,entity,entity_id,after_value) VALUES ($1,'sms_v2_template_approve','sms_v2_template',NULL,$2)",
          [req.admin.userId, JSON.stringify({ templateHash: req.params.hash, ruleId: rule.id })],
        );
        return saved;
      });
      return res.json(result);
    },
  );
  register(
    "POST",
    "/admin/sms/v2/templates/:hash/reject",
    async (req, res, ctx) => {
      if (!/^[a-f0-9]{64}$/.test(req.params.hash))
        throw new HttpError(400, "template_hash_invalid");
      const { reason, note } = req.body || {};
      if (!REJECT_REASONS.includes(reason))
        throw new HttpError(400, "reject_reason_invalid");
      const text = typeof note === "string" ? note.trim() : "";
      if (note !== undefined && typeof note !== "string")
        throw new HttpError(400, "reject_note_invalid");
      if (text.length > 300) throw new HttpError(400, "reject_note_invalid");
      if (reason === "other" && text.length < 3)
        throw new HttpError(400, "reject_note_required");
      const result = await ctx.withAdminClient(async (client) => {
        await client.query(
          "SELECT pg_advisory_xact_lock(hashtext('sms_v2_template_results'))",
        );
        const row = (
          await client.query(
            "SELECT ai_status FROM sms_v2_unknown_templates WHERE template_hash=$1 FOR UPDATE",
            [req.params.hash],
          )
        ).rows[0];
        if (!row) throw new HttpError(404, "template_not_found");
        // Only a finished draft can be rejected; a busy or untouched layout cannot.
        if (row.ai_status !== "ready")
          throw new HttpError(409, "template_not_rejectable");
        // The draft leaves the row, the revision moves, and the sender's next
        // sync replaces the stored result with "failed": the phone drops the
        // private rule and reads the message again.
        await client.query(
          `UPDATE sms_v2_unknown_templates SET ai_status='failed',ai_draft=NULL,failure_code='admin_rejected',
             admin_decision='rejected',admin_reason=$2,admin_note=$3,decided_by=$4,decided_at=clock_timestamp(),
             result_revision=nextval('sms_v2_template_revision')
           WHERE template_hash=$1`,
          [req.params.hash, reason, text || null, req.admin.userId],
        );
        await client.query(
          "INSERT INTO admin_audit_log (admin_id,action,entity,entity_id,after_value,reason) VALUES ($1,'sms_v2_template_reject','sms_v2_template',NULL,$2,$3)",
          [req.admin.userId, JSON.stringify({ templateHash: req.params.hash, reason }), text || reason],
        );
        return { templateHash: req.params.hash, status: "failed", decision: "rejected", reason };
      });
      return res.json(result);
    },
  );
  // Lane C: the release go/no-go payload (still carries the `ai` rows).
  register("GET", "/admin/sms/v2/metrics", require("./metrics_route").metricsHandler);
}

module.exports = {
  TEMPLATE_STATUSES,
  REJECT_REASONS,
  redactionError,
  createTemplateStore,
  createTemplateHandler,
  registerTemplates,
  registerPrivateTemplateRoutes,
};
