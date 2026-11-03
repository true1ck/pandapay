'use strict';

// WP-00 baseline of today's SERVER parser (parseSmsAgainstPatterns) over the
// golden cases in tools/sms_golden/cases.
//
// Tag: golden-baseline. `npm test` only runs test/*.test.js (not this folder),
// and the test is skipped unless SMS_GOLDEN_BASELINE=1, so normal CI skips it.
//
//   SMS_GOLDEN_BASELINE=1 node --test test/sms_golden_baseline/baseline.test.js
//
// It writes tools/sms_golden/reports/baseline_server.interpretations.json.
// Score it with tools/sms_golden/score_baseline.sh.
//
// Today's server parser has no v2 facts, so its output is mapped to the nearest
// v2 Fact. ok:false (no booking) becomes "ignored", as nothing reaches a ledger.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parseSmsAgainstPatterns } = require('../../src/sms_parser');

const enabled = process.env.SMS_GOLDEN_BASELINE === '1';
const goldenDir = process.env.SMS_GOLDEN_DIR || path.join(__dirname, '../../../tools/sms_golden');

function listJson(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...listJson(p));
    else if (e.name.endsWith('.json')) out.push(p);
  }
  return out.sort();
}

function instrumentFor(fields) {
  const card = fields.cardLast4 || fields.last4 || null;
  const acct = fields.accountLast4 || null;
  const kinds = {
    credit_card: 'credit_card',
    debit_card: 'debit_card',
    wallet: 'wallet',
    upi_bank: 'bank_account',
  };
  let kind = kinds[fields.instrument] || null;
  const mask = card || acct;
  if (!kind && mask) kind = card ? 'credit_card' : 'bank_account';
  const out = {};
  if (kind) out.kind = kind;
  if (mask) out.maskDigits = String(mask);
  return out;
}

function interpret(sender, body) {
  let r;
  try {
    r = parseSmsAgainstPatterns([], { sender, body });
  } catch (_) {
    return { facts: [], unknown: true };
  }
  if (!r || !r.ok) return { facts: [], unknown: false };
  const f = r.fields || {};
  const kind = f.entryKind;
  const purpose = { spend: 'purchase', investment: 'investment', transfer: 'transfer' }[kind];
  const direction = { spend: 'debit', investment: 'debit', income: 'credit' }[kind];
  const inst = instrumentFor(f);
  const facts = [];
  if (f.amountInr != null) {
    const attrs = {};
    if (direction) attrs.direction = direction;
    if (purpose) attrs.purpose = purpose;
    const fact = {
      factType: 'movement',
      attrs,
      amounts: [{ role: 'posted', minor: Math.round(Number(f.amountInr) * 100) }],
    };
    if (Object.keys(inst).length) fact.instrument = inst;
    facts.push(fact);
  }
  if (f.availableBalanceInr != null) {
    const fact = {
      factType: 'balance_snapshot',
      amounts: [{ role: 'available_balance', minor: Math.round(Number(f.availableBalanceInr) * 100) }],
    };
    if (Object.keys(inst).length) fact.instrument = inst;
    facts.push(fact);
  }
  return { facts, unknown: false };
}

test('server parser baseline over the golden cases', { skip: enabled ? false : 'golden baseline: set SMS_GOLDEN_BASELINE=1 (tag golden-baseline)' }, () => {
  const results = {};
  let messages = 0;
  for (const file of listJson(path.join(goldenDir, 'cases'))) {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'));
    c.messages.forEach((m, i) => {
      results[`${c.id}#${i}`] = interpret(m.sender, m.body);
      messages += 1;
    });
  }
  assert.ok(messages >= 80, `expected at least 80 messages, got ${messages}`);
  const outFile = path.join(goldenDir, 'reports', 'baseline_server.interpretations.json');
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(
    outFile,
    `${JSON.stringify({ engine: 'server: parseSmsAgainstPatterns', results }, null, 2)}\n`,
  );
  assert.ok(fs.existsSync(outFile));
});
