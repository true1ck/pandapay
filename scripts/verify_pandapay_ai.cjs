"use strict";

const assert = require("node:assert/strict");
const { once } = require("node:events");
const path = require("node:path");
const test = require("node:test");

const { createAiServiceProvider } = require("../api/src/sms_v2/ai_service_provider");
const { runTemplateWorkerOnce } = require("../api/src/sms_v2/template_worker");
const { answer, config, template } = require("../api/test/sms_v2/fixtures/template_draft");

test("PandaPay AI transport persists a validated draft after an outage", async () => {
  const project = path.resolve(process.env.PANDAPAY_AI_PROJECT_DIR || path.join(__dirname, "../../PandaPay-AI"));
  const { createServer } = require(path.join(project, "src/server"));
  const { createGeminiProvider } = require(path.join(project, "src/gemini"));
  const token = "synthetic-cross-project-service-token";
  const sampleMarker = "LOCAL WORDING ONLY";
  let available = false;
  let providerCalls = 0;
  const requestLog = [];
  const generate = createGeminiProvider({
    apiKey: "synthetic-gemini-key",
    model: config.model,
    async fetchImpl(_url, options) {
      providerCalls++;
      assert.ok(!options.body.includes(sampleMarker));
      if (!available) return new Response(null, { status: 503, headers: { "Retry-After": "17" } });
      return Response.json({
        candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify(answer()) }] } }],
        usageMetadata: { promptTokenCount: 27, candidatesTokenCount: 12, totalTokenCount: 39 },
      });
    },
  });
  const server = createServer({
    token,
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    generate,
    log: (entry) => requestLog.push(entry),
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  let state = "queued";
  let draft;
  const requests = [];
  const attempts = [];
  try {
    const url = `http://127.0.0.1:${server.address().port}`;
    const provider = createAiServiceProvider({
      env: { SMS_V2_AI_SERVICE_URL: url, SMS_V2_AI_SERVICE_TOKEN: token },
      async fetchImpl(uri, options) {
        assert.equal(new URL(uri).origin, url);
        requests.push(JSON.parse(options.body));
        return fetch(uri, options);
      },
    });
    const store = {
      async claim() {
        if (state !== "queued") return null;
        state = "working";
        return { ...template, sample: sampleMarker };
      },
      async beginAttempt() { return null; },
      async recordAttempt(_template, _index, attempt) { attempts.push(attempt); },
      async finish(_template, outcome) {
        draft = outcome.rule;
        state = outcome.requeue ? "queued" : draft ? "ready" : "failed";
      },
    };

    const outage = await runTemplateWorkerOnce({ store, provider, config });
    assert.equal(outage.status, "provider_busy");
    assert.equal(state, "queued");
    assert.equal(providerCalls, 1);
    assert.equal(draft, undefined);

    available = true;
    const recovered = await runTemplateWorkerOnce({ store, provider, config });
    assert.equal(recovered.status, "ready");
    assert.equal(state, "ready");
    assert.equal(draft.status, "provisional");
    assert.equal(draft.match.templateHash, template.template_hash);
    assert.equal(attempts.at(-1).totalTokens, 39);
    assert.deepEqual(requests, Array(2).fill({
      senderBrand: template.sender_brand,
      redactedBody: template.redacted_body,
    }));
    assert.equal(providerCalls, 2);
    assert.equal((await runTemplateWorkerOnce({ store, provider, config })).status, "idle");
    assert.equal(requests.length, 2);
    assert.ok(requestLog.length >= 2);
    assert.ok(!JSON.stringify(requestLog).includes(template.redacted_body));
    assert.ok(!JSON.stringify(requestLog).includes(token));
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
