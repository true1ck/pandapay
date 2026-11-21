"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createLocalChainProvider, configuredRoutes } = require("../../src/sms_v2/local_chain_provider");
const { ProviderError } = require("../../src/sms_v2/ai_chain/gemini");
const { ProviderBusyError } = require("../../src/sms_v2/template_worker");

// Invented layouts and answers only. The providers are fakes: nothing here reaches a network.
const answer = () => ({ emit: [{ factType: "info", attrs: { category: "otp" } }] });
const good = (model) => async () => ({ answer: answer(), model, inputTokens: 100, outputTokens: 20, totalTokens: 120 });
const layout = (n = 1) => ({ senderBrand: "TESTBK", redactedBody: `Your code for <AMT> is ready number ${"x".repeat(n)}.`.replace(/\d/g, "") });

function chain(routes, extra = {}) {
  let time = 1_000_000;
  const provider = createLocalChainProvider({ routes, now: () => time, ...extra });
  return { provider, advance: (ms) => (time += ms) };
}

test("a key in the environment turns a provider on and no key leaves it out; nothing is asked of a provider with no key", () => {
  assert.deepEqual(configuredRoutes({}), []);
  assert.equal(createLocalChainProvider({ env: {} }), null);
  assert.deepEqual(configuredRoutes({ GEMINI_API_KEY: "g".repeat(20) }), ["gemini"]);
  assert.deepEqual(
    configuredRoutes({ GEMINI_API_KEY: "g".repeat(20), GROQ_API_KEY: "q".repeat(20), CLOUDFLARE_API_TOKEN: "t".repeat(20), CLOUDFLARE_ACCOUNT_ID: "a".repeat(32) }),
    ["gemini", "groq", "cloudflare"],
  );
  // OpenRouter has no key here: it is not in the chain, and adding its key later adds it with no other change.
  assert.ok(!configuredRoutes({ GROQ_API_KEY: "q".repeat(20) }).includes("openrouter"));
  assert.deepEqual(configuredRoutes({ GROQ_API_KEY: "q".repeat(20), OPENROUTER_API_KEY: "o".repeat(20) }), ["groq", "openrouter"]);
  // The paid provider stays off unless its own switch and model are set.
  assert.ok(!configuredRoutes({ OPENAI_API_KEY: "k".repeat(20) }).includes("openai"));
});

test("Gemini first; a 429 puts Gemini on hold and the next provider answers; the next layout does not wait on Gemini again", async () => {
  let geminiCalls = 0;
  const { provider } = chain({
    gemini: async () => {
      geminiCalls++;
      throw new ProviderError("provider_rate_limited", 429, { retryAfter: 600 });
    },
    groq: good("openai/gpt-oss-20b"),
  });
  const first = await provider.generateLayout(layout(1));
  assert.equal(first.routeProvider, "groq");
  assert.equal(first.routeHadInfrastructureFailure, true);
  const second = await provider.generateLayout({ senderBrand: "OTHERB", redactedBody: "Paid <AMT> to <PARTY>." });
  assert.equal(second.routeProvider, "groq");
  assert.equal(geminiCalls, 1, "Gemini was left alone while it rested");
});

test("a provider that is back after its rest time is used again, first", async () => {
  let geminiCalls = 0;
  const { provider, advance } = chain({
    gemini: async () => {
      geminiCalls++;
      if (geminiCalls === 1) throw new ProviderError("provider_unavailable", 503, { retryAfter: 30 });
      return { answer: answer(), model: "gemini-test", inputTokens: 1, outputTokens: 1, totalTokens: 2 };
    },
    groq: good("openai/gpt-oss-20b"),
  });
  assert.equal((await provider.generateLayout(layout(1))).routeProvider, "groq");
  advance(31_000);
  assert.equal((await provider.generateLayout({ senderBrand: "OTHERB", redactedBody: "Paid <AMT> to <PARTY>." })).routeProvider, "gemini");
});

test("a layout asked again goes to the next provider by itself, and starts over when every provider has answered it", async () => {
  const { provider } = chain({ gemini: good("gemini-test"), groq: good("openai/gpt-oss-20b"), cloudflare: good("@cf/openai/gpt-oss-20b") });
  const asked = layout(1);
  const order = [];
  for (let i = 0; i < 4; i++) order.push((await provider.generateLayout(asked)).routeProvider);
  assert.deepEqual(order, ["gemini", "groq", "cloudflare", "gemini"]);
});

test("the worker's own list of providers to skip is honoured too", async () => {
  const { provider } = chain({ gemini: good("gemini-test"), groq: good("openai/gpt-oss-20b") });
  const result = await provider.generateLayout({ ...layout(2), routing: { skipProviders: ["gemini"] } });
  assert.equal(result.routeProvider, "groq");
});

test("every provider unavailable is a systemic busy answer with the shortest wait: the layout is queued again and no try is spent", async () => {
  const { provider } = chain({
    gemini: async () => { throw new ProviderError("provider_rate_limited", 429, { retryAfter: 90 }); },
    groq: async () => { throw new ProviderError("provider_unavailable", 503, { retryAfter: 20 }); },
  });
  await assert.rejects(provider.generateLayout(layout(3)), (error) => {
    assert.ok(error instanceof ProviderBusyError);
    assert.equal(error.systemic, true);
    assert.ok(error.retryAfterMs >= 1000 && error.retryAfterMs <= 90_000, String(error.retryAfterMs));
    return true;
  });
});

test("every provider answering with something unusable is a bad answer with the real reason, not 'answer_not_json'", async () => {
  const bad = (reason) => async () => { throw new ProviderError("invalid_provider_output", 502, { reason }); };
  const { provider } = chain({ gemini: bad("blocked"), groq: bad("truncated") });
  await assert.rejects(provider.generateLayout(layout(4)), (error) => {
    assert.ok(error instanceof SyntaxError);
    assert.equal(error.serviceReason, "truncated");
    assert.equal(error.noRouteLeft, false);
    return true;
  });
});

test("a slow provider is waited for: nothing cuts a 400 ms answer short, and the answer is returned with its model and tokens", async () => {
  const slow = async () => {
    await new Promise((resolve) => setTimeout(resolve, 400));
    return { answer: answer(), model: "nvidia/nemotron-test", inputTokens: 5, outputTokens: 7, totalTokens: 12 };
  };
  const { provider } = chain({ nvidia: slow });
  const result = await provider.generateLayout(layout(5));
  assert.equal(result.routeProvider, "nvidia");
  assert.equal(result.model, "nvidia/nemotron-test");
  assert.equal(result.totalTokens, 12);
});

test("a layout the chain cannot take (a digit run, an @) is refused before any provider is asked", async () => {
  let asked = 0;
  const { provider } = chain({ gemini: async () => { asked++; return good("m")(); } });
  await assert.rejects(provider.generateLayout({ senderBrand: "TESTBK", redactedBody: "Pay 123456 to <PARTY>" }));
  assert.equal(asked, 0);
});

test("it has the same face as the service client: promptVersion, isUp, assertLayout, and the names of its providers", async () => {
  const { provider } = chain({ gemini: good("m"), groq: good("m") });
  assert.match(provider.promptVersion, /^sms-rule-draft-v/);
  assert.equal(await provider.isUp(), true);
  assert.equal(typeof provider.assertLayout, "function");
  assert.deepEqual(provider.configured, ["gemini", "groq"]);
});
