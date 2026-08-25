const test = require('node:test');
const assert = require('node:assert');
const {
  periodBounds,
  previousPeriodBounds,
  budgetPeriodBounds,
  periodElapsedFraction,
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
