"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  workerConfig,
  fillSynthetic,
  buildPrompt,
  validateDraft,
  validateDraftSafely,
  stampDraft,
  runTemplateWorkerOnce,
  createGeminiTemplateProvider,
} = require("../../src/sms_v2/template_worker");
const {
  redactionError,
  createTemplateHandler,
} = require("../../src/sms_v2/ai_templates");

const { template, config, rule, answer } = require("./fixtures/template_draft");
const { buildMatcher, slotValues } = require("../../src/sms_v2/layout_matcher");
const { buildRule, AnswerError, SMS_PLACEHOLDERS, SMS_DOMAIN_RULES } = require("../../src/sms_v2/template_worker");

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

test("the prompt names the layout's slots, shows the sample's values by slot, and nothing else of the message", () => {
  const matcher = buildMatcher(template.redacted_body);
  const sample = "Rs.4821.50 paid to ZAZA SHOP.";
  const slots = slotValues(matcher, sample);
  assert.deepEqual(slots, { amt1: "Rs.4821.50", party1: "ZAZA SHOP" });
  const { system, user } = buildPrompt({
    template,
    matcher,
    sample,
    slots,
    families: ["upi_debit"],
    reports: { not_financial: 2 },
    fix: ["example_mismatch"],
  });
  assert.deepEqual(JSON.parse(user), {
    sender: "TESTBK",
    layout: "<amt1> paid to <party1>.",
    sample,
    slotValues: slots,
    familiesUsedBySender: ["upi_debit"],
    peopleReported: { not_financial: 2 },
    yourLastAnswerFailed: ["example_mismatch"],
  });
  // No wording and no values without a sample: the layout alone.
  assert.deepEqual(Object.keys(JSON.parse(buildPrompt({ template, matcher }).user)).sort(), ["layout", "sender"]);
  // A layout that could still hold a real number never leaves the server.
  assert.throws(() => buildPrompt({ template: { ...template, redacted_body: "Call 9876543210" }, matcher }), /redaction_required/);
  // The whole request stays small: free keys count tokens (the old prompt was about 14,000).
  assert.ok((system.length + user.length) / 3.2 < 2000, `prompt is ${Math.round((system.length + user.length) / 3.2)} tokens`);
  assert.equal(fillSynthetic(template.redacted_body), "Rs. 127.45 paid to SYNTHETIC STORE.");
});

test("the system prompt carries the India SMS rules, every fact type and the slot kinds", () => {
  const { SYSTEM } = require("../../src/sms_v2/ai_prompt");
  const factSchema = require("../../../contracts/sms/v2/fact.schema.json");
  const rules = SMS_DOMAIN_RULES.join("\n");
  assert.ok(rules.includes("bill_due"));
  assert.ok(rules.includes("hold fact"));
  assert.ok(rules.includes("never the movement amount"));
  for (const kind of ["amt", "date", "mask", "vpa", "ref", "phone", "email", "url", "party", "w"]) assert.ok(SMS_PLACEHOLDERS[kind], kind);
  for (const type of Object.keys(factSchema.$defs)) assert.ok(SYSTEM.includes(type), `fact type ${type}`);
  // Every fact type the rules name exists in the fact contract.
  const named = new Set(
    SMS_DOMAIN_RULES.flatMap((rule) => [...rule.matchAll(/\b(\w+) facts?\b/g)].map((m) => m[1])).filter((word) => !["a", "an", "one", "each"].includes(word)),
  );
  assert.ok(named.size >= 5);
  for (const type of named) assert.ok(type in factSchema.$defs, type);
  // The rules about regexes are gone: the model writes no regex now.
  assert.equal(/backreference|named group|pattern runs/i.test(SYSTEM), false);
});

test("a rule is built from the layout and the model's answer, and passes the same checks as any draft", () => {
  const matcher = buildMatcher(template.redacted_body);
  const built = buildRule(answer(), template, matcher, config.model);
  assert.equal(built.match.pattern, matcher.pattern);
  assert.equal(built.match.templateHash, template.template_hash);
  assert.equal(built.status, "provisional");
  assert.deepEqual(validateDraft(built, template, config.model), []);
  // Slot names, units and date formats are tidied: "<AMT1>" is amt1, rupees by default, formats are the engine's.
  const messy = answer();
  messy.emit[0].amounts[0] = { role: "posted", from: "<AMT1>" };
  messy.emit[0].occurredAt = { from: "Date1", formats: ["dd/MM/yyyy"] };
  messy.emit[0].counterparty.nameFrom = "PARTY1";
  const tidy = buildRule(messy, template, matcher, config.model);
  assert.deepEqual(tidy.emit[0].amounts[0], { role: "posted", from: "amt1", unit: "INR" });
  assert.deepEqual(tidy.emit[0].occurredAt, { from: "date1" });
  assert.equal(tidy.emit[0].counterparty.nameFrom, "party1");
  // A slot the layout does not have is caught by the capture check, not guessed.
  const wrong = answer();
  wrong.emit[0].amounts[0].from = "amt9";
  assert.ok(validateDraft(buildRule(wrong, template, matcher, config.model), template, config.model).includes("capture_group_missing"));
  // Nothing usable: no emit.
  for (const bad of [null, [], {}, { emit: [] }, { emit: ["x"] }, { emit: Array(7).fill({ factType: "info" }) }])
    assert.throws(() => buildRule(bad, template, matcher, config.model), AnswerError);
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
    beginAttempt: async () => null,
    recordAttempt: async (_t, a, usage) => attempts.push({ a, ...usage }),
    finish: async (_t, out) => {
      finish = out;
    },
  };
  const provider = {
    generate: async ({ prompt, system }) => {
      calls++;
      assert.ok(system.length > 1000, "the fixed instruction travels as the system prompt");
      if (calls === 1)
        return {
          answer: {},
          inputTokens: 100,
          outputTokens: 20,
          totalTokens: 120,
        };
      assert.deepEqual(JSON.parse(prompt).yourLastAnswerFailed, ["answer_shape_invalid"]);
      return {
        answer: answer(),
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
  assert.equal(finish.rule.match.templateHash, template.template_hash);
  assert.equal(attempts[1].outputTokens, 35);
  assert.equal(attempts[1].costUsd, 0.00017);
  // Why the first try failed is kept, as codes; a good try keeps none.
  assert.equal(attempts[0].errorKind, "answer_invalid");
  assert.deepEqual(attempts[0].errorCodes, ["answer_shape_invalid"]);
  assert.equal(attempts[1].errorKind, null);
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
      return { answer: {} };
    },
  };
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "failed",
  );
  assert.equal(calls, 2);
  assert.equal(finish.code, "draft_validation_failed");
  assert.deepEqual(finish.detail, ["answer_invalid", "answer_shape_invalid"], "the reason is kept");
  store.beginAttempt = async () => "capacity";
  calls = 0;
  assert.equal(
    (await runTemplateWorkerOnce({ store, provider, config })).status,
    "capacity",
  );
  assert.equal(calls, 0);
  assert.equal(finish.requeue, true);
  // Only the key and a database login come from the host: the rest has defaults.
  assert.equal(workerConfig({}).model, "gemini-3.1-flash-lite");
  assert.equal(workerConfig({ SMS_V2_AI_MODEL: "test" }).tpm, 100000);
  assert.throws(() => workerConfig({ SMS_V2_AI_TPM: "0" }), /TPM_invalid/);
  // Compose hands an unset variable over as an empty string: that means "unset".
  const blank = workerConfig({
    SMS_V2_AI_MODEL: "",
    SMS_V2_AI_TPM: "",
    SMS_V2_AI_RPM: "",
    SMS_V2_AI_MAX_OUTPUT_TOKENS: "",
    SMS_V2_AI_INPUT_USD_PER_MILLION: "",
    SMS_V2_AI_OUTPUT_USD_PER_MILLION: "",
  });
  assert.equal(blank.model, "gemini-3.1-flash-lite");
  assert.equal(blank.tpm, 100000);
  assert.equal(blank.inputPrice, null);
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

test("each attempt records the prompt version", async () => {
  assert.match(PROMPT_VERSION, /^tpl-\d{4}-\d{2}-\d{2}-[a-z]+$/);
  const attempts = [];
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    beginAttempt: async () => null,
    recordAttempt: async (_t, _a, usage) => attempts.push(usage),
    finish: async () => {},
  };
  // The model's answer may arrive as text.
  const provider = { generate: async () => ({ answer: JSON.stringify(answer()), inputTokens: 10, outputTokens: 10, totalTokens: 20 }) };
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
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
  };
  const provider = {
    generate: async (input) => {
      seen = input;
      return { answer: answer(), inputTokens: 1, outputTokens: 1, totalTokens: 2 };
    },
  };
  const result = await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(seen.temperature, 0.3);
  assert.equal(result.gapSeconds, 20, "after a call the worker rests for the console's gap");

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
  await gemini.generate({ system: "FIXED", prompt: "synthetic only", model: "test-model", maxOutputTokens: 512, temperature: 0.3 });
  assert.equal(body.generationConfig.temperature, 0.3);
  assert.equal(body.systemInstruction.parts[0].text, "FIXED");
  await gemini.generate({ prompt: "synthetic only", model: "test-model", maxOutputTokens: 512 });
  assert.equal("temperature" in body.generationConfig, false, "no temperature unless one is set");
  assert.equal("systemInstruction" in body, false, "no system prompt unless one is given");
});

test("a layout an active rule already reads, in every way of writing its values, ends covered and the provider is never called", async () => {
  const matcher = buildMatcher(template.redacted_body);
  const active = { ...rule(), id: "TESTBK-PAID", version: 3, status: "active", match: { pattern: matcher.pattern, flags: "i" } };
  assert.equal(coveredBy(template, [active]), "TESTBK-PAID@3");
  assert.equal(coveredBy(template, [{ ...active, senders: ["OTHERBK"] }]), null, "another sender's rule");
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, pattern: "^Never matches$" } }]), null);
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, rejectAny: ["paid"] } }]), null, "rejectAny words");
  assert.equal(coveredBy(template, [{ ...active, match: { ...active.match, requireAll: ["absent"] } }]), null, "requireAll words");
  assert.equal(coveredBy(template, [{ ...active, match: { pattern: "(" } }]), null, "a broken rule covers nothing");
  // A rule that only reads one way of writing the values ("Rs. 127.45") is not a cover: it would fail on "Rs.450".
  assert.equal(coveredBy(template, [{ ...active, match: { pattern: "^Rs\\. [0-9.]+ paid to [A-Z ]+\\.$", flags: "i" } }]), null);

  let finished;
  let calls = 0;
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    activeRules: async () => [active],
    beginAttempt: async () => assert.fail("no capacity is reserved for a covered layout"),
    recordAttempt: async () => assert.fail("no attempt is recorded"),
    finish: async (_t, out) => { finished = out; },
  };
  const provider = { generate: async () => { calls++; return { answer: answer() }; } };
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
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
  };
  const provider = { generate: async () => { calls++; return { answer: answer() }; } };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "ready");
  assert.equal(calls, 1);
});

// ---- learning loop B2: better input for the AI

test("the domain rules tell the AI how to treat user reports", () => {
  assert.ok(
    SMS_DOMAIN_RULES.includes(
      "If people reported this layout as not financial, draft a rule that emits only an info fact. A user report is a hint, not proof: the printed text decides.",
    ),
  );
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

// ---- pipeline v3: wording, pacing, keys

const wordingStore = (extra = {}) => {
  let leased = false;
  return {
    claim: async () => (leased ? null : ((leased = true), { ...template, sample: "Rs.4821.50 paid to ZAZA SHOP." })),
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    finish: async () => {},
    ...extra,
  };
};
const promptSeen = async (store) => {
  let prompt;
  const provider = { generate: async (input) => ((prompt = JSON.parse(input.prompt)), { answer: answer(), inputTokens: 1, outputTokens: 1, totalTokens: 2 }) };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "ready");
  return prompt;
};

test("Gemini sees the message wording with swapped numbers only when allowed, safe, and really this layout", async () => {
  const settings = (more) => async () => ({ ...require("../../src/sms_v2/settings").mergeSettings([]), ...more });
  // Allowed and aligned: wording and the value of each slot.
  const shown = await promptSeen(wordingStore());
  assert.equal(shown.sample, "Rs.4821.50 paid to ZAZA SHOP.");
  assert.deepEqual(shown.slotValues, { amt1: "Rs.4821.50", party1: "ZAZA SHOP" });
  // The console switch turns the wording off: the layout alone.
  assert.equal("sample" in (await promptSeen(wordingStore({ settings: settings({ ai_use_sample: false }), monthSpend: async () => 0 }))), false);
  // A sample that is not this layout, or holds a link or address, is dropped.
  for (const sample of ["Something else entirely.", "Rs.1 paid to pay@bank.com.", "Rs.1 paid to https://x.example."]) {
    let leased = false;
    const store = wordingStore({ claim: async () => (leased ? null : ((leased = true), { ...template, sample })) });
    assert.equal("sample" in (await promptSeen(store)), false, sample);
  }
});

test("reports and the sender's rule families reach the prompt; nothing else is read for it", async () => {
  const otherFamily = { ...rule(), family: "upi_debit", senders: ["TESTBK"], match: { pattern: "^never$", flags: "i" } };
  const prompt = await promptSeen(
    wordingStore({
      activeRules: async () => [otherFamily, otherFamily],
      userReports: async () => ({ not_financial: 2 }),
      previousMistakes: async () => [{ redactedBody: "<AMT> blocked.", reason: "overmatches" }],
      examples: async () => assert.fail("example rules are no longer sent"),
      siblingLayouts: async () => assert.fail("sibling layouts are no longer compared"),
    }),
  );
  assert.deepEqual(prompt.peopleReported, { not_financial: 2 });
  assert.deepEqual(prompt.familiesUsedBySender, ["upi_debit"]);
  assert.deepEqual(prompt.rejectedBefore, [{ layout: "<AMT> blocked.", reason: "overmatches" }], "what an admin turned down is not repeated");
});

test("a layout with too many name slots is refused with a reason, and Gemini is not called", async () => {
  let finished;
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), { ...template, redacted_body: Array(9).fill("<PARTY>").join(" a ") })),
    beginAttempt: async () => assert.fail("no capacity is reserved"),
    finish: async (_t, out) => { finished = out; },
  };
  const provider = { generate: async () => assert.fail("no call") };
  assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "failed");
  assert.equal(finished.code, "layout_too_many_wildcards");
  assert.deepEqual(finished.detail, ["layout", "layout_too_many_wildcards"]);
});

test("while every key is resting after a rate limit the layout waits, with no try or reservation spent", async () => {
  let finished;
  let leased = false;
  const store = {
    claim: async () => (leased ? null : ((leased = true), template)),
    beginAttempt: async () => assert.fail("no reservation while resting"),
    finish: async (_t, out) => { finished = out; },
  };
  const provider = { waitMs: () => 17000, generate: async () => assert.fail("no call while resting") };
  const result = await runTemplateWorkerOnce({ store, provider, config });
  assert.deepEqual(result, { status: "provider_busy", retryAfterMs: 17000 });
  assert.equal(finished.requeue, true);
});

test("a busy answer is recorded as such, with its HTTP status, and the layout stays at its place in the queue", async () => {
  const { ProviderBusyError } = require("../../src/sms_v2/template_worker");
  const attempts = [];
  let finished;
  const store = {
    claim: async () => template,
    beginAttempt: async () => null,
    recordAttempt: async (_t, _n, usage) => attempts.push(usage),
    providerFailures: async () => 0,
    finish: async (_t, out) => { finished = out; },
  };
  const provider = { generate: async () => { throw new ProviderBusyError("template_provider_busy", { status: 503 }); } };
  await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(attempts[0].errorKind, "provider_busy");
  assert.equal(attempts[0].httpStatus, 503);
  assert.deepEqual(attempts[0].errorCodes, ["template_provider_busy"]);
  assert.equal(finished.requeue, true);
});

const ok = (text = "{}") =>
  new Response(JSON.stringify({ candidates: [{ finishReason: "STOP", content: { parts: [{ text }] } }], usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 } }));
const refused = (status, body) => new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
const retryIn = (seconds) => ({ error: { code: 429, status: "RESOURCE_EXHAUSTED", details: [{ "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: `${seconds}s` }] } });

test("two keys are used in turn, and a key that hits a limit rests for exactly the wait Gemini gave", async () => {
  let clock = 1_000_000;
  const used = [];
  const limited = new Set(["key-a"]);
  const provider = createGeminiTemplateProvider({
    apiKeys: ["key-a", "key-b"],
    now: () => clock,
    fetchImpl: async (_url, options) => {
      const key = options.headers["x-goog-api-key"];
      used.push(key);
      return limited.has(key) ? refused(429, retryIn(20)) : ok();
    },
  });
  assert.equal(provider.waitMs(), 0);
  await provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 });
  assert.deepEqual(used, ["key-a", "key-b"], "a limited key hands over to the next one");
  assert.equal(provider.waitMs(), 0, "one key is still usable");
  used.length = 0;
  await provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 });
  await provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 });
  assert.deepEqual(used, ["key-b", "key-b"], "the resting key is not asked while it rests");
  clock += 21_000;
  limited.clear();
  used.length = 0;
  await provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 });
  await provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 });
  assert.deepEqual([...new Set(used)].sort(), ["key-a", "key-b"], "after the wait both keys work again");
});

test("when every key is limited the call waits the shortest rest, and a daily quota waits half an hour", async () => {
  let clock = 0;
  const provider = createGeminiTemplateProvider({
    apiKeys: ["key-a", "key-b"],
    now: () => clock,
    fetchImpl: async (_url, options) => refused(429, retryIn(options.headers["x-goog-api-key"] === "key-a" ? 20 : 35)),
  });
  await assert.rejects(
    () => provider.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }),
    (error) => error.name === "ProviderBusyError" && error.systemic === false && error.retryAfterMs === 20000 && error.status === 429,
  );
  assert.equal(provider.waitMs(), 20000);
  clock += 5000;
  assert.equal(provider.waitMs(), 15000);

  const daily = createGeminiTemplateProvider({
    apiKeys: ["only"],
    now: () => 0,
    fetchImpl: async () => refused(429, { error: { message: "quota", details: [{ violations: [{ quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier" }] }] } }),
  });
  await assert.rejects(() => daily.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }), (error) => error.retryAfterMs === 1800000);
});

test("a quota refusal is a wait, an old model name uses the fallback model, and an incomplete answer is a draft failure", async () => {
  // 403 that talks about quota is a rate limit, not a broken key.
  const quota403 = createGeminiTemplateProvider({ apiKeys: ["k"], now: () => 0, fetchImpl: async () => refused(403, "Quota exceeded for this project") });
  await assert.rejects(() => quota403.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }), (error) => error.systemic === false && error.status === 403);

  const urls = [];
  const fallback = createGeminiTemplateProvider({
    apiKeys: ["k"],
    fallbackModel: "newer-model",
    fetchImpl: async (url) => (urls.push(url), url.includes("old-model") ? refused(404, "gone") : ok()),
  });
  await fallback.generate({ prompt: "{}", model: "old-model", maxOutputTokens: 10 });
  assert.equal(urls.length, 2);
  assert.match(urls[1], /newer-model:generateContent$/);
  // With no fallback model a 404 stays "the account's fault": wait, never fail layouts.
  const none = createGeminiTemplateProvider({ apiKeys: ["k"], fetchImpl: async () => refused(404, "gone") });
  await assert.rejects(() => none.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }), (error) => error.systemic === true);

  // Cut off by the output limit: counted as a failed draft, with its reason.
  const cut = createGeminiTemplateProvider({
    apiKeys: ["k"],
    fetchImpl: async () => new Response(JSON.stringify({ candidates: [{ finishReason: "MAX_TOKENS", content: { parts: [{ text: "{" }] } }] })),
  });
  await assert.rejects(() => cut.generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }), /template_provider_incomplete/);
});

test("the provider's own wait is read from the Retry-After header or the retryDelay in the body, and keys come from the host in order", () => {
  const { providerDelayMs, parseApiKeys } = require("../../src/sms_v2/template_worker");
  assert.equal(providerDelayMs("", { get: () => "12" }), 12000);
  assert.equal(providerDelayMs(JSON.stringify(retryIn(34)), { get: () => null }), 34000);
  assert.equal(providerDelayMs(JSON.stringify(retryIn(0.5)), { get: () => null }), 500);
  assert.equal(providerDelayMs("not json", { get: () => null }), 0);
  assert.deepEqual(parseApiKeys({ GEMINI_API_KEY: "a", GEMINI_FALLBACK_API_KEY: "b", GEMINI_API_KEYS: "c, a ,d" }), ["a", "b", "c", "d"]);
  assert.deepEqual(parseApiKeys({ GEMINI_API_KEY: " ", GEMINI_FALLBACK_API_KEY: "" }), []);
  assert.throws(() => createGeminiTemplateProvider({ apiKeys: [] }), /GEMINI_API_KEY_required/);
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
    // Model puts tests instead of examples and omits confidence:
    const withTests = { ...rule(), tests: rule().examples };
    delete withTests.examples;
    delete withTests.confidence;
    assert.deepEqual(validateDraft(stampDraft(withTests, template, config.model), template, config.model), []);
});

test("a reference key outside the fact contract is refused here, because the phone would refuse the fact", () => {
  const draft = rule();
  draft.emit[0].references = { ref: "ref" };
  assert.ok(validateDraft(draft, template, config.model).includes("reference_key_invalid"));
  draft.emit[0].references = { upiRef: "ref" };
  assert.ok(!validateDraft(draft, template, config.model).includes("reference_key_invalid"));
});

test("validation runs in one reusable thread, and a runaway regex times out without breaking the next draft", async () => {
  const good = rule();
  assert.deepEqual(await validateDraftSafely(good, template, config.model, []), []);
  assert.deepEqual(await validateDraftSafely(good, template, config.model, []), []);
  // Passes the pattern lint but backtracks exponentially on a near match.
  const runaway = rule();
  runaway.match = { ...runaway.match, pattern: "^(?:(?:a?){10}){10}b" };
  runaway.examples = [
    ...runaway.examples,
    { sender: "TESTBK", body: "a".repeat(30), expectFactTypes: [] },
  ];
  const started = Date.now();
  assert.deepEqual(
    await validateDraftSafely(runaway, template, config.model, [], { timeoutMs: 500 }),
    ["validation_timeout"],
  );
  assert.ok(Date.now() - started < 5000);
  assert.deepEqual(await validateDraftSafely(good, template, config.model, []), []);
});

// The prompt must keep teaching the model the decisions the phone's reader and ledger
// are built on. A draft that breaks them double counts money or swallows a message
// the phone could still complete, so each rule is pinned by what it says.
test("the prompt carries the rules the ledger depends on", () => {
  const rules = SMS_DOMAIN_RULES.join("\n").toLowerCase();
  const pinned = [
    // A provider's own receipt is never a second debit.
    "evidenceonly true",
    // A refund that has not arrived has not moved money.
    "only initiated",
    "attempt fact",
    // Coins and rewards are activity, not income or spending.
    "counterparty kind own",
    // A debit alert about an AutoPay is a movement, not a mandate.
    "references.umrn",
    // Money in, and what a wallet top-up is.
    "money in",
    "wallet_topup",
    // Never invent a date.
    "never invent a date",
    // Reports and application status are information.
    "credit report",
  ];
  for (const phrase of pinned) assert.ok(rules.includes(phrase), `domain rules lost: ${phrase}`);
});

test("an overloaded provider makes the layout wait in the queue instead of failing", async () => {
  const { ProviderBusyError, MAX_PROVIDER_FAILURES, busyWaitMs } = require("../../src/sms_v2/template_worker");
  let calls = 0,
    finish,
    failures = 0;
  const store = {
    claim: async () => template,
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async () => {},
    providerFailures: async () => failures,
    finish: async (_t, out) => {
      finish = out;
    },
  };
  const provider = {
    generate: async () => {
      calls++;
      throw new ProviderBusyError("template_provider_busy", { status: 503, retryAfterMs: 7000 });
    },
  };
  const result = await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(result.status, "provider_busy");
  assert.equal(result.retryAfterMs, 7000);
  assert.equal(calls, 1, "one call, not an immediate second try");
  assert.equal(finish.requeue, true);
  assert.equal(finish.code, undefined);

  failures = MAX_PROVIDER_FAILURES;
  const gaveUp = await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(gaveUp.status, "failed");
  assert.equal(finish.code, "provider_unavailable");

  assert.deepEqual([1, 2, 3, 9].map((n) => busyWaitMs({}, n)), [5000, 10000, 20000, 120000]);
  assert.equal(busyWaitMs({ retryAfterMs: 90000 }, 1), 90000);
  assert.equal(busyWaitMs({ retryAfterMs: 9e9 }, 1), 3600000, "a daily quota may ask for up to an hour");
  assert.equal(busyWaitMs({ retryAfterMs: 1000 }, 1), 5000, "never less than the shortest pause");
});

function busyStore(overrides = {}) {
  const log = { finish: null, attempts: [] };
  const store = {
    claim: async () => template,
    examples: async () => [],
    beginAttempt: async () => null,
    recordAttempt: async (_t, _n, usage) => log.attempts.push(usage),
    providerFailures: async () => 0,
    finish: async (_t, out) => {
      log.finish = out;
    },
    ...overrides,
  };
  return { store, log };
}

test("a refused key or model is the account's fault: layouts wait, are never failed or given up on", async () => {
  const { ProviderBusyError, MAX_PROVIDER_FAILURES } = require("../../src/sms_v2/template_worker");
  // Even with the failure count far past the limit and the provider "working" elsewhere.
  const { store, log } = busyStore({
    providerFailures: async () => MAX_PROVIDER_FAILURES + 50,
    providerRecentlyWorked: async () => true,
  });
  const provider = {
    generate: async () => {
      throw new ProviderBusyError("template_provider_misconfigured", { status: 403, systemic: true, retryAfterMs: 300000 });
    },
  };
  const result = await runTemplateWorkerOnce({ store, provider, config });
  assert.equal(result.status, "provider_busy");
  assert.equal(result.systemic, true);
  assert.equal(result.retryAfterMs, 300000);
  assert.equal(log.finish.requeue, true);
  assert.equal(log.finish.code, undefined);
  assert.equal(log.attempts[0].outcome, "provider_error", "not counted as a provider failure of the layout");
});

test("during a provider outage a layout is never given up on, even after many failures", async () => {
  const { ProviderBusyError, MAX_PROVIDER_FAILURES } = require("../../src/sms_v2/template_worker");
  const provider = {
    generate: async () => {
      throw new ProviderBusyError("template_provider_busy", { status: 503 });
    },
  };
  const outage = busyStore({
    providerFailures: async () => MAX_PROVIDER_FAILURES,
    providerRecentlyWorked: async () => false,
  });
  assert.equal((await runTemplateWorkerOnce({ store: outage.store, provider, config })).status, "provider_busy");
  assert.equal(outage.log.finish.requeue, true);

  // The provider answers other layouts, so this one really is the problem.
  const healthy = busyStore({
    providerFailures: async () => MAX_PROVIDER_FAILURES,
    providerRecentlyWorked: async () => true,
  });
  assert.equal((await runTemplateWorkerOnce({ store: healthy.store, provider, config })).status, "failed");
  assert.equal(healthy.log.finish.code, "provider_unavailable");
});

test("provider answers are told apart: key, model and billing problems versus a bad request", () => {
  const { isSystemicProviderAnswer } = require("../../src/sms_v2/template_worker");
  for (const status of [401, 403, 404]) assert.equal(isSystemicProviderAnswer(status, ""), true);
  assert.equal(isSystemicProviderAnswer(400, '{"error":{"status":"INVALID_ARGUMENT","message":"API key not valid"}}'), true);
  assert.equal(isSystemicProviderAnswer(400, "models/gemini-x is not found for API version v1beta"), true);
  assert.equal(isSystemicProviderAnswer(400, '{"error":{"message":"Request contains an invalid argument."}}'), false);
  assert.equal(isSystemicProviderAnswer(422, "anything"), false);
  assert.equal(isSystemicProviderAnswer(403, "Quota exceeded"), false, "a quota refusal is a rate limit");
});

test("the Gemini provider turns a refused key into a wait and a plain bad request into a draft failure", async () => {
  const mk = (status, body) =>
    createGeminiTemplateProvider({
      apiKey: "k",
      fetchImpl: async () => ({ ok: false, status, headers: { get: () => null }, text: async () => body }),
    });
  await assert.rejects(
    () => mk(403, "PERMISSION_DENIED").generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }),
    (error) => error.name === "ProviderBusyError" && error.systemic === true,
  );
  await assert.rejects(
    () => mk(400, "invalid argument").generate({ prompt: "{}", model: "m", maxOutputTokens: 10 }),
    (error) => error.name === "Error" && error.message === "template_provider_failed",
  );
});

// ---- the compact prompt: only the rules and the example that fit the layout are sent

test("each layout gets only the rules and the one example that fit its words, and every rule can be reached", () => {
  const { RULES, rulesFor, exampleFor, EXAMPLES } = require("../../src/sms_v2/ai_prompt");
  // One layout per rule that names the words it is about: each rule is sent for such a layout and not for an unrelated one.
  const triggers = [
    [1, "Salary of <AMT> credited on <DATE>"], [2, "NEFT transfer of <AMT> received"], [3, "Your SIP of <AMT> in <PARTY> fund"],
    [4, "Your bill of <AMT> is due on <DATE>"], [5, "Pay Later purchase of <AMT>"], [6, "AutoPay mandate registered for <AMT>"],
    [7, "<AMT> blocked for IPO"], [8, "Cash withdrawn from ATM <AMT>"], [9, "Refund of <AMT> processed"], [10, "Refund of <AMT> initiated"],
    [11, "Your renewal receipt for <AMT>"], [12, "Fixed deposit of <AMT> created"], [13, "Loan of <AMT> credited to wallet"],
    [14, "You redeemed 500 coins for <AMT>"], [15, "AutoPay debit of <AMT> mandate ref <REF>"], [16, "Reminder: bill due <DATE>"],
    [17, "Your credit report is ready"], [18, "Payment on your card of <AMT>"], [19, "Dear customer, your OTP is <REF>"],
    [20, "Avl Bal <AMT>"], [21, "<AMT> paid and <AMT> fee"],
  ];
  const reachable = new Set();
  for (const [index, layout] of triggers) {
    const sent = rulesFor(layout.replace(/<([A-Z]+)>/g, (_m, k) => "<" + k.toLowerCase() + "1>").replace("<amt1> paid and <amt1>", "<amt1> paid and <amt2>"));
    assert.ok(sent.includes(RULES[index].text), "rule " + index + " should be sent for: " + layout);
    reachable.add(index);
  }
  reachable.add(0);
  reachable.add(22);
  assert.equal(reachable.size, RULES.length, "every rule is pinned by a layout that triggers it (the user-report rule by a report)");
  assert.ok(rulesFor("<amt1> paid to <party1>.", { reported: true }).includes(RULES[22].text));
  assert.equal(rulesFor("<amt1> paid to <party1>.").includes(RULES[22].text), false);

  // What is sent is always a subset of the full list, in the same order, and never more than half of it for a plain layout.
  const full = RULES.map((rule) => rule.text);
  const plain = rulesFor("<amt1> debited from A/c <mask1> on <date1> to <party1>. UPI Ref <ref1>. Avl Bal <amt2>.");
  assert.ok(plain.every((text) => full.includes(text)));
  assert.deepEqual(plain, full.filter((text) => plain.includes(text)));
  assert.ok(plain.length <= RULES.length / 2, "a plain debit gets " + plain.length + " rules");
  // A layout with almost no words still gets the basics (money in, information, balance).
  assert.ok(rulesFor("hello").length >= 3);
  // One example, the one that fits.
  assert.equal(exampleFor("Your OTP is <ref1>"), EXAMPLES[1]);
  assert.equal(exampleFor("Your bill of <amt1> is due on <date1>"), EXAMPLES[2]);
  assert.equal(exampleFor("<amt1> debited from A/c <mask1>"), EXAMPLES[0]);
});

test("the average request is about a tenth of the old one, and a layout rich in rules stays under budget", () => {
  const { buildPrompt: build } = require("../../src/sms_v2/ai_prompt");
  const layouts = [
    "<AMT> debited from A/c <MASK> on <DATE> to <PARTY>. UPI Ref <REF>. Avl Bal <AMT>.",
    "Dear Customer, your OTP is <REF>. Do not share it with anyone.",
    "Your UPI mandate for <AMT> is successfully created towards <PARTY> from A/c <MASK>.",
    "Refund of <AMT> for order <REF> has been initiated and will be credited in 5-7 days.",
    "Your SIP of <AMT> in <PARTY> fund is processed on <DATE>. Units allotted at NAV <AMT>.",
  ];
  const sizes = layouts.map((layout) => {
    const { system, user } = build({ template: { ...template, redacted_body: layout }, matcher: buildMatcher(layout) });
    return Math.round((Buffer.byteLength(system) + Buffer.byteLength(user)) / 3.2);
  });
  assert.ok(Math.max(...sizes) < 1800, "largest " + Math.max(...sizes) + " tokens");
  assert.ok(sizes.reduce((a, b) => a + b, 0) / sizes.length < 1500, "average " + sizes.join(", "));
});

test("a failed attribute says which one and why, so the second try can fix it", () => {
  const draft = rule();
  draft.emit[0].attrs.direction = "outgoing";
  const errors = validateDraft(draft, template, config.model);
  assert.ok(errors.includes("emitted_attrs_invalid"), "the code stays");
  const detail = errors.find((e) => e.startsWith("attrs_movement"));
  assert.match(detail, /^attrs_movement\/direction: one of debit\|credit$/);
  // A value the schema does not know, and a missing one, are named too.
  const extra = rule();
  extra.emit[0].attrs.colour = "red";
  assert.ok(validateDraft(extra, template, config.model).some((e) => /^attrs_movement\/?.*unknown attribute colour$/.test(e)));
  const missing = rule();
  delete missing.emit[0].attrs.rail;
  assert.ok(validateDraft(missing, template, config.model).some((e) => /^attrs_movement\/?.*missing rail$/.test(e)));
});

test("a date or amount slot used as an attribute is checked the way the phone reads it, and a missing slot is named", () => {
  const layout = "Bal <AMT> as of <DATE>. Due <AMT> by <DATE>.";
  const t = { template_hash: "a".repeat(64), sender_brand: "TESTBK", redacted_body: layout };
  const matcher = buildMatcher(layout);
  const ok = {
    family: "balance_and_due",
    confidence: 0.9,
    emit: [
      { factType: "balance_snapshot", attrs: { asOf: { from: "date1" } }, amounts: [{ role: "available_balance", from: "amt1", unit: "INR" }] },
      { factType: "bill_due", attrs: { dueDate: { from: "date2" } }, amounts: [{ role: "due_total", from: "amt2", unit: "INR" }] },
      { factType: "info", attrs: { category: "service", amountMinor: { from: "amt1" } } },
    ],
  };
  // The phone turns the date slot into a timestamp or a day, and the amount slot into minor units, so these are fine.
  assert.deepEqual(validateDraft(buildRule(ok, t, matcher, config.model), t, config.model), []);
  // A slot the layout does not have is named, together with the ones it does have.
  const wrong = JSON.parse(JSON.stringify(ok));
  wrong.emit[0].amounts[0].from = "amt9";
  const errors = validateDraft(buildRule(wrong, t, matcher, config.model), t, config.model);
  assert.ok(errors.includes("capture_group_missing"));
  assert.ok(errors.some((e) => /^slot_not_in_layout: amt9 \(the layout has: amt1,date1,amt2,date2\)$/.test(e)), errors.join(" | "));
});
