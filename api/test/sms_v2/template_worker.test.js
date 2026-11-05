"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  workerConfig,
  fillSynthetic,
  buildPrompt,
  validateDraft,
  runTemplateWorkerOnce,
  createGeminiTemplateProvider,
} = require("../../src/sms_v2/template_worker");
const {
  redactionError,
  createTemplateHandler,
} = require("../../src/sms_v2/ai_templates");

const { template, config, rule } = require("./fixtures/template_draft");

test("redaction guard refuses long digits, URLs, email and spaced phones", () => {
  for (const body of [
    "Rs 123456 spent",
    "call 98765 43210",
    "ref help@example.invalid",
    "visit https://example.invalid",
    "visit pay.in/path",
  ])
    assert.equal(redactionError(body), "template_redaction_required");
  assert.equal(redactionError(template.redacted_body), null);
});

test("prompt uses only redacted data and at most five public rule summaries", () => {
  const examples = Array.from({ length: 8 }, () => ({
    ...rule(),
    examples: [{ body: "USER SECRET MUST NOT REACH PROMPT" }],
  }));
  const prompt = JSON.parse(buildPrompt(template, examples));
  assert.equal(prompt.redactedBody, template.redacted_body);
  assert.equal(prompt.existingRules.length, 5);
  assert.equal(JSON.stringify(prompt).includes("USER SECRET"), false);
  assert.throws(
    () => buildPrompt({ ...template, redacted_body: "Call 9876543210" }),
    /redaction_required/,
  );
  assert.equal(
    fillSynthetic(template.redacted_body),
    "Rs. 127.45 paid to SYNTHETIC STORE.",
  );
});

test("prompt carries the India SMS rules and the placeholder legend", () => {
  const prompt = JSON.parse(buildPrompt(template));
  assert.ok(prompt.domainRules.some((rule) => rule.includes("bill_due")));
  assert.ok(prompt.domainRules.some((rule) => rule.includes("hold fact")));
  assert.ok(
    prompt.domainRules.some((rule) =>
      rule.includes("never the movement amount"),
    ),
  );
  assert.equal(prompt.placeholders["<AMT>"], "an amount, with its currency marker");
  assert.equal(prompt.placeholders["#"], "one digit");
  // Every placeholder the phone or the synthetic filler can produce is explained.
  for (const key of ["AMT", "DATE", "MASK", "VPA", "REF", "PHONE", "EMAIL", "URL", "PARTY", "W"])
    assert.ok(prompt.placeholders[`<${key}>`], key);
  // The rules come right after the instruction, and every fact type they name exists.
  assert.deepEqual(Object.keys(prompt).slice(0, 3), ["instruction", "placeholders", "domainRules"]);
  const named = new Set(
    prompt.domainRules
      .flatMap((rule) => [...rule.matchAll(/\b(\w+) facts?\b/g)].map((m) => m[1]))
      .filter((word) => !["a", "an", "one", "each"].includes(word)),
  );
  assert.ok(named.size >= 5);
  for (const type of named) assert.ok(type in prompt.factContract, type);
});

test("draft validation checks scope, captures, two positives/negatives and family consistency", () => {
  assert.deepEqual(validateDraft(rule(), template, config.model), []);
  const mutate = (fn) => {
    const body = rule();
    fn(body);
    return validateDraft(body, template, config.model);
  };
  assert.ok(
    mutate((body) => {
      body.match.templateHash = "b".repeat(64);
    }).includes("template_scope_required"),
  );
  assert.ok(
    mutate((body) => {
      body.emit[0].amounts[0].from = "absent";
    }).includes("capture_group_missing"),
  );
  assert.ok(
    mutate((body) => {
      body.examples.pop();
    }).includes("two_positive_negative_examples_required"),
  );
  assert.ok(
    mutate((body) => { body.emit[0].attrs.direction = "outgoing"; }).includes("emitted_attrs_invalid"),
  );
  assert.ok(
    mutate((body) => {
      body.match.pattern = "(?<amt>(a+)+)";
    }).includes("regex_dialect_invalid"),
  );
  assert.ok(
    validateDraft(
      rule(),
      { ...template, redacted_body: "<AMT> blocked for IPO." },
      config.model,
    ).includes("hold_cannot_emit_movement"),
  );
});

test("worker repairs once, records usage, and deduplicates subsequent work", async () => {
  let calls = 0,
    finish;
  const attempts = [];
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async (_t, a, usage) => attempts.push({ a, ...usage }),
    finish: async (_t, out) => {
      finish = out;
    },
  };
  const provider = {
    generate: async ({ prompt }) => {
      calls++;
      if (calls === 1)
        return {
          rule: {},
          inputTokens: 100,
          outputTokens: 20,
          totalTokens: 120,
        };
      assert.ok(JSON.parse(prompt).repairErrors.length);
      return {
        rule: rule(),
        inputTokens: 100,
        outputTokens: 30,
        totalTokens: 135,
      };
    },
  };
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "ready",
  );
  assert.equal(calls, 2);
  assert.equal(finish.rule.status, "provisional");
  assert.equal(attempts[1].outputTokens, 35);
  assert.equal(attempts[1].costUsd, 0.00017);
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "idle",
  );
});

test("failed second draft stays failed, and exhausted capacity makes no call", async () => {
  let calls = 0,
    finish;
  const store = {
    claim: async () => template,
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async (_t, out) => {
      finish = out;
    },
  };
  const provider = {
    generate: async () => {
      calls++;
      return { rule: {} };
    },
  };
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "failed",
  );
  assert.equal(calls, 2);
  assert.equal(finish.code, "draft_validation_failed");
  store.beginAttempt = async () => "capacity";
  calls = 0;
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "capacity",
  );
  assert.equal(calls, 0);
  assert.equal(finish.requeue, true);
  assert.throws(() => workerConfig({ SMS_V2_AI_MODEL: "test" }), /TPM_invalid/);
  assert.equal(
    workerConfig({
      SMS_V2_AI_MODEL: "test",
      SMS_V2_AI_TPM: "5000",
      SMS_V2_AI_RPM: "7",
    }).rpm,
    7,
  );
});

test("unverified monitor submissions are retained with drafting eligibility false", async () => {
  let eligible;
  const req = {
    userId: "profile",
    body: {
      items: [
        {
          templateHash: template.template_hash,
          senderBrand: "TESTBK",
          redactedBody: template.redacted_body,
          observedAt: "2026-11-20T00:00:00Z",
        },
      ],
    },
  };
  const res = {
    status(code) {
      this.code = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
  await createTemplateHandler({
    store: {
      submit: async (_p, _items, value) => {
        eligible = value;
        return [template.template_hash];
      },
    },
    security: {
      verifyAttestation: async () => {
        req.smsV2Security = { sharedLearningEligible: false };
        return true;
      },
      checkRate: async () => true,
    },
  })(req, res);
  assert.equal(res.code, 202);
  assert.equal(eligible, false);
});

test("Gemini adapter sends JSON mode and bounds the configured output", async () => {
  let request;
  const provider = createGeminiTemplateProvider({
    apiKey: "test-key",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return new Response(
        JSON.stringify({
          candidates: [
            {
              finishReason: "STOP",
              content: { parts: [{ text: JSON.stringify(rule()) }] },
            },
          ],
          usageMetadata: {
            promptTokenCount: 12,
            candidatesTokenCount: 30,
            totalTokenCount: 42,
          },
        }),
      );
    },
  });
  const result = await provider.generate({
    prompt: "synthetic only",
    model: "test-model",
    maxOutputTokens: 512,
  });
  assert.match(request.url, /test-model:generateContent$/);
  assert.equal(
    JSON.parse(request.options.body).generationConfig.maxOutputTokens,
    512,
  );
  assert.equal(request.options.headers["x-goog-api-key"], "test-key");
  assert.equal(result.inputTokens, 12);
});
