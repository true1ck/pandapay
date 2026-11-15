"use strict";
// Every scenario of the AI drafts pipeline, end to end on this machine: the real worker and the real Gemini provider
// talk real HTTP to a fake Gemini (api/scripts/fake_gemini_server.js) that can be told to misbehave. The queue is in
// memory and the clock is ours, so a wait of minutes costs nothing. (The same worker against Postgres is in
// ai_pipeline_v3_pg.test.js; the phone side is in the app tests and on the emulator.)
const test = require("node:test");
const assert = require("node:assert/strict");
const fakeGemini = require("../../scripts/fake_gemini_server");
const { config } = require("./fixtures/template_draft");
const { mergeSettings } = require("../../src/sms_v2/settings");
const {
  runTemplateWorkerOnce,
  createGeminiTemplateProvider,
  validateDraft,
  PROMPT_VERSION,
} = require("../../src/sms_v2/template_worker");

const hashOf = (i) => i.toString(16).padStart(64, "0");
const LAYOUTS = [
  "<AMT> debited from A/c <MASK> on <DATE> to <PARTY>. UPI Ref <REF>. Avl Bal <AMT>.",
  "Dear Customer, your OTP is <REF>. Do not share it with anyone.",
  "<AMT> spent on card <MASK> on <DATE>. Avl limit <AMT>.",
  "Your account <MASK> was credited with <AMT> on <DATE>.",
  "Your <PARTY> bill of <AMT> is due on <DATE>.",
  "Your account has been updated.",
  "Money sent to <VPA> successfully. UPI Ref <REF>.",
  "<AMT> spent on card <MASK>.",
];

async function rig(t, { keys = ["key-a", "key-b"], fallbackModel = null, settings = {}, rules = [], layouts = LAYOUTS, samples = {} } = {}) {
  const fake = await fakeGemini.start({ port: 0 });
  t.after(() => fake.server.close());
  const clock = { t: 1_000_000, now() { return this.t; }, advance(ms) { this.t += ms; } };
  const provider = createGeminiTemplateProvider({ apiKeys: keys, baseUrl: `http://127.0.0.1:${fake.port}`, now: () => clock.now(), fallbackModel });
  const rows = layouts.map((body, i) => ({ template_hash: hashOf(i + 1), sender_brand: "TESTBK", redacted_body: body, sample: samples[i] ?? null, ai_status: "queued", order: i, detail: null, code: null, draft: null, covered: null }));
  const attempts = [];
  const store = {
    settings: async () => ({ ...mergeSettings([]), ai_min_gap_seconds: 20, ...settings }),
    monthSpend: async () => 0,
    claim: async () => {
      const row = rows.filter((r) => r.ai_status === "queued").sort((a, b) => a.order - b.order)[0];
      if (!row) return null;
      row.ai_status = "working";
      return { ...row, lease_id: `lease-${row.template_hash}` };
    },
    activeRules: async () => rules,
    userReports: async () => ({}),
    previousMistakes: async () => [],
    providerFailures: async () => attempts.filter((a) => a.outcome === "rejected" && !a.totalTokens).length,
    providerRecentlyWorked: async () => attempts.some((a) => a.totalTokens > 0),
    beginAttempt: async (template, attempt) => (attempts.push({ hash: template.template_hash, attempt }), null),
    recordAttempt: async (template, attempt, usage) => Object.assign(attempts.findLast((a) => a.hash === template.template_hash && a.attempt === attempt), usage),
    finish: async (template, out) => {
      const row = rows.find((r) => r.template_hash === template.template_hash);
      row.ai_status = out.covered ? "covered" : out.requeue ? "queued" : out.rule ? "ready" : "failed";
      row.code = out.code ?? null;
      row.detail = out.detail ?? null;
      row.draft = out.rule ?? null;
      row.covered = out.covered ?? null;
      if (row.ai_status !== "queued") row.sample = null;
    },
  };
  const post = (path, body) => fetch(`http://127.0.0.1:${fake.port}${path}`, { method: "POST", body: JSON.stringify(body ?? {}) }).then((r) => r.json());
  const results = [];
  // Runs the worker like the service does: after a provider wait, time passes (and nothing else happens).
  const drain = async (max = 60) => {
    for (let i = 0; i < max; i++) {
      const result = await runTemplateWorkerOnce({ store, provider, config, clock: () => clock.now() });
      results.push(result);
      if (result.status === "idle") return results;
      if (result.status === "provider_busy") clock.advance(Math.max(result.retryAfterMs || 0, 5000));
      else if (result.gapSeconds) clock.advance(result.gapSeconds * 1000);
    }
    throw new Error(`the queue did not drain: ${JSON.stringify(results.slice(-4))}`);
  };
  const calls = () => fetch(`http://127.0.0.1:${fake.port}/_log`).then((r) => r.json());
  return { rows, attempts, store, provider, clock, drain, post, calls, results };
}
const states = (rows) => rows.map((r) => r.ai_status);

test("S1 a queue of layouts drains first in, first out, every rule passes the checks, and a request stays small", async (t) => {
  const r = await rig(t);
  await r.drain();
  assert.deepEqual(states(r.rows), Array(LAYOUTS.length).fill("ready"));
  const log = await r.calls();
  assert.deepEqual(log.map((c) => c.layout.replace(/<[a-z]+\d>/g, "")).slice(0, 2), [LAYOUTS[0], LAYOUTS[1]].map((l) => l.replace(/<[A-Z]+>/g, "")), "arrival order");
  for (const row of r.rows) assert.deepEqual(validateDraft(row.draft, row, config.model), [], row.redacted_body);
  const worst = Math.max(...log.map((c) => (c.systemBytes + c.userBytes) / 3.2));
  assert.ok(worst < 1800, `largest request ${Math.round(worst)} tokens`);
  // The worker rests after every call that reached Gemini (the console's gap), so the queue never bursts.
  assert.ok(r.results.filter((x) => x.status === "ready").every((x) => x.gapSeconds === 20));
});

test("S2 a rate-limited key hands over to the other, rests for the wait Gemini gave, and is used again after it", async (t) => {
  const r = await rig(t);
  await r.post("/_faults", [{ status: 429, retryDelaySeconds: 30, key: "key-a", times: 1 }]);
  await r.drain();
  assert.deepEqual(states(r.rows), Array(LAYOUTS.length).fill("ready"));
  const log = await r.calls();
  const limited = log.findIndex((c) => c.status === 429);
  assert.equal(log[limited].key, "key-a");
  assert.equal(log.filter((c) => c.status === 429).length, 1, "limited once, not asked again while it rests");
  // Calls made while it rested (the first two layouts took 40 s with the gap) all went to key-b ...
  assert.equal(log[limited + 1].key, "key-b");
  // ... and once the 30 s were over key-a served again.
  assert.ok(log.slice(limited + 1).some((c) => c.key === "key-a" && c.status === 200), "key-a is used again after its rest");
  assert.equal(r.provider.waitMs(), 0);
});

test("S3 when every key is limited the layout waits at its place and nothing is failed; then it is drafted", async (t) => {
  const r = await rig(t);
  await r.post("/_faults", [{ status: 429, retryDelaySeconds: 40, times: 2 }]);
  await r.drain();
  assert.deepEqual(states(r.rows), Array(LAYOUTS.length).fill("ready"));
  assert.equal(r.rows[0].code, null);
  assert.ok(r.results.some((x) => x.status === "provider_busy"));
  // The first layout was the first to be drafted again (it kept its place).
  const log = await r.calls();
  assert.equal(log.find((c) => c.status === 200).layout, "<amt1> debited from A/c <mask1> on <date1> to <party1>. UPI Ref <ref1>. Avl Bal <amt2>.");
});

test("S4 a daily quota makes the worker wait half an hour, not minutes", async (t) => {
  const r = await rig(t, { keys: ["only"], layouts: [LAYOUTS[1]] });
  await r.post("/_faults", [{ status: 429, quota: "day", times: 1 }]);
  const first = await runTemplateWorkerOnce({ store: r.store, provider: r.provider, config, clock: () => r.clock.now() });
  assert.equal(first.status, "provider_busy");
  assert.ok(first.retryAfterMs >= 1_800_000, `waits ${first.retryAfterMs} ms`);
  assert.equal(r.rows[0].ai_status, "queued");
});

test("S5 an overloaded Gemini (503) is waited out; the layout's tries are not used up", async (t) => {
  const r = await rig(t, { layouts: [LAYOUTS[0]] });
  await r.post("/_faults", [{ status: 503, times: 3 }]);
  await r.drain();
  assert.equal(r.rows[0].ai_status, "ready");
  assert.equal(r.attempts.filter((a) => a.errorKind === "provider_busy").length, 3);
  assert.ok(r.attempts.filter((a) => a.errorKind === "provider_busy").every((a) => a.httpStatus === 503));
  assert.equal(r.attempts.findLast((a) => a.errorKind === null).outcome, "valid");
});

test("S6 an answer that is not JSON is repaired once with the reason; twice in a row is a named failure", async (t) => {
  const once = await rig(t, { layouts: [LAYOUTS[1]] });
  await once.post("/_faults", [{ mode: "badjson", times: 1 }]);
  await once.drain();
  assert.equal(once.rows[0].ai_status, "ready");
  assert.equal(once.attempts[0].errorKind, "json_invalid");

  const twice = await rig(t, { layouts: [LAYOUTS[1]] });
  await twice.post("/_faults", [{ mode: "badjson", times: 2 }]);
  await twice.drain();
  assert.equal(twice.rows[0].ai_status, "failed");
  assert.equal(twice.rows[0].code, "draft_validation_failed");
  assert.deepEqual(twice.rows[0].detail, ["json_invalid", "answer_not_json"]);
});

test("S7 an answer cut off by the output limit, or empty, is a named failure with its reason", async (t) => {
  const cut = await rig(t, { layouts: [LAYOUTS[1]] });
  await cut.post("/_faults", [{ mode: "incomplete", times: 2 }]);
  await cut.drain();
  assert.deepEqual([cut.rows[0].ai_status, cut.rows[0].detail], ["failed", ["provider_error", "template_provider_incomplete"]]);

  const empty = await rig(t, { layouts: [LAYOUTS[1]] });
  await empty.post("/_faults", [{ mode: "empty", times: 2 }]);
  await empty.drain();
  assert.deepEqual([empty.rows[0].ai_status, empty.rows[0].detail], ["failed", ["answer_invalid", "answer_shape_invalid"]]);
});

test("S8 an old model name (404) uses the fallback model; with none, layouts wait and are never failed", async (t) => {
  const withFallback = await rig(t, { layouts: [LAYOUTS[1]], fallbackModel: "newer-model" });
  await withFallback.post("/_faults", [{ status: 404, model: "test-model", times: 5 }]);
  await withFallback.drain();
  assert.equal(withFallback.rows[0].ai_status, "ready");
  assert.deepEqual((await withFallback.calls()).map((c) => c.model), ["test-model", "newer-model"]);

  const none = await rig(t, { layouts: [LAYOUTS[1]] });
  await none.post("/_faults", [{ status: 404, times: 99 }]);
  const result = await runTemplateWorkerOnce({ store: none.store, provider: none.provider, config, clock: () => none.clock.now() });
  assert.equal(result.status, "provider_busy");
  assert.equal(result.systemic, true);
  assert.equal(none.rows[0].ai_status, "queued", "an account problem never fails a layout");
});

test("S9 a revoked key (403) waits for a fix; once fixed the same layout is drafted", async (t) => {
  const r = await rig(t, { keys: ["only"], layouts: [LAYOUTS[1]] });
  await r.post("/_faults", [{ status: 403, message: "API key not valid", times: 1 }]);
  const first = await runTemplateWorkerOnce({ store: r.store, provider: r.provider, config, clock: () => r.clock.now() });
  assert.equal(first.status, "provider_busy");
  assert.equal(first.systemic, true);
  await r.drain();
  assert.equal(r.rows[0].ai_status, "ready");
});

test("S10 the message wording reaches Gemini only when allowed, aligned and safe, and is deleted with a final answer", async (t) => {
  const sample = "Rs.4821.50 debited from A/c XX1234 on 20-Nov-26 to <PARTY>. UPI Ref 427711903388. Avl Bal Rs.10500.25.";
  const on = await rig(t, { layouts: [LAYOUTS[0]], samples: { 0: sample } });
  await on.drain();
  assert.equal(on.rows[0].sample, null, "deleted once the answer is final");
  const bodies = [];
  const fakeProbe = await rig(t, { layouts: [LAYOUTS[0]], samples: { 0: sample } });
  fakeProbe.provider.generate = ((orig) => async (args) => (bodies.push(JSON.parse(args.prompt)), orig(args)))(fakeProbe.provider.generate.bind(fakeProbe.provider));
  await fakeProbe.drain();
  assert.equal(bodies[0].slotValues.amt1, "Rs.4821.50");
  assert.equal(bodies[0].slotValues.party1, "SYNTHETIC STORE", "a name tag is filled with a made-up one");

  const off = await rig(t, { layouts: [LAYOUTS[0]], samples: { 0: sample }, settings: { ai_use_sample: false } });
  const seenOff = [];
  off.provider.generate = ((orig) => async (args) => (seenOff.push(JSON.parse(args.prompt)), orig(args)))(off.provider.generate.bind(off.provider));
  await off.drain();
  assert.equal("sample" in seenOff[0], false);
});

test("S11 a layout an existing rule already reads is never sent; one that is too garbled is refused by name, also unsent", async (t) => {
  const { buildMatcher } = require("../../src/sms_v2/layout_matcher");
  const covering = { id: "TESTBK-OTP", version: 1, senders: ["TESTBK"], family: "otp", match: { pattern: buildMatcher(LAYOUTS[1]).pattern, flags: "i" } };
  const r = await rig(t, { layouts: [LAYOUTS[1], "<PARTY> a <PARTY> b <PARTY> c <PARTY>"], rules: [covering] });
  await r.drain();
  assert.deepEqual(states(r.rows), ["covered", "failed"]);
  assert.equal(r.rows[1].code, "layout_too_many_wildcards");
  assert.equal((await r.calls()).length, 0, "Gemini was not called at all");
});

test("S12 a mixed day: limits, overload, a bad answer and a good one, all in one queue, end with every layout decided and none lost", async (t) => {
  const r = await rig(t);
  await r.post("/_faults", [
    { status: 429, retryDelaySeconds: 15, key: "key-a", times: 1 },
    { status: 503, times: 2 },
    { mode: "badjson", times: 1 },
    { mode: "slow", delayMs: 50, times: 1 },
  ]);
  await r.drain();
  assert.ok(r.rows.every((x) => ["ready", "failed", "covered"].includes(x.ai_status)), JSON.stringify(states(r.rows)));
  assert.equal(r.rows.filter((x) => x.ai_status === "ready").length, LAYOUTS.length, "every transient problem was recovered from");
  assert.ok(r.attempts.every((a) => a.promptVersion === PROMPT_VERSION || a.promptVersion === undefined));
});

test("S13 the request is small for every layout and stays under the token budget", async (t) => {
  const r = await rig(t);
  await r.drain();
  const log = await r.calls();
  const sizes = log.map((c) => Math.round((c.systemBytes + c.userBytes) / 3.2));
  assert.ok(sizes.every((n) => n < 1800), `request sizes (tokens): ${sizes.join(", ")}`);
});
