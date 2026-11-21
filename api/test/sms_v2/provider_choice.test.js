"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { chooseProvider } = require("../../src/sms_v2/jobs/template_worker_main");

const TOKEN = "a".repeat(40);
const run = (env) => {
  const logs = [];
  const provider = chooseProvider((entry) => logs.push(entry), env);
  return { provider, logs };
};

test("no service settings: no provider, no throw (Gemini is never used)", () => {
  const { provider, logs } = run({ GEMINI_API_KEY: "ignored" });
  assert.equal(provider, null);
  assert.equal(logs[0].status, "not_configured");
});

test("the providers run in the worker only when SMS_V2_AI_CHAIN=on, and only the ones that have a key", () => {
  const keys = { GEMINI_API_KEY: "g".repeat(24), GROQ_API_KEY: "q".repeat(24) };
  // Keys alone change nothing (a stray key on a developer machine, a deploy that adds keys before the switch is on).
  assert.equal(run(keys).provider, null);
  assert.equal(run({ ...keys, SMS_V2_AI_CHAIN: "off" }).provider, null);
  const { provider, logs } = run({ ...keys, SMS_V2_AI_CHAIN: "on" });
  assert.deepEqual(provider.configured, ["gemini", "groq"]);
  assert.deepEqual([logs[0].event, logs[0].status, logs[0].routes], ["sms_v2_ai_chain", "configured", ["gemini", "groq"]]);
  // On with no key at all: nothing to run, so the service client is tried, and with no service settings there is no provider.
  assert.equal(run({ SMS_V2_AI_CHAIN: "on" }).provider, null);
  // On, and a service configured as well: the chain wins; it is the owner's explicit choice.
  const both = run({ ...keys, SMS_V2_AI_CHAIN: "on", SMS_V2_AI_SERVICE_URL: "https://ai.example.test", SMS_V2_AI_SERVICE_TOKEN: TOKEN });
  assert.ok(Array.isArray(both.provider.configured));
});

test("malformed token or URL: no provider, a short code is logged, no throw", () => {
  for (const [env, code] of [
    [{ SMS_V2_AI_SERVICE_URL: "https://ai.example.test", SMS_V2_AI_SERVICE_TOKEN: "short" }, "SMS_V2_AI_SERVICE_TOKEN_invalid"],
    [{ SMS_V2_AI_SERVICE_URL: "not a url", SMS_V2_AI_SERVICE_TOKEN: TOKEN }, "SMS_V2_AI_SERVICE_URL_invalid"],
    [{ SMS_V2_AI_SERVICE_URL: "http://ai.example.test", SMS_V2_AI_SERVICE_TOKEN: TOKEN }, "SMS_V2_AI_SERVICE_URL_invalid"],
    [{ SMS_V2_AI_SERVICE_TOKEN: TOKEN }, "SMS_V2_AI_SERVICE_URL_invalid"],
  ]) {
    const { provider, logs } = run(env);
    assert.equal(provider, null);
    assert.deepEqual([logs[0].status, logs[0].code], ["misconfigured", code]);
  }
});

test("valid settings: the service provider", () => {
  const { provider } = run({ SMS_V2_AI_SERVICE_URL: "https://ai.example.test", SMS_V2_AI_SERVICE_TOKEN: TOKEN });
  assert.equal(typeof provider.generateLayout, "function");
});
