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
