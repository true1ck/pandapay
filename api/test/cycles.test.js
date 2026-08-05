const test = require('node:test');
const assert = require('node:assert/strict');
const { periodBounds } = require('../src/cycles');

test('calendar_month bounds the whole month regardless of day', () => {
  const bounds = periodBounds('calendar_month', new Date('2026-02-15T00:00:00Z'));
  assert.deepEqual(bounds, { start: '2026-02-01', end: '2026-02-28' });
});

test('calendar_month handles a leap year February correctly', () => {
  const bounds = periodBounds('calendar_month', new Date('2028-02-15T00:00:00Z'));
  assert.deepEqual(bounds, { start: '2028-02-01', end: '2028-02-29' });
});

test('quarter bounds Q1/Q2/Q3/Q4 correctly', () => {
  assert.deepEqual(periodBounds('quarter', new Date('2026-02-01T00:00:00Z')), {
    start: '2026-01-01',
    end: '2026-03-31',
  });
  assert.deepEqual(periodBounds('quarter', new Date('2026-11-01T00:00:00Z')), {
    start: '2026-10-01',
    end: '2026-12-31',
  });
});

test('half_year splits the calendar year in two', () => {
  assert.deepEqual(periodBounds('half_year', new Date('2026-03-01T00:00:00Z')), {
    start: '2026-01-01',
    end: '2026-06-30',
  });
  assert.deepEqual(periodBounds('half_year', new Date('2026-09-01T00:00:00Z')), {
    start: '2026-07-01',
    end: '2026-12-31',
  });
});

test('annual with no anchor defaults to the calendar year', () => {
  const bounds = periodBounds('annual', new Date('2026-06-15T00:00:00Z'));
  assert.deepEqual(bounds, { start: '2026-01-01', end: '2026-12-31' });
});

test('annual with fiscal_year anchor uses April-March', () => {
  assert.deepEqual(
    periodBounds('annual', new Date('2026-02-15T00:00:00Z'), { anchor: 'fiscal_year' }),
    { start: '2025-04-01', end: '2026-03-31' }
  );
  assert.deepEqual(
    periodBounds('annual', new Date('2026-05-15T00:00:00Z'), { anchor: 'fiscal_year' }),
    { start: '2026-04-01', end: '2027-03-31' }
  );
});

test('annual with card_anniversary anchor wraps around the anniversary date', () => {
  const opts = { anchor: 'card_anniversary', anchorDate: '2025-08-20' };
  // Before this year's anniversary -> still in last year's window.
  assert.deepEqual(periodBounds('annual', new Date('2026-08-01T00:00:00Z'), opts), {
    start: '2025-08-20',
    end: '2026-08-19',
  });
  // On/after this year's anniversary -> the new window has started.
  assert.deepEqual(periodBounds('annual', new Date('2026-08-20T00:00:00Z'), opts), {
    start: '2026-08-20',
    end: '2027-08-19',
  });
});

test('statement_cycle before the statement day belongs to last month\'s cycle', () => {
  const bounds = periodBounds('statement_cycle', new Date('2026-03-05T00:00:00Z'), { statementDay: 10 });
  assert.deepEqual(bounds, { start: '2026-02-10', end: '2026-03-09' });
});

test('statement_cycle on/after the statement day belongs to this month\'s cycle', () => {
  const bounds = periodBounds('statement_cycle', new Date('2026-03-15T00:00:00Z'), { statementDay: 10 });
  assert.deepEqual(bounds, { start: '2026-03-10', end: '2026-04-09' });
});

test('statement_cycle with no statementDay falls back to calendar_month', () => {
  const bounds = periodBounds('statement_cycle', new Date('2026-03-15T00:00:00Z'), {});
  assert.deepEqual(bounds, { start: '2026-03-01', end: '2026-03-31' });
});

test('lifetime always returns the same wide-open bounds', () => {
  assert.deepEqual(periodBounds('lifetime', new Date('2026-03-15T00:00:00Z')), {
    start: '1970-01-01',
    end: '9999-12-31',
  });
});

test('an unknown period throws rather than silently defaulting', () => {
  assert.throws(() => periodBounds('not_a_real_period', new Date()));
});
