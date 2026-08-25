const test = require('node:test');
const assert = require('node:assert');
const { detectRecurringSeries, annualCost } = require('../src/recurring');

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
});

test('two charges are not enough', () => {
  // Two of anything is a coincidence waiting to be disproved.
  assert.strictEqual(detectRecurringSeries(monthly('Netflix', 649, '2026-05-03', 2)).length, 0);
});

test('the next charge is predicted one cadence after the last', () => {
  const series = detectRecurringSeries(monthly('Spotify', 119, '2026-06-01', 4));
  const last = new Date(series[0].lastSeenOn);
  const next = new Date(series[0].nextExpectedOn);
  assert.strictEqual(Math.round((next - last) / 86400000), 30);
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
    'netflix*subscription',
    'the most recent spelling is what appears on the latest statement'
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

test('annual cost converts any cadence to a yearly figure', () => {
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 649, cadenceDays: 30 })), 7896);
  assert.strictEqual(Math.round(annualCost({ typicalAmountInr: 1499, cadenceDays: 365 })), 1499);
});
