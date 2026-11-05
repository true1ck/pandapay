"use strict";
// Dev-only dry run of AI drafts (api/scripts/dry_run_sms_v2_templates.js).
// Run: node --test api/test/sms_v2/dry_run_templates.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  parseArgs,
  dryRun,
  main,
} = require("../../scripts/dry_run_sms_v2_templates");
const { template, config, rule } = require("./fixtures/template_draft");

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "sms-v2-dry-run-"));

test("dry run drafts each layout, repairs once, and reports metadata only", async () => {
  const prompts = [];
  const logs = [];
  const provider = {
    generate: async ({ prompt }) => {
      prompts.push(JSON.parse(prompt));
      return prompts.length === 1
        ? { rule: "{}", inputTokens: 10, outputTokens: 5, totalTokens: 15 }
        : { rule: rule(), inputTokens: 20, outputTokens: 30, totalTokens: 50 };
    },
  };
  const { results, summary } = await dryRun({
    templates: [{ ...template, ai_status: "held" }],
    examplesFor: async () => [],
    provider,
    config,
    log: (entry) => logs.push(entry),
  });
  assert.equal(prompts.length, 2);
  assert.ok(prompts[1].repairErrors.length, "second attempt carries the errors");
  assert.ok(prompts[0].domainRules.length, "the prompt carries the India rules");
  assert.equal(results[0].valid, true);
  assert.equal(results[0].attempts, 2);
  assert.equal(results[0].aiStatus, "held");
  assert.equal(results[0].rule.id, `AI-${template.template_hash}`);
  assert.deepEqual(
    { layouts: summary.layouts, valid: summary.valid, inputTokens: summary.inputTokens, outputTokens: summary.outputTokens },
    { layouts: 1, valid: 1, inputTokens: 30, outputTokens: 35 },
  );
  assert.equal(summary.estimatedCostUsd, (30 * 1 + 35 * 2) / 1e6);
  // The console line never holds the layout or the draft.
  assert.deepEqual(Object.keys(logs[0]).sort(), ["errors", "sender", "status", "valid"]);
  assert.equal(JSON.stringify(logs).includes(template.redacted_body), false);
});

test("an unredacted layout is never sent to the provider", async () => {
  let calls = 0;
  const { results, summary } = await dryRun({
    templates: [{ ...template, redacted_body: "Call 9876543210 now" }],
    examplesFor: async () => [],
    provider: { generate: async () => { calls++; return { rule: rule() }; } },
    config,
  });
  assert.equal(calls, 0);
  assert.deepEqual(results[0].errors, ["template_redaction_required"]);
  assert.equal(results[0].redactedBody, null, "an unsafe body is not written to the output");
  assert.deepEqual(summary.commonErrors, { template_redaction_required: 1 });
});

test("arguments: --out is required and must be outside the repository", () => {
  assert.throws(() => parseArgs(["node", "x"]), /--out/);
  const repoFile = path.resolve(__dirname, "../../../ai-dry-run.json");
  assert.throws(() => parseArgs(["node", "x", "--out", repoFile]), /outside the repository/);
  const out = path.join(tmp(), "out.json");
  const args = parseArgs(["node", "x", "--out", out, "--limit", "5", "--provider", "fake"]);
  assert.deepEqual({ limit: args.limit, provider: args.provider }, { limit: 5, provider: "fake" });
  assert.throws(() => parseArgs(["node", "x", "--out", out, "--limit", "0"]), /--limit/);
  assert.throws(() => parseArgs(["node", "x", "--out", out, "--provider", "openai"]), /--provider/);
});

test("fake mode runs offline from a layouts file and writes a private output file", async () => {
  const dir = tmp();
  const layouts = path.join(dir, "layouts.json");
  fs.writeFileSync(layouts, JSON.stringify([
    { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." },
    { senderBrand: "TESTBK", redactedBody: "<AMT> debited from a/c <MASK> on <DATE>." },
  ]));
  const out = path.join(dir, "ai-dry-run.json");
  const lines = [];
  const realFetch = global.fetch;
  global.fetch = () => { throw new Error("fake mode must not use the network"); };
  try {
    await main(["node", "x", "--provider", "fake", "--layouts", layouts, "--out", out], {}, { log: (line) => lines.push(line) });
  } finally {
    global.fetch = realFetch;
  }
  const written = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(written.provider, "fake");
  assert.equal(written.summary.layouts, 2);
  assert.equal(written.summary.valid, 0, "the fake provider drafts nothing valid");
  assert.match(written.results[0].templateHash, /^[a-f0-9]{64}$/);
  if (process.platform !== "win32") assert.equal(fs.statSync(out).mode & 0o777, 0o600);
  assert.match(lines.at(-1), /0 of 2 drafts valid/);
});

test("database read is one read-only transaction as the owner with learning.read", async () => {
  const { loadLayoutsFromDb } = require("../../scripts/dry_run_sms_v2_templates");
  const sql = [];
  let ended = false;
  class FakePool {
    async query(text) {
      sql.push(text);
      return { rows: [{ name: "admin_api_runtime", unsafe: false }] };
    }
    async connect() {
      return {
        query: async (text, params = []) => {
          sql.push(params.length ? `${text} [${params.join(",")}]` : text);
          if (/admin_has_permission/.test(text)) return { rows: [{ allowed: true }] };
          if (/FROM sms_v2_unknown_templates/.test(text)) return { rows: [{ ...template, ai_status: "held" }] };
          if (/FROM sms_v2_rules/.test(text)) return { rows: [{ body: rule() }] };
          return { rows: [] };
        },
        release() {},
      };
    }
    async end() { ended = true; }
  }
  const { templates, examples } = await loadLayoutsFromDb({
    env: { ADMIN_API_DATABASE_URL: "postgresql://fixture@localhost/test", DB_SSL: "false", NODE_ENV: "test" },
    adminId: "00000000-0000-4000-8000-000000000009",
    limit: 7,
    PoolClass: FakePool,
  });
  assert.equal(templates.length, 1);
  assert.equal(examples.get("TESTBK").length, 1);
  assert.equal(ended, true);
  assert.ok(sql.includes("SET LOCAL ROLE pandapay_admin_api"));
  assert.ok(sql.some((s) => /admin_has_permission/.test(s) && s.endsWith("[learning.read]")));
  assert.ok(sql.indexOf("SET TRANSACTION READ ONLY") < sql.findIndex((s) => /sms_v2_unknown_templates/.test(s)));
  assert.ok(sql.some((s) => /LIMIT \$1 \[7\]$/.test(s)));
  assert.equal(sql.some((s) => /^\s*(INSERT|UPDATE|DELETE)\b/i.test(s)), false);
});

test("gemini mode refuses to start without a key, before reading any layout", async () => {
  const out = path.join(tmp(), "out.json");
  await assert.rejects(
    main(["node", "x", "--layouts", "/nonexistent.json", "--out", out], { SMS_V2_AI_MODEL: "m", SMS_V2_AI_TPM: "1000" }, { log: () => {} }),
    /GEMINI_API_KEY_required/,
  );
  await assert.rejects(
    main(["node", "x", "--out", out], { SMS_V2_AI_MODEL: "m", SMS_V2_AI_TPM: "1000", GEMINI_API_KEY: "k" }, { log: () => {} }),
    /SMS_V2_JOB_ADMIN_ID_required/,
  );
});
