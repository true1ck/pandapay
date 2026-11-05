"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { template, config, rule } = require("./fixtures/template_draft");
const {
  createTemplateStore,
  registerPrivateTemplateRoutes,
} = require("../../src/sms_v2/ai_templates");
const {
  createPgWorkerStore,
  runTemplateWorkerOnce,
} = require("../../src/sms_v2/template_worker");
const { createAdminDbHelpers } = require("../../src/admin/server");
const { createAdminApiApp } = require("../../src/admin/app");
const { registerSmsV2 } = require("../../src/sms_v2");
const { validateResponse } = require("../../src/sms_v2/contracts");
const { routeManifest } = require("../../src/admin/route_manifest");
const express = require("express");

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
test(
  "template submission, worker, owner sync and private draft on fully migrated Postgres",
  { skip: !url || !adminUrl },
  async (t) => {
    const { Pool } = require("pg");
    const pool = new Pool({ connectionString: url });
    const privatePool = new Pool({ connectionString: adminUrl });
    const profiles = Array.from({ length: 4 }, () => crypto.randomUUID());
    const admin = crypto.randomUUID();
    const priorFlag = (
      await pool.query(
        "SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'",
      )
    ).rows[0];
    let publicServer, adminServer;
    t.after(async () => {
      for (const server of [publicServer, adminServer]) {
        if (server) {
          server.closeAllConnections();
          await new Promise((resolve) => server.close(resolve));
        }
      }
      if (priorFlag)
        await pool.query(
          "UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'",
          [priorFlag.is_enabled, priorFlag.rollout_percent],
        );
      else
        await pool.query(
          "DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'",
        );
      await pool.query("DELETE FROM profiles WHERE id=ANY($1::uuid[])", [
        profiles,
      ]);
      await pool.query("DELETE FROM sms_v2_unknown_templates");
      await pool.query("DELETE FROM sms_v2_ai_capacity");
      await pool.query("DELETE FROM sms_v2_template_attempts");
      await pool.query("DELETE FROM admin_audit_log WHERE admin_id=$1", [
        admin,
      ]);
      await pool.query("DELETE FROM admin_users WHERE id=$1", [admin]);
      await pool.query("DELETE FROM sms_v2_rules WHERE rule_id=$1", [
        `AI-${template.template_hash}`,
      ]);
      await Promise.all([pool.end(), privatePool.end()]);
    });
    for (const id of profiles)
      await pool.query("INSERT INTO profiles(id) VALUES($1)", [id]);
    await pool.query(
      "INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')",
      [admin, `${admin}@example.invalid`],
    );
    const consent = async (id, granted) =>
      pool.query(
        "INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning','sms-shared-learning-v3',$2,clock_timestamp())",
        [id, granted],
      );
    const withUserClient = async (id, operation) => {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        await client.query("SET LOCAL ROLE app_user");
        await client.query("SELECT set_config('app.user_id',$1,true)", [id]);
        const out = await operation(client);
        await client.query("COMMIT");
        return out;
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      } finally {
        client.release();
      }
    };
    const store = createTemplateStore({ withUserClient });
    const item = {
      templateHash: template.template_hash,
      senderBrand: template.sender_brand,
      redactedBody: template.redacted_body,
      observedAt: new Date().toISOString(),
    };
    await assert.rejects(store.submit(profiles[0], [item], true), {
      code: "42501",
    });
    for (const id of profiles) await consent(id, true);
    await assert.rejects(
      store.submit(
        profiles[0],
        [{ ...item, redactedBody: "call 9876543210" }],
        true,
      ),
      { code: "22023" },
    );
    assert.equal(
      (
        await withUserClient(profiles[0], (client) =>
          client.query("SELECT * FROM sms_v2_unknown_templates"),
        )
      ).rows.length,
      0,
    );
    const app = express();
    const requireMember = (req, res, next) => {
      req.userId = req.headers["x-test-user"];
      return req.userId ? next() : res.sendStatus(401);
    };
    registerSmsV2(app, {
      withUserClient,
      requireAuth: requireMember,
      requireMember,
      requireSmsV2: (_req, _res, next) => next(),
      signer: null,
      hooks: {
        security: {
          verifyAttestation: async (req) => {
            req.smsV2Security = {
              sharedLearningEligible: req.headers["x-test-verified"] === "1",
            };
            return true;
          },
          checkRate: async () => true,
        },
      },
    });
    publicServer = app.listen(0, "127.0.0.1");
    await new Promise((resolve) => publicServer.once("listening", resolve));
    const origin = `http://127.0.0.1:${publicServer.address().port}`;
    const submit = async (profile, verified, items = [item]) =>
      fetch(`${origin}/sms/v2/unknown-templates`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-test-user": profile,
          "x-test-verified": verified ? "1" : "0",
        },
        body: JSON.stringify({ items }),
      });
    assert.equal((await submit(profiles[0], false)).status, 202);
    assert.equal(
      (await pool.query("SELECT ai_status FROM sms_v2_unknown_templates"))
        .rows[0].ai_status,
      "held",
    );
    const worker = createPgWorkerStore({
      ...createAdminDbHelpers(privatePool),
      adminId: admin,
    });
    let calls = 0;
    const provider = {
      generate: async ({ prompt }) => {
        calls++;
        assert.equal(JSON.parse(prompt).redactedBody, template.redacted_body);
        return {
          rule: rule(),
          inputTokens: 100,
          outputTokens: 150,
          totalTokens: 250,
        };
      },
    };
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "idle",
    );
    assert.equal((await submit(profiles[0], true)).status, 202);
    assert.equal((await submit(profiles[1], true)).status, 202);
    const shared = (
      await pool.query(
        "SELECT seen_count,distinct_profiles FROM sms_v2_unknown_templates",
      )
    ).rows[0];
    assert.equal(Number(shared.seen_count), 2);
    assert.equal(shared.distinct_profiles, 2);
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "ready",
    );
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "idle",
    );
    assert.equal(calls, 1);
    const sync = await fetch(`${origin}/sms/v2/sync`, {
      headers: { "x-test-user": profiles[0] },
    });
    assert.equal(sync.status, 200);
    const response = await sync.json();
    assert.equal(validateResponse("sync", response).ok, true);
    assert.equal(
      response.aiResults[0].rule.match.templateHash,
      item.templateHash,
    );
    assert.equal(response.aiResults[0].status, "ready");
    assert.equal((await store.results(profiles[2], null)).items.length, 0);
    const savedCursor = response.cursor;
    assert.equal(
      (
        await (
          await fetch(
            `${origin}/sms/v2/sync?cursor=${encodeURIComponent(savedCursor)}`,
            { headers: { "x-test-user": profiles[0] } },
          )
        ).json()
      ).aiResults.length,
      0,
    );
    // Submitting a ready template after a previous sync still returns the rule.
    const empty = await store.results(profiles[2], null);
    await store.submit(profiles[2], [item], true);
    assert.equal(
      (await store.results(profiles[2], empty.cursor)).items[0].status,
      "ready",
    );
    const batch = Array.from({ length: 48 }, () => item);
    assert.equal((await submit(profiles[0], true, batch)).status, 202);
    assert.equal((await submit(profiles[0], true)).status, 429);
    await consent(profiles[0], false);
    assert.equal((await store.results(profiles[0], null)).items.length, 0);
    assert.equal((await submit(profiles[0], true)).status, 403);
    await pool.query(
      "INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100",
    );
    const helpers = createAdminDbHelpers(privatePool);
    const adminApp = createAdminApiApp({
      routeManifest: routeManifest.filter((row) =>
        [
          "/admin/sms/v2/templates",
          "/admin/sms/v2/templates/:hash/draft",
          "/admin/sms/v2/metrics",
        ].includes(row.path),
      ),
      introspectAdminSession: async () => ({
        active: true,
        userId: admin,
        sessionId: "test",
        assurance: "email+webauthn-uv",
        mfaVerifiedAt: new Date(),
        expiresAt: new Date(Date.now() + 60000),
      }),
      ...helpers,
      registerRoutes: registerPrivateTemplateRoutes,
    });
    adminServer = adminApp.listen(0, "127.0.0.1");
    await new Promise((resolve) => adminServer.once("listening", resolve));
    const adminOrigin = `http://127.0.0.1:${adminServer.address().port}`;
    const headers = { authorization: `Bearer ${"x".repeat(43)}` };
    const promotion = await fetch(
      `${adminOrigin}/admin/sms/v2/templates/${item.templateHash}/draft`,
      { method: "POST", headers },
    );
    const draft = await promotion.json();
    assert.equal(promotion.status, 200, JSON.stringify(draft));
    const storedDraft = (
      await pool.query(
        "SELECT body FROM sms_v2_rules WHERE rule_id=$1 AND status='draft'",
        [`AI-${template.template_hash}`],
      )
    ).rows[0].body;
    assert.equal(storedDraft.status, "draft");
    assert.equal(storedDraft.match.templateHash, undefined);
    const metrics = await (
      await fetch(`${adminOrigin}/admin/sms/v2/metrics`, { headers })
    ).json();
    assert.equal(metrics.ai[0].calls, 1);
    assert.equal(Number(metrics.ai[0].total_tokens), 250);
    // Popular templates win, and a single queued job cannot be leased twice.
    const unpopular = { ...item, templateHash: "b".repeat(64) };
    const popular = { ...item, templateHash: "c".repeat(64) };
    await store.submit(profiles[3], [unpopular, popular], true);
    await store.submit(profiles[1], [popular], true);
    const claimed = await worker.claim();
    assert.equal(claimed.template_hash, popular.templateHash);
    const second = await worker.claim();
    assert.equal(second.template_hash, unpopular.templateHash);
    assert.equal(await worker.claim(), null);
    assert.equal(
      await worker.beginAttempt(claimed, 1, "synthetic prompt", {
        ...config,
        rpm: 2,
      }),
      null,
    );
    assert.equal(
      await worker.beginAttempt(second, 1, "synthetic prompt", {
        ...config,
        rpm: 2,
      }),
      "capacity",
    );
    // Revocation removes the owner association and cancels unstarted work.
    await consent(profiles[1], false);
    await consent(profiles[3], false);
    assert.equal(
      await worker.beginAttempt(second, 1, "synthetic prompt", config),
      "consent_or_lease_lost",
    );
  },
);
