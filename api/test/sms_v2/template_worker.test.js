"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  workerConfig,
  fillSynthetic,
  buildPrompt,
  validateDraft,
  stampDraft,
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
  assert.match(prompt.placeholders["<AMT>"], /^an amount, with its currency marker/);
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

// ---- learning loop B1: prompt versions, temperature and covered layouts

const { PROMPT_VERSION, coveredBy } = require("../../src/sms_v2/template_worker");

test("each attempt records the prompt version, which is also in the prompt", async () => {
  assert.match(PROMPT_VERSION, /^tpl-\d{4}-\d{2}-\d{2}$/);
  assert.equal(JSON.parse(buildPrompt(template)).promptVersion, PROMPT_VERSION);
  const attempts = [];
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async (_t, _a, usage) => attempts.push(usage),
    finish: async () => {},
  };
  const provider = { generate: async () => ({ rule: rule(), inputTokens: 10, outputTokens: 10, totalTokens: 20 }) };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "ready");
  assert.deepEqual(attempts.map((usage) => usage.promptVersion), [PROMPT_VERSION]);
});

test("the temperature from the settings reaches the provider call and Gemini's generationConfig", async () => {
  let seen;
  let leased = false;
  const store = {
    settings: async () => ({ ...require("../../src/sms_v2/settings").mergeSettings([]), ai_temperature: 0.3 }),
    monthSpend: async () => 0,
    claim: async () => (leased ? null : ((leased = true), template)),
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
  };
  const provider = {
    generate: async (input) => {
      seen = input;
      return { rule: rule(), inputTokens: 1, outputTokens: 1, totalTokens: 2 };
    },
  };
  await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(seen.temperature, 0.3);

  let body;
  const gemini = createGeminiTemplateProvider({
    apiKey: "test-key",
    fetchImpl: async (_url, options) => {
      body = JSON.parse(options.body);
      return new Response(JSON.stringify({
        candidates: [{ finishReason: "STOP", content: { parts: [{ text: "{}" }] } }],
        usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 },
      }));
    },
  });
  await gemini.generate({ prompt: "synthetic only", model: "test-model", maxOutputTokens: 512, temperature: 0.3 });
  assert.equal(body.generationConfig.temperature, 0.3);
  await gemini.generate({ prompt: "synthetic only", model: "test-model", maxOutputTokens: 512 });
  assert.equal("temperature" in body.generationConfig, false, "no temperature unless one is set");
});

test("a layout an active rule already reads ends covered and the provider is never called", async () => {
  const active = { ...rule(), id: "TESTBK-PAID", version: 3, status: "active" };
  delete active.match.templateHash;
  assert.equal(coveredBy(template, [active]), "TESTBK-PAID@3");
  assert.equal(coveredBy(template, [{ ...active, senders: ["OTHERBK"] }]), null, "another sender's rule");
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, pattern: "^Never matches$" } }]), null);
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, rejectAny: ["paid"] } }]), null, "rejectAny words");
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, requireAll: ["absent"] } }]), null, "requireAll words");
  assert.equal(coveredBy(template, [{ ...active, match: { pattern: "(" } }]), null, "a broken rule covers nothing");

  let finished;
  let calls = 0;
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    activeRules: async () => [active],
    examples: async () => assert.fail("no prompt is built for a covered layout"),
    beginAttempt: async () => assert.fail("no capacity is reserved for a covered layout"),
    recordAttempt: async () => assert.fail("no attempt is recorded"),
    finish: async (_t, out) => { finished = out; },
  };
  const provider = { generate: async () => { calls++; return { rule: rule() }; } };
  const result = await runTemplateWorkerOnce({ store, provider, config });
  assert.deepEqual(result, { status: "covered", templateHash: template.template_hash, covered: "TESTBK-PAID@3" });
  assert.equal(finished.covered, "TESTBK-PAID@3");
  assert.equal(calls, 0);
});

test("a layout no active rule reads still goes to the provider", async () => {
  let calls = 0;
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    activeRules: async () => [],
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
  };
  const provider = { generate: async () => { calls++; return { rule: rule() }; } };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "ready");
  assert.equal(calls, 1);
});

// ---- learning loop B2: better input for the AI

const { rankSimilarRules } = require("../../src/sms_v2/template_worker");

const ruleWith = (id, body) => ({ ...rule(), id, examples: [{ sender: "TESTBK", body, expectFactTypes: ["movement"] }] });

test("the prompt carries what people reported and past admin rejections, as counts and layouts only", () => {
  const empty = JSON.parse(buildPrompt(template));
  assert.deepEqual(empty.userReports, {});
  assert.deepEqual(empty.previousMistakes, []);
  const prompt = JSON.parse(
    buildPrompt(template, [], [], {
      userReports: { not_financial: 3, wrong_amount: 1 },
      previousMistakes: [
        { redactedBody: "<AMT> will be debited.", reason: "overmatches" },
        { redactedBody: "<AMT> blocked.", reason: "wrong_fact_type" },
        { redactedBody: "<AMT> paid.", reason: "misses_fields" },
        { redactedBody: "<AMT> fourth.", reason: "other" },
      ],
    }),
  );
  assert.deepEqual(prompt.userReports, { not_financial: 3, wrong_amount: 1 });
  assert.equal(prompt.previousMistakes.length, 3, "at most three past mistakes");
  assert.deepEqual(Object.keys(prompt.previousMistakes[0]).sort(), ["reason", "redactedBody"]);
});

test("the domain rules tell the AI how to treat user reports", () => {
  const prompt = JSON.parse(buildPrompt(template));
  assert.ok(prompt.domainRules.includes("If people reported this layout as not financial, draft a rule that emits only an info fact."));
  assert.ok(prompt.domainRules.includes("A user report is a hint, not proof: the printed text decides."));
});

test("existing rules are chosen by word overlap with the layout, not by rule id", () => {
  const rules = [
    ruleWith("A-ALPHA", "Statement ready for your credit card please review"),
    ruleWith("B-BETA", "Rs. 127.45 paid to SYNTHETIC STORE."),
    ruleWith("C-GAMMA", "Rs. 50.00 paid to MY SHOP."),
    ruleWith("D-DELTA", "Your OTP is 123456"),
    ruleWith("E-EPSILON", "Account balance is low"),
    ruleWith("F-ZETA", "Rs. 10.00 paid to SOME STORE today"),
  ];
  const ranked = rankSimilarRules(template, rules, 3).map((entry) => entry.id);
  assert.deepEqual(ranked.slice(0, 2).sort(), ["B-BETA", "C-GAMMA"].sort());
  assert.equal(ranked.length, 3);
  assert.ok(!ranked.includes("A-ALPHA"), "the lowest rule id is not enough to be included");
  const prompt = JSON.parse(buildPrompt(template, rules));
  assert.equal(prompt.existingRules.length, 5);
  assert.deepEqual(Object.keys(prompt.existingRules[0]).sort(), ["emit", "family", "match"], "example bodies never reach the prompt");
});

test("a draft that reads a sibling layout with its own rule is refused", () => {
  const sibling = { template_hash: "b".repeat(64), redacted_body: "<AMT> paid to <PARTY>." };
  // The sibling has the same words, so the broad draft pattern reads it too.
  assert.ok(validateDraft(rule(), template, config.model, [sibling]).includes("draft_overmatches_other_layouts"));
  const different = { template_hash: "c".repeat(64), redacted_body: "<AMT> credited to your account." };
  assert.ok(!validateDraft(rule(), template, config.model, [different]).includes("draft_overmatches_other_layouts"));
  // The layout itself never counts against its own draft.
  assert.deepEqual(validateDraft(rule(), template, config.model, [{ ...template }]), []);
  assert.deepEqual(validateDraft(rule(), template, config.model), []);
});

test("the worker hands the report counts, past mistakes and sibling layouts to the prompt and the check", async () => {
  let prompt;
  let siblings = 0;
  let leased = false;
  const sibling = { template_hash: "b".repeat(64), redacted_body: "<AMT> credited to your account." };
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    ruleCandidates: async () => [],
    userReports: async () => ({ not_financial: 2 }),
    previousMistakes: async () => [{ redactedBody: "<AMT> blocked.", reason: "overmatches" }],
    siblingLayouts: async () => { siblings++; return [sibling]; },
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
  };
  const provider = { generate: async (input) => { prompt = JSON.parse(input.prompt); return { rule: rule(), inputTokens: 1, outputTokens: 1, totalTokens: 2 }; } };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "ready");
  assert.deepEqual(prompt.userReports, { not_financial: 2 });
  assert.equal(prompt.previousMistakes[0].reason, "overmatches");
  assert.equal(siblings, 1);
});

test("the worker stamps the fields it owns, so a model slip there never fails a draft", () => {
  const slipped = {
    ...rule(),
    id: "AI-wrong",
    version: 7,
    status: "active",
    createdBy: "admin:someone",
    senders: ["OTHERBK"],
    match: { ...rule().match, templateHash: "f".repeat(64) },
  };
  assert.notDeepEqual(validateDraft(slipped, template, config.model), []);
  assert.deepEqual(validateDraft(stampDraft(slipped, template, config.model), template, config.model), []);
  // The model's own parts are kept and still validated.
  const stamped = stampDraft({ ...rule(), match: { ...rule().match, pattern: "(" } }, template, config.model);
  assert.equal(stamped.match.pattern, "(");
  assert.notDeepEqual(validateDraft(stamped, template, config.model), []);
  assert.equal(stampDraft(null, template, config.model), null);
});

test("a reference key outside the fact contract is refused here, because the phone would refuse the fact", () => {
  const draft = rule();
  draft.emit[0].references = { ref: "ref" };
  assert.ok(validateDraft(draft, template, config.model).includes("reference_key_invalid"));
  draft.emit[0].references = { upiRef: "ref" };
  assert.ok(!validateDraft(draft, template, config.model).includes("reference_key_invalid"));
});
