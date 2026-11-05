"use strict";

const { validateRequest } = require("./contracts");
const { createRequireSmsV2 } = require("./guard");
const { createPgStore } = require("./rules_store");
const { saveDraft, HttpError } = require("./rules_admin_route");
const { intakeOpen } = require("./settings");

const MAX_BODY = 20000;
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
    if (
      status &&
      !["held", "queued", "working", "ready", "failed"].includes(status)
    )
      throw new HttpError(400, "template_status_invalid");
    const rows = await ctx.withAdminClient((client) =>
      client.query(
        `SELECT template_hash,sender_brand,redacted_body,seen_count,distinct_profiles,ai_status,ai_draft,ai_model,failure_code,first_seen,last_seen
       FROM sms_v2_unknown_templates WHERE ($1::text IS NULL OR ai_status=$1) ORDER BY first_seen,template_hash LIMIT 200`,
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
        return store.tx(req.admin.userId, (tx) =>
          saveDraft(tx, rule.id, rule, {
            adminId: req.admin.userId,
            now: new Date(),
          }),
        );
      });
      return res.json(result);
    },
  );
  // Lane C: the release go/no-go payload (still carries the `ai` rows).
  register("GET", "/admin/sms/v2/metrics", require("./metrics_route").metricsHandler);
}

module.exports = {
  redactionError,
  createTemplateStore,
  createTemplateHandler,
  registerTemplates,
  registerPrivateTemplateRoutes,
};
