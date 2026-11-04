'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const c = require('../../src/sms_v2/contracts');

const FIX = path.join(c.SCHEMA_DIR, 'fixtures');
const read = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const files = (dir) => fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort().map((f) => ({ name: f, file: path.join(dir, f) }));

function validatorFor(dir) {
  switch (dir) {
    case 'fact': return c.validateFact;
    case 'instrument': return c.validateInstrument;
    case 'event': return c.validateEvent;
    case 'ledger_entry': return c.validateLedgerEntry;
    case 'bundle': return c.validateBundle;
    default: {
      const m = /^(request|response)\.(.+)$/.exec(dir);
      assert.ok(m, `unknown fixture directory ${dir}`);
      return (body) => (m[1] === 'request' ? c.validateRequest(m[2], body) : c.validateResponse(m[2], body));
    }
  }
}

const validDirs = fs.readdirSync(path.join(FIX, 'valid')).sort();
const invalidDirs = fs.readdirSync(path.join(FIX, 'invalid')).sort();

test('every valid fixture passes', () => {
  let count = 0;
  for (const dir of validDirs) {
    const v = validatorFor(dir);
    for (const { name, file } of files(path.join(FIX, 'valid', dir))) {
      const r = v(read(file));
      assert.deepEqual(r, { ok: true, errors: [] }, `${dir}/${name}`);
      count += 1;
    }
  }
  assert.ok(count >= 30 + 5, 'expected at least 3 fixtures per fact type plus the other kinds');
});

test('every invalid fixture fails with exactly the code in its file name', () => {
  let count = 0;
  const problems = [];
  for (const dir of invalidDirs) {
    const v = validatorFor(dir);
    for (const { name, file } of files(path.join(FIX, 'invalid', dir))) {
      const expected = name.replace(/\.json$/, '').split('~')[0];
      const r = v(read(file));
      const got = [...new Set(r.errors.map((e) => e.code))];
      if (r.ok || got.length !== 1 || got[0] !== expected) problems.push(`${dir}/${name}: got ${JSON.stringify(got)}`);
      for (const e of r.errors) assert.equal(typeof e.path, 'string');
      count += 1;
    }
  }
  assert.deepEqual(problems, []);
  assert.ok(count >= 200);
});

test('error_codes.json and the invalid fixtures cover each other', () => {
  const used = new Set();
  for (const dir of invalidDirs) for (const { name } of files(path.join(FIX, 'invalid', dir))) used.add(name.replace(/\.json$/, '').split('~')[0]);
  const listed = new Set(Object.keys(c.errorCodes));
  assert.deepEqual([...listed].filter((x) => !used.has(x)), [], 'codes with no invalid fixture');
  assert.deepEqual([...used].filter((x) => !listed.has(x)), [], 'fixture codes missing from error_codes.json');
});

test('at least 3 valid fixtures per fact type and 1 per other kind', () => {
  const facts = files(path.join(FIX, 'valid', 'fact')).map((f) => f.name.split('.')[0]);
  for (const t of ['movement', 'attempt', 'hold', 'balance_snapshot', 'limit_change', 'bill_due', 'mandate', 'reward', 'instrument_hint', 'info']) {
    assert.ok(facts.filter((x) => x === t).length >= 3, `valid fixtures for ${t}`);
  }
  for (const d of ['instrument', 'event', 'ledger_entry', 'bundle']) assert.ok(files(path.join(FIX, 'valid', d)).length >= 1, d);
});

test('later contract additions are accepted', () => {
  const base = read(path.join(FIX, 'valid', 'fact', 'movement.card_spend.json'));
  const withExtras = { ...base, attrs: { ...base.attrs, purpose: 'dividend', evidenceOnly: true } };
  assert.equal(c.validateFact(withExtras).ok, true);
  const mandate = read(path.join(FIX, 'valid', 'fact', 'mandate.one_time_ipo.json'));
  assert.equal(mandate.attrs.oneTime, true);
  assert.equal(mandate.attrs.mandatePurpose, 'ipo');
  assert.equal(c.validateFact(mandate).ok, true);
  const infoAmount = read(path.join(FIX, 'valid', 'fact', 'info.ipo_application_amount.json'));
  assert.equal(infoAmount.attrs.amountMinor, 1500000);
  assert.deepEqual(infoAmount.amounts, []);
  assert.equal(c.validateFact(infoAmount).ok, true);
  const oldInfo = read(path.join(FIX, 'valid', 'fact', 'info.service.json'));
  assert.equal('amountMinor' in oldInfo.attrs, false);
  assert.equal(c.validateFact(oldInfo).ok, true);
  for (const bad of [0, -1, 1.5, 'x']) {
    const r = c.validateFact({ ...infoAmount, attrs: { category: 'service', amountMinor: bad } });
    assert.equal(r.ok, false, String(bad));
    assert.ok(JSON.stringify(r).includes('fact.info.amountMinor_invalid'), String(bad));
  }
  const asMoney = c.validateFact({ ...infoAmount, attrs: { category: 'service' }, amounts: [{ role: 'informational', minor: 1500000, unit: 'INR' }] });
  assert.equal(asMoney.ok, false);
  assert.ok(JSON.stringify(asMoney).includes('fact.info.amount_count'));
  const ev = read(path.join(FIX, 'valid', 'event', 'card_bill_payment_complete.json'));
  for (const type of ['investment_withdrawal', 'dividend']) assert.equal(c.validateEvent({ ...ev, type }).ok, true, type);
  const dup = { ...ev, legs: [ev.legs[0], { factId: ev.legs[1].factId, role: 'duplicate_notice' }] };
  assert.equal(c.validateEvent(dup).ok, true);
  const led = read(path.join(FIX, 'valid', 'ledger_entry', 'own_unresolved.json'));
  assert.deepEqual(led.to, { ownUnresolved: 'credit_card' });
  assert.equal(c.validateLedgerEntry(led).ok, true);
  const bundle = read(path.join(FIX, 'valid', 'bundle', 'full.json'));
  assert.ok(bundle.counterpartyPurposes.length > 0);
  assert.ok(bundle.senders.some((s) => s.walletSpendVisibility === 'partial'));
  assert.ok(bundle.rules.some((r) => r.status === 'provisional' && r.match.templateHash));
  const sync = read(path.join(FIX, 'valid', 'response.sync', 'with_corrections.json'));
  assert.ok(Array.isArray(sync.corrections));
  assert.equal(c.validateResponse('sync', sync).ok, true);
});

test('bundleVersion 0 may carry a null signature; later versions may not', () => {
  const zero = read(path.join(FIX, 'valid', 'bundle', 'baseline_version_0.json'));
  assert.equal(zero.signature, null);
  assert.equal(c.validateBundle(zero).ok, true);
  assert.deepEqual(c.validateBundle({ ...zero, bundleVersion: 1 }).errors.map((e) => e.code), ['bundle.signature_required']);
});

test('the committed baseline bundle is a valid empty version 0 bundle', () => {
  const baseline = read(path.resolve(c.SCHEMA_DIR, '../../../app/assets/sms_rules/baseline_bundle.json'));
  assert.equal(baseline.bundleVersion, 0);
  assert.equal(baseline.rules.length, 0);
  assert.deepEqual(c.validateBundle(baseline), { ok: true, errors: [] });
});

test('unknown routes throw', () => {
  assert.throws(() => c.validateRequest('nope', {}), /unknown/);
  assert.throws(() => c.validateResponse('nope', {}), /unknown/);
});

test('validators never throw on non-object input', () => {
  for (const bad of [null, 42, 'x', [], undefined]) {
    assert.equal(c.validateFact(bad).ok, false);
    assert.equal(c.validateBundle(bad).ok, false);
    assert.equal(c.validateRequest('corrections', bad).ok, false);
  }
});
