"use strict";
// S1-5: the layout upload's rate bucket is charged once for the request, and for the batch only after it is
// accepted and only for layouts new to this person today. A refused or repeated batch costs one unit.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createTemplateHandler } = require("../../src/sms_v2/ai_templates");
const { layoutItem } = require("./fixtures/template_draft");

function fakeResponse() {
  return {
    statusCode: 200, headers: {}, body: null,
    status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    removeHeader(name) { delete this.headers[name]; },
    json(body) { this.body = body; return this; },
  };
}
const batch = (n) => ({ items: Array.from({ length: n }, (_, i) => layoutItem(i)) });

function rig({ submit, allow = () => true }) {
  const charged = [];
  const security = {
    verifyAttestation: async () => true,
    storedSettings: async () => ({}),
    checkRate: async (_req, route, units) => { charged.push(units); return allow(units, charged); },
  };
  return { charged, handler: createTemplateHandler({ store: { submit }, security }) };
}
const run = async (handler, body) => { const res = fakeResponse(); await handler({ body, userId: "u", headers: {} }, res); return res; };

test("a batch the database refuses (400 or 5xx) is charged one unit, however often the phone retries", async () => {
  const r = rig({ submit: async () => { throw Object.assign(new Error("bad"), { code: "22023" }); } });
  for (let i = 0; i < 7; i++) assert.equal((await run(r.handler, batch(10))).statusCode, 400);
  assert.deepEqual(r.charged, [1, 1, 1, 1, 1, 1, 1], "was 70 units: a day-long 429 after about five retries");
});

test("a lost-response resend of layouts already counted today costs one unit", async () => {
  const r = rig({ submit: async (_u, items) => Object.assign(items.map((i) => i.templateHash), { fresh: 0 }) });
  assert.equal((await run(r.handler, batch(10))).statusCode, 202);
  assert.deepEqual(r.charged, [1]);
});

test("new layouts are charged after acceptance; a refused late charge never fails the stored batch", async () => {
  const r = rig({ submit: async (_u, items) => Object.assign(items.map((i) => i.templateHash), { fresh: 10 }),
    allow: (units) => units === 1 });
  const res = await run(r.handler, batch(10));
  assert.equal(res.statusCode, 202);
  assert.equal(res.body.accepted.length, 10);
  assert.deepEqual(r.charged, [1, 9]);
  assert.equal(res.headers["Retry-After"], undefined);
});

test("the request is still refused up front when the bucket has no room", async () => {
  let submitted = 0;
  const r = rig({ submit: async () => { submitted++; return []; }, allow: () => false });
  assert.equal((await run(r.handler, batch(3))).statusCode, 429);
  assert.equal(submitted, 0);
});
