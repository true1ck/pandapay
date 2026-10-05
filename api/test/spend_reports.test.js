const test = require('node:test');
const assert = require('node:assert');
const {
  periodBounds,
  previousPeriodBounds,
  budgetPeriodBounds,
  periodElapsedFraction,
  spendByCategory,
  spendByCard,
  spendByInstrument,
} = require('../src/spend_reports');

/**
 * Period boundary maths, which every spend figure and every budget
 * percentage in the app is computed against. An off-by-one here doesn't
 * throw — it quietly moves money between periods and makes a budget read as
 * over or under when it isn't.
 *
 * The pure functions are covered here; the SQL aggregations are exercised
 * against a live database rather than mocked, since mocking a query planner
 * proves nothing about whether the query is right.
 */
function iso(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

test('month bounds are the calendar month, end-exclusive', () => {
  const { start, end } = periodBounds('month', new Date(2026, 7, 25));
  assert.strictEqual(iso(start), '2026-08-01');
  assert.strictEqual(iso(end), '2026-09-01');
});

test('week bounds start on Monday', () => {
  // 25 Aug 2026 is a Tuesday.
  const { start, end } = periodBounds('week', new Date(2026, 7, 25));
  assert.strictEqual(iso(start), '2026-08-24', 'Monday');
  assert.strictEqual(iso(end), '2026-08-31');
});

test('a Sunday belongs to the week that started the previous Monday', () => {
  // getDay() is 0 for Sunday, so a naive shift puts Sunday in the wrong
  // week — the single most likely bug in this function.
  const { start } = periodBounds('week', new Date(2026, 7, 30)); // Sunday
  assert.strictEqual(iso(start), '2026-08-24');
});

test('quarter bounds cover the right three months', () => {
  assert.strictEqual(iso(periodBounds('quarter', new Date(2026, 0, 15)).start), '2026-01-01');
  assert.strictEqual(iso(periodBounds('quarter', new Date(2026, 2, 31)).end), '2026-04-01');
  assert.strictEqual(iso(periodBounds('quarter', new Date(2026, 7, 25)).start), '2026-07-01');
  assert.strictEqual(iso(periodBounds('quarter', new Date(2026, 11, 31)).end), '2027-01-01');
});

test('year bounds are the calendar year', () => {
  const { start, end } = periodBounds('year', new Date(2026, 7, 25));
  assert.strictEqual(iso(start), '2026-01-01');
  assert.strictEqual(iso(end), '2027-01-01');
});

test('timezone-aware month bounds use the device calendar, not UTC', () => {
  // 00:00 on 2 Oct in India is 18:30 on 1 Oct UTC. A UTC truncation would
  // incorrectly place this instant in September for the user's calendar.
  const anchor = new Date('2026-10-01T18:30:00.000Z');
  const bounds = periodBounds('month', anchor, { timeZone: 'Asia/Kolkata' });
  assert.strictEqual(bounds.start.toISOString(), '2026-09-30T18:30:00.000Z');
  assert.strictEqual(bounds.end.toISOString(), '2026-10-31T18:30:00.000Z');
  assert.strictEqual(
    previousPeriodBounds('month', anchor, { timeZone: 'Asia/Kolkata' }).end.toISOString(),
    bounds.start.toISOString(),
  );
});

test('timezone-aware week bounds start on Monday in India', () => {
  // Friday 2 Oct 2026, 00:15 IST.
  const bounds = periodBounds('week', new Date('2026-10-01T18:45:00.000Z'), { timeZone: 'Asia/Kolkata' });
  assert.strictEqual(bounds.start.toISOString(), '2026-09-27T18:30:00.000Z');
  assert.strictEqual(bounds.end.toISOString(), '2026-10-04T18:30:00.000Z');
});

test('the previous period is the one immediately before, across unequal lengths', () => {
  // The failure mode being guarded: subtracting a fixed offset lands in the
  // wrong month when the months differ in length (March 31 -> Feb 28/29).
  assert.strictEqual(iso(previousPeriodBounds('month', new Date(2026, 2, 31)).start), '2026-02-01');
  assert.strictEqual(iso(previousPeriodBounds('month', new Date(2026, 0, 15)).start), '2025-12-01');
  assert.strictEqual(iso(previousPeriodBounds('quarter', new Date(2026, 0, 15)).start), '2025-10-01');
  assert.strictEqual(iso(previousPeriodBounds('year', new Date(2026, 0, 1)).start), '2025-01-01');
});

test('the previous period abuts the current one exactly, with no gap or overlap', () => {
  for (const period of ['week', 'month', 'quarter', 'year']) {
    const now = new Date(2026, 7, 25);
    assert.strictEqual(
      previousPeriodBounds(period, now).end.getTime(),
      periodBounds(period, now).start.getTime(),
      `${period}: a gap here loses spend, an overlap double-counts it`
    );
  }
});

test('a weekly budget runs from its own anchor day, not from Monday', () => {
  // A user whose week starts Thursday gets a Thursday-to-Wednesday week.
  const budget = { period: 'weekly', starts_on: '2026-08-06' }; // a Thursday
  const bounds = budgetPeriodBounds(budget, new Date(2026, 7, 25)); // Tuesday
  assert.strictEqual(iso(bounds.start), '2026-08-20', 'the most recent Thursday');
  assert.strictEqual(iso(bounds.end), '2026-08-27');
});

test('a weekly budget checked on its own anchor day starts that day', () => {
  const budget = { period: 'weekly', starts_on: '2026-08-06' };
  assert.strictEqual(iso(budgetPeriodBounds(budget, new Date(2026, 7, 6)).start), '2026-08-06');
});

test('monthly/quarterly/yearly budgets use calendar periods', () => {
  const now = new Date(2026, 7, 25);
  assert.strictEqual(iso(budgetPeriodBounds({ period: 'monthly', starts_on: '2026-01-01' }, now).start), '2026-08-01');
  assert.strictEqual(iso(budgetPeriodBounds({ period: 'quarterly', starts_on: '2026-01-01' }, now).start), '2026-07-01');
  assert.strictEqual(iso(budgetPeriodBounds({ period: 'yearly', starts_on: '2026-01-01' }, now).start), '2026-01-01');
});

test('elapsed fraction is what makes a budget percentage mean anything', () => {
  const bounds = { start: new Date(2026, 7, 1), end: new Date(2026, 8, 1) };
  // 60% of a budget spent is alarming on day 3 and fine on day 25; the
  // difference is entirely this number.
  const early = periodElapsedFraction(bounds, new Date(2026, 7, 3));
  const late = periodElapsedFraction(bounds, new Date(2026, 7, 25));
  assert.ok(early < 0.1, `day 3 of a 31-day month should be under 10%, got ${early}`);
  assert.ok(late > 0.7, `day 25 should be over 70%, got ${late}`);
});

test('elapsed fraction is clamped to 0..1 outside the period', () => {
  const bounds = { start: new Date(2026, 7, 1), end: new Date(2026, 8, 1) };
  assert.strictEqual(periodElapsedFraction(bounds, new Date(2026, 6, 1)), 0);
  assert.strictEqual(periodElapsedFraction(bounds, new Date(2026, 9, 1)), 1);
});

test('an unknown period throws rather than silently defaulting', () => {
  // Defaulting to "month" would produce plausible-looking wrong numbers.
  assert.throws(() => periodBounds('fortnight', new Date()), /unknown period/);
});

test('payment-method spend rows preserve instrument totals and counts', async () => {
  const client = {
    query: async (sql, params) => {
      assert.match(sql, /t\.instrument/);
      assert.deepEqual(params, ['user-1', 'start', 'end']);
      return {
        rows: [
          { instrument: 'credit_card', total: '1000.00', txn_count: '2' },
          { instrument: 'upi_bank', total: '500.00', txn_count: '1' },
        ],
      };
    },
  };

  assert.deepEqual(
    await spendByInstrument(client, 'user-1', { start: 'start', end: 'end' }),
    [
      { instrument: 'credit_card', totalInr: 1000, txnCount: 2 },
      { instrument: 'upi_bank', totalInr: 500, txnCount: 1 },
    ],
  );
});

test('legacy Uncategorized rows are presented as the explicit Other bucket', async () => {
  const client = {
    query: async (sql, params) => {
      assert.match(sql, /spend_categories/);
      assert.deepEqual(params, ['user-1', 'start', 'end']);
      return {
        rows: [
          { category_id: 'legacy', category_slug: 'uncategorized', category_name: 'Uncategorized', total: '2458.00', txn_count: '2' },
          { category_id: null, category_slug: null, category_name: null, total: '10.00', txn_count: '1' },
        ],
      };
    },
  };

  assert.deepEqual(
    await spendByCategory(client, 'user-1', { start: 'start', end: 'end' }),
    [
      { categoryId: 'legacy', categorySlug: 'uncategorized', categoryName: 'Other', totalInr: 2458, txnCount: 2 },
      { categoryId: null, categorySlug: 'other', categoryName: 'Other', totalInr: 10, txnCount: 1 },
    ],
  );
});

test('card breakdown labels unmatched UPI and card rows instead of calling everything cash', async () => {
  const client = {
    query: async (sql, params) => {
      assert.match(sql, /t\.instrument/);
      assert.deepEqual(params, ['user-1', 'start', 'end']);
      return {
        rows: [
          { user_card_id: null, instrument: 'upi_bank', card_name: null, card_nickname: null, annual_fee_inr: null, total: '500.00', rewards: '0', txn_count: '1' },
          { user_card_id: null, instrument: 'credit_card', card_name: null, card_nickname: null, annual_fee_inr: null, total: '800.00', rewards: '0', txn_count: '1' },
          { user_card_id: 'uc-1', instrument: 'credit_card', card_name: 'HDFC Millennia', card_nickname: null, annual_fee_inr: '1000', total: '1000.00', rewards: '20', txn_count: '1' },
        ],
      };
    },
  };

  assert.deepEqual(
    await spendByCard(client, 'user-1', { start: 'start', end: 'end' }),
    [
      { cardId: null, cardName: 'UPI / bank account', annualFeeInr: null, totalInr: 500, rewardsInr: 0, txnCount: 1, effectiveRatePerRupee: 0 },
      { cardId: null, cardName: 'Credit card (unmatched)', annualFeeInr: null, totalInr: 800, rewardsInr: 0, txnCount: 1, effectiveRatePerRupee: 0 },
      { cardId: 'uc-1', cardName: 'HDFC Millennia', annualFeeInr: 1000, totalInr: 1000, rewardsInr: 20, txnCount: 1, effectiveRatePerRupee: 0.02 },
    ],
  );
});
