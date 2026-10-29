const test = require('node:test');
const assert = require('node:assert');
const {
  detectRecurringSeries,
  annualCost,
  isUsableSubscriptionName,
  nextExpectedAfter,
  isDisplayableSubscriptionRecord,
  classifySubscriptionEvidence,
  deriveSubscriptionProjection,
  deriveSubscriptionStatus,
} = require('../src/recurring');

/**
 * Subscription detection is deliberately conservative, and these tests are
 * mostly about what it must NOT claim.
 *
 * A false positive is worse than a miss: telling someone a one-off purchase
 * will recur, and predicting a date for it, makes every other figure on the
 * screen suspect. Missing a subscription costs them nothing they didn't
 * already lack.
 */
function txn(merchant, amount, isoDate, extra = {}) {
  return {
    merchant_name: merchant,
    amount_inr: amount,
    occurred_at: new Date(isoDate),
    category_id: extra.categoryId ?? null,
    user_card_id: extra.cardId ?? null,
  };
}

/** n monthly charges of the same amount, starting from `startIso`. */
function monthly(merchant, amount, startIso, count) {
  const start = new Date(startIso);
  const rows = [];
  for (let i = 0; i < count; i += 1) {
    const d = new Date(start);
    d.setDate(d.getDate() + i * 30);
    rows.push(txn(merchant, amount, d.toISOString()));
  }
  return rows;
}

test('three regular monthly charges are detected', () => {
  const series = detectRecurringSeries(monthly('Netflix', 649, '2026-05-03', 3));
  assert.strictEqual(series.length, 1);
  assert.strictEqual(series[0].displayName, 'Netflix');
  assert.strictEqual(series[0].typicalAmountInr, 649);
  assert.strictEqual(series[0].cadenceDays, 30);
  assert.strictEqual(series[0].occurrenceCount, 3);
  assert.equal(series[0].reviewCandidate, true);
});

test('regular merchant visits are review candidates, never confirmed evidence', () => {
  const series = detectRecurringSeries(monthly('Blue Tokai', 350, '2026-05-03', 4));
  assert.equal(series.length, 1);
  assert.equal(series[0].reviewCandidate, true);
  assert.equal(series[0].subscriptionEvidence, 'posted_payment_pattern');
});

test('two anonymous charges are not enough', () => {
  // Two of anything is a coincidence waiting to be disproved — for
  // merchants without a brand-name match; known brands admit on two
  // (see the brand test below).
  assert.strictEqual(detectRecurringSeries(monthly('Blue Tokai', 350, '2026-05-03', 2)).length, 0);
});

test('the next charge is predicted one cadence after the last', () => {
  const series = detectRecurringSeries(monthly('Spotify', 119, '2026-06-01', 4), {
    now: new Date('2026-07-01T00:00:00Z'),
  });
  const last = new Date(series[0].lastSeenOn);
  const next = new Date(series[0].nextExpectedOn);
  assert.ok(next > last);
});

test('an old series rolls its next date forward instead of returning a past date', () => {
  const series = detectRecurringSeries(monthly('Old Service', 499, '2025-06-01', 4), {
    now: new Date('2026-10-20T12:00:00Z'),
  });
  const next = new Date(series[0].nextExpectedOn);
  assert.ok(next > new Date('2026-10-20T00:00:00Z'));
  assert.equal(
    next.toISOString().slice(0, 10),
    nextExpectedAfter(
      new Date('2025-08-30T00:00:00Z'),
      30,
      new Date('2026-10-20T00:00:00Z'),
    ).toISOString().slice(0, 10),
  );
});

test('monthly dates preserve the billing day instead of drifting by 30 days', () => {
  assert.equal(
    nextExpectedAfter(
      new Date('2026-01-31T00:00:00Z'),
      30,
      new Date('2026-03-01T00:00:00Z'),
    ).toISOString().slice(0, 10),
    '2026-03-31',
  );
});

test('billing that drifts by a day or two is still one series', () => {
  // Real billing lands on the 3rd, then the 5th because the 3rd was a
  // Sunday, then the 2nd. Demanding metronomic gaps would reject almost
  // every real subscription.
  const rows = [
    txn('Netflix', 649, '2026-05-03'),
    txn('Netflix', 649, '2026-06-05'),
    txn('Netflix', 649, '2026-07-02'),
    txn('Netflix', 649, '2026-08-04'),
  ];
  assert.strictEqual(detectRecurringSeries(rows).length, 1);
});

test('irregular visits to the same merchant are not a subscription', () => {
  // A coffee shop visited whenever, at the same price, must not be
  // reported as a recurring charge with a predicted date.
  const rows = [
    txn('Blue Tokai', 350, '2026-05-03'),
    txn('Blue Tokai', 350, '2026-05-06'),
    txn('Blue Tokai', 350, '2026-07-28'),
    txn('Blue Tokai', 350, '2026-08-01'),
  ];
  assert.strictEqual(detectRecurringSeries(rows).length, 0);
});

test('a merchant that is both a subscription and a shop separates the two', () => {
  // Amazon Prime at 1,499/yr alongside ordinary Amazon shopping: mixing
  // them would produce a nonsense cadence and a nonsense amount.
  const rows = [
    ...monthly('Amazon', 199, '2026-01-05', 6),
    txn('Amazon', 4300, '2026-02-11'),
    txn('Amazon', 780, '2026-03-19'),
    txn('Amazon', 12500, '2026-05-02'),
  ];
  const series = detectRecurringSeries(rows);
  assert.strictEqual(series.length, 1);
  assert.strictEqual(series[0].typicalAmountInr, 199, 'the one-off purchases must not move the amount');
  assert.strictEqual(series[0].occurrenceCount, 6);
});

test('a small price rise stays one series', () => {
  // Subscriptions raise prices. A 5% increase is the same subscription.
  const rows = [
    txn('Hotstar', 299, '2026-03-01'),
    txn('Hotstar', 299, '2026-03-31'),
    txn('Hotstar', 310, '2026-04-30'),
    txn('Hotstar', 310, '2026-05-30'),
  ];
  assert.strictEqual(detectRecurringSeries(rows).length, 1);
});

test('charges with no merchant name are never grouped', () => {
  // Two unnamed 499 charges are not evidence of anything.
  const rows = [
    txn(null, 499, '2026-05-01'),
    txn(null, 499, '2026-05-31'),
    txn('', 499, '2026-06-30'),
  ];
  assert.strictEqual(detectRecurringSeries(rows).length, 0);
});

test('placeholder names from mandate alerts are never treated as merchants', () => {
  const rows = [
    ...monthly('7308080808', 2000, '2026-05-01', 3),
    ...monthly('31/12/2035', 1850, '2026-05-01', 3),
    ...monthly('MONTHLY', 1649, '2026-05-01', 3),
    ...monthly('paytm-98510@ptys', 210, '2026-05-01', 5),
    ...monthly('Kavlekar petroleum', 500, '2026-05-01', 4),
  ];
  assert.equal(detectRecurringSeries(rows).length, 0);
  assert.equal(isUsableSubscriptionName('OpenAI'), true);
  assert.equal(isUsableSubscriptionName('OpenAILLC'), true);
  assert.equal(isUsableSubscriptionName('7308080808'), false);
  assert.equal(isUsableSubscriptionName('31/12/2035'), false);
  assert.equal(isUsableSubscriptionName('MONTHLY'), false);
  assert.equal(isUsableSubscriptionName('paytm-98510@ptys'), false);
  assert.equal(isUsableSubscriptionName('Kavlekar petroleum'), false);
  assert.equal(isUsableSubscriptionName('Indian Oil Petrol Pump'), false);
});

test('merchant name formatting differences are one series, not several', () => {
  const rows = [
    txn('NETFLIX.COM', 649, '2026-05-03'),
    txn('Netflix', 649, '2026-06-02'),
    txn('netflix*subscription', 649, '2026-07-02'),
  ];
  const series = detectRecurringSeries(rows);
  assert.strictEqual(series.length, 1);
  assert.strictEqual(
    series[0].displayName,
    'Netflix',
    'the known-brand catalog names the series canonically'
  );
});

test('cadences outside the subscription range are rejected', () => {
  // Daily-ish charges (a commute) and multi-year gaps are not subscriptions.
  const daily = [
    txn('Metro', 60, '2026-05-01'),
    txn('Metro', 60, '2026-05-02'),
    txn('Metro', 60, '2026-05-03'),
    txn('Metro', 60, '2026-05-04'),
  ];
  assert.strictEqual(detectRecurringSeries(daily).length, 0);

  const rare = [
    txn('Passport Seva', 1500, '2020-05-01'),
    txn('Passport Seva', 1500, '2023-05-01'),
    txn('Passport Seva', 1500, '2026-05-01'),
  ];
  assert.strictEqual(detectRecurringSeries(rare).length, 0);
});

test('an annual subscription is detected', () => {
  const rows = [
    txn('Amazon Prime', 1499, '2024-02-10'),
    txn('Amazon Prime', 1499, '2025-02-11'),
    txn('Amazon Prime', 1499, '2026-02-09'),
  ];
  const series = detectRecurringSeries(rows);
  assert.strictEqual(series.length, 1);
  assert.ok(series[0].cadenceDays > 360 && series[0].cadenceDays < 370);
});

test('series are ordered by what they cost per year', () => {
  // The order someone reviewing their subscriptions wants: biggest first.
  const rows = [
    ...monthly('Cheap', 99, '2026-01-01', 4),
    ...monthly('Pricey', 999, '2026-01-01', 4),
  ];
  const series = detectRecurringSeries(rows);
  assert.strictEqual(series[0].displayName, 'Pricey');
});

test('annual cost follows calendar cycles, not 365/day blocks', () => {
  // A ₹1,850 sub billed on the 1st of every month costs ₹22,200/year —
  // twelve payments — not 1,850 × 365/30 = 22,508.33 with an imaginary
  // 12th-and-a-bit payment. The buckets mirror cadenceLabel.
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 1850, cadenceDays: 30 })), 22200);
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 649, cadenceDays: 30 })), 7788);
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 999, cadenceDays: 91 })), 3996, 'quarterly ×4');
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 119, cadenceDays: 15 })), 3094, 'fortnightly ×26');
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 499, cadenceDays: 7 })), 25948, 'weekly ×52');
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 1499, cadenceDays: 365 })), 1499);
  // A 40-day cycle is not a calendar month: fall back to 365/days.
  assert.strictEqual(
    annualCost({ typicalAmountInr: 100, cadenceDays: 40 }),
    (100 * 365) / 40,
  );
});

test('engine status: confirmed while billing, needs_cadence on guesses', () => {
  const { engineStatus } = require('../src/recurring');
  const now = new Date('2026-10-21T12:00:00Z');
  assert.strictEqual(
    engineStatus({
      cadence_days: 30,
      cadence_confirmed: true,
      detection_source: 'observed',
      occurrence_count: 3,
      first_seen_on: '2026-07-01',
      last_seen_on: '2026-10-01',
    }, now),
    'confirmed',
  );
  assert.strictEqual(
    engineStatus({ cadence_days: 30, cadence_confirmed: false, detection_source: 'mandate', occurrence_count: 1 }, now),
    'needs_cadence',
  );
});

test('engine status: unused mandates and at-risk series', () => {
  const { engineStatus } = require('../src/recurring');
  const now = new Date('2026-10-21T12:00:00Z');
  // Mandate registered in March, never billed: past 1.5 cycles.
  assert.strictEqual(
    engineStatus({
      cadence_days: 30,
      cadence_confirmed: true,
      detection_source: 'mandate',
      occurrence_count: 1,
      first_seen_on: '2026-03-01',
      last_seen_on: '2026-03-01',
    }, now),
    'unused',
  );
  // It used to bill; the charges stopped.
  assert.strictEqual(
    engineStatus({
      cadence_days: 30,
      cadence_confirmed: true,
      detection_source: 'observed',
      occurrence_count: 4,
      first_seen_on: '2025-06-01',
      last_seen_on: '2026-06-01',
    }, now),
    'at_risk',
  );
  // A user-entered date that already passed is the user's own lapsed claim.
  assert.strictEqual(
    engineStatus({
      cadence_days: 30,
      cadence_confirmed: true,
      detection_source: 'manual',
      occurrence_count: 0,
      first_seen_on: null,
      last_seen_on: null,
      next_expected_on: '2026-08-01',
    }, now),
    'at_risk',
  );
});

test('broker brands are allowed as subscriptions; transfer wording is not', () => {
  // Broker AMC/SIP-style recurring debits are spend the user asked to see
  // ('zerodha should show'); generic transfer labels still never group.
  const zamc = detectRecurringSeries(monthly('Zerodha', 75, '2026-05-01', 3));
  assert.equal(zamc.length, 1);
  const rows = [
    txn('Bank transfer', 5000, '2026-05-01'),
    txn('Bank transfer', 5000, '2026-05-31'),
    txn('Bank transfer', 5000, '2026-06-30'),
  ];
  assert.equal(detectRecurringSeries(rows).length, 0);
});

test('known brands are admitted on two charges and get the canonical name', () => {
  const rows = [
    txn('OPENAILLC', 1999, '2026-08-01'),
    txn('OpenAILLC', 1999, '2026-08-31'),
  ];
  const series = detectRecurringSeries(rows);
  assert.strictEqual(series.length, 1, 'two brand-matched charges qualify');
  assert.strictEqual(series[0].displayName, 'OpenAI', 'display name comes from the catalog');
});

test('unknown merchants still need three charges', () => {
  assert.strictEqual(detectRecurringSeries(monthly('Blue Tokai', 350, '2026-05-03', 2)).length, 0);
});

test('account-movement wording never becomes a recurring subscription', () => {
  const rows = [
    txn('Bank transfer', 5000, '2026-05-01'),
    txn('Bank transfer', 5000, '2026-05-31'),
    txn('Bank transfer', 5000, '2026-06-30'),
    txn('Transfer to SIP account', 3000, '2026-04-01'),
    txn('Transfer to SIP account', 3000, '2026-05-01'),
    txn('Transfer to SIP account', 3000, '2026-06-01'),
  ];
  assert.equal(detectRecurringSeries(rows).length, 0);
});

test('non-spend transaction kinds are rejected defensively by the detector', () => {
  const rows = monthly('Netflix', 649, '2026-05-03', 3).map((row) => ({
    ...row,
    entry_kind: 'investment',
  }));
  assert.equal(detectRecurringSeries(rows).length, 0);
});

test('a driver-parsed date column still projects a valid next charge', () => {
  // Postgres `date` columns (OID 1082) come back from the driver as JS
  // Dates. Appending a time suffix to one produced an invalid date, and the
  // route's toISOString() on it threw "Invalid time value" — the whole
  // subscriptions screen returned 500 for any profile with a series.
  const driverDate = new Date(2026, 9, 21); // local midnight, as pg parses it
  const next = nextExpectedAfter(driverDate, 30, new Date('2026-10-21T00:00:00Z'));
  assert.ok(next instanceof Date);
  assert.equal(Number.isNaN(next.getTime()), false);
  // A monthly cycle keeps the billing day instead of drifting by 30 days.
  assert.equal(next.toISOString().slice(0, 10), '2026-11-21');
});

test('a plain calendar day keeps the day it names', () => {
  const next = nextExpectedAfter('2026-10-21', 30, new Date('2026-10-21T00:00:00Z'));
  assert.equal(next.toISOString().slice(0, 10), '2026-11-21');
});

test('an unusable anchor yields no date instead of an invalid one', () => {
  assert.equal(nextExpectedAfter('not-a-date', 30, new Date()), null);
  assert.equal(nextExpectedAfter(null, 30, new Date()), null);
  assert.equal(nextExpectedAfter(undefined, 30, new Date()), null);
});

test('a lapsed saved renewal date is still flagged from a driver-parsed date', () => {
  const { engineStatus } = require('../src/recurring');
  const status = engineStatus(
    {
      cadence_days: 30,
      cadence_confirmed: true,
      detection_source: 'manual',
      occurrence_count: 3,
      next_expected_on: new Date(2026, 8, 1),
    },
    new Date('2026-10-21T00:00:00Z'),
  );
  assert.equal(status, 'at_risk');
});

test('historical detection is explicitly posted-payment evidence', () => {
  const series = detectRecurringSeries(monthly('Netflix', 649, '2026-05-03', 3));
  assert.equal(series[0].detectionSource, 'observed');
  assert.equal(series[0].evidenceSource, 'historical_posted_payment');
  assert.equal(series[0].subscriptionEvidence, 'posted_payment_pattern');
  assert.equal(series[0].lastPostedPaymentAmountInr, 649);
});

test('mandate limit stays an authorisation and never becomes paid subscription evidence', () => {
  const mandate = {
    detection_source: 'mandate',
    display_name: 'OpenAI',
    typical_amount_inr: 1999,
    cadence_days: 30,
    occurrence_count: 1,
    first_seen_on: '2026-10-01',
    last_seen_on: '2026-10-01',
    autopay_status: 'active',
  };
  assert.equal(isDisplayableSubscriptionRecord(mandate), false);
  assert.deepEqual(classifySubscriptionEvidence(mandate, { now: new Date('2026-10-21T00:00:00Z') }), {
    target: 'mandate_authorization',
    isServiceSubscription: false,
    isMandateAuthorization: true,
    detectionSource: 'mandate',
    status: 'mandate_only',
    lifecycleStatus: 'active',
    renewalMode: 'unknown',
    reason: 'mandate_authorization_without_service_evidence',
  });
  const projection = deriveSubscriptionProjection(mandate, { now: new Date('2026-10-21T00:00:00Z') });
  assert.equal(projection.authorizationLimitInr, 1999);
  assert.equal(projection.typicalAmountInr, null);
  assert.equal(projection.lastPostedPayment, null);
});

test('explicit free one-time service supports an access end without inventing renewal', () => {
  const row = {
    detection_source: 'manual',
    display_name: 'ChatGPT trial',
    typical_amount_inr: 0,
    renewal_mode: 'one_time',
    explicit_subscription_evidence: true,
    access_end_on: '2026-11-01',
  };
  assert.equal(deriveSubscriptionStatus(row, { now: new Date('2026-10-21T00:00:00Z') }), 'active');
  assert.equal(deriveSubscriptionStatus(row, { now: new Date('2026-11-02T00:00:00Z') }), 'ended');
  const projection = deriveSubscriptionProjection(row, { now: new Date('2026-10-21T00:00:00Z') });
  assert.equal(projection.renewalMode, 'one_time');
  assert.equal(projection.typicalAmountInr, 0);
  assert.equal(projection.estimatedNextPayment, null);
});

test('a missed expected historical renewal is unverified after the grace window', () => {
  const row = {
    detection_source: 'observed',
    display_name: 'Example Service',
    typical_amount_inr: 499,
    cadence_days: 30,
    occurrence_count: 3,
    last_seen_on: '2026-08-01',
  };
  assert.equal(
    deriveSubscriptionStatus(row, { now: new Date('2026-09-15T00:00:00Z') }),
    'renewal_unverified',
  );
  assert.equal(
    deriveSubscriptionStatus({ ...row, lifecycle_status: 'cancelled' }, { now: new Date('2026-09-15T00:00:00Z') }),
    'cancelled',
  );
});

test('manual renewal without a known term remains unknown', () => {
  const row = {
    detection_source: 'manual',
    display_name: 'Local Gym',
    typical_amount_inr: 1200,
    renewal_mode: 'manual',
    occurrence_count: 0,
  };
  const projection = deriveSubscriptionProjection(row);
  assert.equal(projection.target, 'subscription_service');
  assert.equal(projection.status, 'unknown');
  assert.equal(projection.billingCadenceDays, null);
  assert.equal(projection.estimatedNextPayment, null);
});
