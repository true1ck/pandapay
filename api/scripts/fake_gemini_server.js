#!/usr/bin/env node
'use strict';
/**
 * A fake Gemini for local tests only (api/scripts/ is not in the image). It answers the SMS v2 drafts worker's
 * generateContent calls with a plausible answer by layout (keywords), and can be told to misbehave, so every
 * provider scenario can be forced without a real key or real quota.
 *
 *   node api/scripts/fake_gemini_server.js --port 4410
 *   SMS_V2_AI_BASE_URL=http://127.0.0.1:4410 GEMINI_API_KEYS=key-a,key-b node api/src/sms_v2/jobs/template_worker_main.js
 *
 * Control (JSON over HTTP, local only):
 *   POST /_faults  [{ "status": 429, "retryDelaySeconds": 5, "times": 2, "key": "key-a", "model": "m", "quota": "day" }]
 *                  or { "mode": "incomplete" | "badjson" | "empty" | "slow", "times": 1, "delayMs": 3000 }
 *                  or { "mode": "wrong", "wrong": "direction" | "balance_amount", "times": 1 }: a well-formed answer that is
 *                  wrong about the message (direction flipped; the balance slot used as the amount)
 *                  A fault applies to the next `times` matching calls (key and model optional).
 *   POST /_reset   clears faults and the log
 *   GET  /_log     one row per call: time, key, model, status, layout, sizes (never the system prompt)
 * Everything it sees is synthetic or already redacted.
 */
const http = require('node:http');

const tokens = (bytes) => Math.ceil(bytes / 3.2);

// The kind of message, from the words of the layout: just enough to give each layout a sensible reading.
function answerFor(layout) {
  const text = String(layout || '');
  const slot = (kind) => (text.match(new RegExp(`<${kind}\\d+>`, 'g')) || []).map((s) => s.slice(1, -1));
  const [amt1, amt2] = slot('amt');
  const [date1] = slot('date');
  const [mask1] = slot('mask');
  const [party1] = slot('party');
  const [ref1] = slot('ref');
  const has = (re) => re.test(text);
  const base = { confidence: 0.9 };
  if (has(/otp|one.time|verification code/i)) return { ...base, family: 'otp', emit: [{ factType: 'info', attrs: { category: 'otp' } }] };
  if (has(/\bdue\b|bill of|statement/i) && date1) {
    return {
      ...base, family: 'bill_due',
      emit: [{ factType: 'bill_due', attrs: { dueDate: { from: date1 }, ...(party1 ? { billerName: { from: party1 } } : {}) }, ...(amt1 ? { amounts: [{ role: 'due_total', from: amt1, unit: 'INR' }] } : {}) }],
    };
  }
  const credit = has(/credited|received|deposit/i);
  const debit = has(/debited|spent|paid|withdrawn|sent|purchase/i);
  if ((credit || debit) && amt1) {
    const movement = {
      factType: 'movement',
      attrs: { direction: credit && !debit ? 'credit' : 'debit', purpose: credit && !debit ? 'p2p' : 'purchase', rail: has(/upi/i) ? 'upi' : has(/card/i) ? 'card' : 'unknown' },
      amounts: [{ role: 'posted', from: amt1, unit: 'INR' }],
      ...(date1 ? { occurredAt: { from: date1 } } : {}),
      ...(mask1 ? { instrument: { kind: has(/card/i) ? 'credit_card' : 'bank_account', maskFrom: mask1 } } : {}),
      ...(party1 ? { counterparty: { nameFrom: party1, kind: 'merchant' } } : {}),
      ...(ref1 && has(/upi/i) ? { references: { upiRef: ref1 } } : {}),
    };
    const emit = [movement];
    if (amt2 && has(/bal/i)) {
      emit.push({ factType: 'balance_snapshot', attrs: { asOf: { field: 'occurredAt', sameAs: 0 } }, amounts: [{ role: 'available_balance', from: amt2, unit: 'INR' }], instrument: { sameAs: 0 } });
    }
    return { ...base, family: credit && !debit ? 'credit_alert' : 'debit_alert', emit };
  }
  return { ...base, family: 'service_notice', emit: [{ factType: 'info', attrs: { category: 'service' } }] };
}

// A well-formed but wrong answer, what the model does when it misreads a layout.
function makeWrong(answer, how) {
  const movement = answer.emit.find((e) => e.factType === 'movement');
  if (!movement) return answer;
  if (how === 'direction') movement.attrs.direction = movement.attrs.direction === 'debit' ? 'credit' : 'debit';
  if (how === 'balance_amount') {
    const balance = answer.emit.find((e) => e.factType === 'balance_snapshot');
    if (balance) movement.amounts[0].from = balance.amounts[0].from;
  }
  return answer;
}

function takeFault(faults, key, model) {
  const i = faults.findIndex((f) => (!f.key || f.key === key) && (!f.model || f.model === model));
  if (i < 0) return null;
  const fault = faults[i];
  if (--fault.times <= 0) faults.splice(i, 1);
  return fault;
}

const send = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
};

function handle(req, res, body, { faults, log }) {
  const url = new URL(req.url, 'http://local');
  if (url.pathname === '/_reset') { faults.length = 0; log.length = 0; return send(res, 200, { ok: true }); }
  if (url.pathname === '/_log') return send(res, 200, log);
  if (url.pathname === '/_faults') {
    for (const f of [].concat(JSON.parse(body || '[]'))) faults.push({ times: 1, ...f });
    return send(res, 200, { pending: faults.length });
  }
  const match = /^\/v1beta\/models\/([^/:]+):generateContent$/.exec(url.pathname);
  if (!match || req.method !== 'POST') return send(res, 404, { error: { message: 'not found' } });
  const model = decodeURIComponent(match[1]);
  const key = req.headers['x-goog-api-key'] || '';
  let request;
  try { request = JSON.parse(body); } catch { return send(res, 400, { error: { message: 'bad json' } }); }
  const system = request.systemInstruction?.parts?.[0]?.text || '';
  const prompt = request.contents?.[0]?.parts?.[0]?.text || '';
  let asked = {};
  try { asked = JSON.parse(prompt); } catch { /* the worker always sends JSON */ }
  const row = { at: new Date().toISOString(), key, model, layout: asked.layout, systemBytes: Buffer.byteLength(system), userBytes: Buffer.byteLength(prompt) };
  // Opt-in, for a person checking by hand what the model is sent (never set on a hosted worker).
  if (process.env.FAKE_GEMINI_KEEP_PROMPTS === '1') row.prompt = prompt;
  const done = (status, payload, headers) => { log.push({ ...row, status }); send(res, status, payload, headers); };

  const fault = takeFault(faults, key, model);
  const reply = () => {
    const answer = answerFor(asked.layout);
    if (fault?.mode === 'wrong') makeWrong(answer, fault.wrong);
    const inputTokens = tokens(row.systemBytes + row.userBytes);
    const text = JSON.stringify(answer);
    if (fault?.mode === 'badjson') return done(200, { candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '{"family": ' }] } }], usageMetadata: { promptTokenCount: inputTokens, candidatesTokenCount: 5, totalTokenCount: inputTokens + 5 } });
    if (fault?.mode === 'empty') return done(200, { candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '{}' }] } }], usageMetadata: { promptTokenCount: inputTokens, candidatesTokenCount: 1, totalTokenCount: inputTokens + 1 } });
    if (fault?.mode === 'incomplete') return done(200, { candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: text.slice(0, 40) }] } }], usageMetadata: { promptTokenCount: inputTokens, candidatesTokenCount: 1024, totalTokenCount: inputTokens + 1024 } });
    return done(200, { candidates: [{ finishReason: 'STOP', content: { parts: [{ text }] } }], usageMetadata: { promptTokenCount: inputTokens, candidatesTokenCount: tokens(text.length), totalTokenCount: inputTokens + tokens(text.length) } });
  };
  if (fault?.status) {
    const retry = fault.retryDelaySeconds
      ? { details: [{ '@type': 'type.googleapis.com/google.rpc.RetryInfo', retryDelay: `${fault.retryDelaySeconds}s` }] } : {};
    const quota = fault.quota === 'day'
      ? { details: [{ violations: [{ quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier' }], ...(retry.details?.[0] || {}) }] } : retry;
    return done(fault.status, { error: { code: fault.status, status: fault.status === 429 ? 'RESOURCE_EXHAUSTED' : 'ERROR', message: fault.message || 'fault', ...quota } });
  }
  if (fault?.mode === 'slow') return setTimeout(reply, fault.delayMs || 3000);
  return reply();
}

function start({ port = 4410, host = '127.0.0.1' } = {}) {
  const state = { faults: [], log: [] };
  const { faults, log } = state;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => { try { handle(req, res, body, state); } catch (error) { send(res, 500, { error: { message: String(error.message) } }); } });
  });
  return new Promise((resolve) => server.listen(port, host, () => resolve({ server, port: server.address().port, faults, log })));
}

module.exports = { start, answerFor };

if (require.main === module) {
  const i = process.argv.indexOf('--port');
  start({ port: i >= 0 ? Number(process.argv[i + 1]) : 4410 }).then(({ port }) => console.log(`fake gemini on http://127.0.0.1:${port}`));
}
