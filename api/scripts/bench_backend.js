'use strict';

// Backend CPU benchmark (no database needed). Synthetic data only: the repo is public.
//
//   node scripts/bench_backend.js [--out baseline.json] [--compare baseline.json] [--iters 300]
//
// Each case times one call per message over a fixed corpus, reports p50/p95/mean in
// microseconds, and with --compare prints the change against a saved run.
// DB-bound routes are not covered: they need a scratch Postgres (see bench_sms_v2_facts.js).

process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'bench_only_not_a_real_secret';
const fs = require('node:fs');
const { parseSmsAgainstPatterns } = require('../src/sms_parser');

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : d; };
const ITERS = Number(flag('iters', '300'));

// --- corpus: every shape the route sees. `ok` is what the current parser must keep returning.
const corpus = [
  { sender: 'VM-HDFCBK-S', body: 'Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL on 04-08-26. Avl limit Rs.85,000.' },
  { sender: 'VM-ICICIB-S', body: 'INR 2,350.50 spent on ICICI Bank Card XX9876 at SWIGGY on 05-Aug-26. Avl Lmt INR 1,20,000.' },
  { sender: 'AX-AXISBK', body: 'Spent INR 640.00 Axis Bank Card no. XX1122 12-08-26 14:05:11 IST ZOMATO Avl Limit INR 40,000' },
  { sender: 'VM-SBIUPI', body: 'Dear UPI user A/C X1234 debited by 250.0 on date 06Aug26 trf to RAMESH STORES Refno 123456789012' },
  { sender: 'VM-HDFCBK', body: 'Rs. 12,000.00 credited to a/c XX5678 on 07-08-26 by NEFT from ACME PAYROLL. Avl bal Rs 45,000.' },
  { sender: 'VM-HDFCBK', body: '123456 is your OTP for transaction of Rs 500. Do not share with anyone.' },
  { sender: 'JD-OFFERS', body: 'Flat 20% off on your next order. Use code SAVE20. T&C apply.' },
  { sender: 'VM-HDFCBK', body: 'Your HDFC Bank Credit Card statement is generated. Total due Rs 8,450.00 due on 20-08-26.' },
  { sender: 'XX-UNKNOWN', body: 'Payment of Rs 799 made to NETFLIX using your card ending 3344 on 09-08-26.' },
  { sender: 'VM-KOTAKB', body: 'Sent Rs.1500.00 from Kotak Bank AC X9012 to friend@okaxis on 10-08-26. UPI Ref 987654321098.' },
];

// Active configured patterns as the route loads them from parser_patterns. `n` of them,
// mostly for other banks (they reject fast on sender), like production.
const bankNames = ['HDFCBK', 'ICICIB', 'AXISBK', 'SBIINB', 'KOTAKB', 'YESBNK', 'IDFCFB', 'INDUSB', 'PNBSMS', 'BOBTXN'];
function makePatterns(n) {
  const out = [];
  for (let i = 0; i < n; i += 1) {
    const bank = bankNames[i % bankNames.length];
    out.push({
      id: `p-${i}`,
      sender_pattern: bank,
      regex: `Rs\\.?\\s?([\\d,]+\\.?\\d*) spent on your ${bank} Card ending (\\d{4}) at ([A-Za-z0-9 &._-]+?) on (\\d{2}-\\d{2}-\\d{2})`,
      field_map: { amount: 1, last4: 2, merchant: 3, date: 4 },
      version: 1,
    });
  }
  return out;
}

function pct(sorted, p) { return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))]; }

function timeCase(name, fn) {
  for (let i = 0; i < 50; i += 1) fn(i); // warm-up: JIT + regex caches, so we measure steady state
  const samples = [];
  for (let i = 0; i < ITERS; i += 1) {
    const t = process.hrtime.bigint();
    fn(i);
    samples.push(Number(process.hrtime.bigint() - t) / 1000);
  }
  samples.sort((a, b) => a - b);
  const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
  return { name, p50: pct(samples, 0.5), p95: pct(samples, 0.95), mean };
}

const results = [];
for (const n of [0, 20, 100]) {
  const patterns = makePatterns(n);
  results.push(timeCase(`parseSmsAgainstPatterns patterns=${n}`, (i) => parseSmsAgainstPatterns(patterns, corpus[i % corpus.length])));
}

// Behaviour fingerprint: an optimisation must not change any parse result.
const fingerprint = JSON.stringify(corpus.map((m) => parseSmsAgainstPatterns(makePatterns(20), m)));
const crypto = require('node:crypto');
const digest = crypto.createHash('sha256').update(fingerprint).digest('hex').slice(0, 16);

const run = { node: process.version, iters: ITERS, fingerprint: digest, results };
const cmp = flag('compare');
const base = cmp ? JSON.parse(fs.readFileSync(cmp, 'utf8')) : null;
if (base && base.fingerprint !== digest) console.log(`!! parse output changed: ${base.fingerprint} -> ${digest}`);

console.log(`fingerprint ${digest}`);
for (const r of results) {
  const b = base && base.results.find((x) => x.name === r.name);
  const delta = b ? `  (baseline p50 ${b.p50.toFixed(1)}us, ${(b.p50 / r.p50).toFixed(2)}x)` : '';
  console.log(`${r.name.padEnd(44)} p50 ${r.p50.toFixed(1).padStart(8)}us  p95 ${r.p95.toFixed(1).padStart(8)}us  mean ${r.mean.toFixed(1).padStart(8)}us${delta}`);
}
if (flag('out')) fs.writeFileSync(flag('out'), JSON.stringify(run, null, 2));
