'use strict';

// Card Rewards Phase 1, WP8 — v2 windows for cap_states / milestone_states
// (plan C3.6 `period` + `anchor`, C3.7 milestone windows). The v1
// periodBounds is pinned by cycles.test.js and must not move.
const test = require('node:test');
const assert = require('node:assert/strict');
const { periodBounds, cardAnchorDate, cardIssueAnchorDate, windowBoundsV2, istDay, addDays } = require('../src/cycles');

const at = (iso) => new Date(`${iso}T10:00:00Z`);

test('cardIssueAnchorDate (C8 D22b): opened_on wins, then anniversary_on, then created_at (approximate)', () => {
  const both = { anniversaryOn: '2026-03-15', openedOn: '2025-03-15', createdAt: new Date('2026-01-01T08:00:00Z') };
  assert.deepEqual(cardIssueAnchorDate(both), { date: '2025-03-15', approximate: false, source: 'opened_on' });
  assert.deepEqual(cardAnchorDate(both), { date: '2026-03-15', approximate: false, source: 'anniversary_on' });
  assert.deepEqual(cardIssueAnchorDate({ ...both, openedOn: null }), { date: '2026-03-15', approximate: false, source: 'anniversary_on' });
  assert.deepEqual(cardIssueAnchorDate({ createdAt: new Date('2026-01-01T08:00:00Z') }), { date: '2026-01-01', approximate: true, source: 'created_at' });
});

test('created_at anchors on its India calendar day (C8 D23c)', () => {
  // 20:00 UTC on 31 Dec is 01:30 IST on 1 Jan.
  assert.equal(cardAnchorDate({ createdAt: new Date('2025-12-31T20:00:00Z') }).date, '2026-01-01');
  assert.equal(cardIssueAnchorDate({ createdAt: new Date('2025-12-31T20:00:00Z') }).date, '2026-01-01');
});

test('windowBoundsV2 uses India calendar dates for every period kind (C8 D23c)', () => {
  // 21:30 UTC on 30 Nov is 03:00 IST on 1 Dec.
  const lateNov = '2026-11-30T21:30:00Z';
  assert.equal(istDay(lateNov), '2026-12-01');
  assert.deepEqual(windowBoundsV2('calendar_month', lateNov, {}), { start: '2026-12-01', end: '2026-12-31', approximate: false });
  assert.deepEqual(windowBoundsV2('quarter', '2026-12-31T19:00:00Z', {}), { start: '2027-01-01', end: '2027-03-31', approximate: false });
  assert.deepEqual(windowBoundsV2('annual', '2026-12-31T19:00:00Z', { anchor: 'calendar_year' }), { start: '2027-01-01', end: '2027-12-31', approximate: false });
  assert.deepEqual(windowBoundsV2('annual', '2027-03-31T19:00:00Z', { anchor: 'fiscal_year' }), { start: '2027-04-01', end: '2028-03-31', approximate: false });
  assert.deepEqual(windowBoundsV2('statement_cycle', '2026-11-20T19:00:00Z', { statementDay: 20 }), { start: '2026-11-21', end: '2026-12-20', approximate: false });
  assert.deepEqual(
    windowBoundsV2('annual', '2026-03-14T19:00:00Z', { anchor: 'card_anniversary', anchorDate: '2025-03-15' }),
    { start: '2026-03-15', end: '2027-03-14', approximate: false },
  );
  const welcome = { anchorDate: '2026-10-01', windowDays: 90 };
  assert.equal(windowBoundsV2('lifetime', '2026-12-29T20:00:00Z', welcome), null); // 30 Dec IST
  assert.equal(windowBoundsV2('lifetime', '2026-09-30T19:00:00Z', welcome).start, '2026-10-01'); // 1 Oct IST
  // v1 is unchanged: still the UTC day.
  assert.deepEqual(periodBounds('calendar_month', new Date(lateNov)), { start: '2026-11-01', end: '2026-11-30' });
});

/** Statement-cycle window for an IST calendar day. */
const cycle = (day, statementDay) => {
  const w = windowBoundsV2('statement_cycle', `${day}T06:30:00Z`, { statementDay });
  return [w.start, w.end];
};

test('statement cycles (C8 D23b): the day after the previous statement date to the statement date', () => {
  assert.deepEqual(cycle('2026-02-15', 15), ['2026-01-16', '2026-02-15']);
  assert.deepEqual(cycle('2026-02-16', 15), ['2026-02-16', '2026-03-15']);
  assert.deepEqual(cycle('2026-02-15', 28), ['2026-01-29', '2026-02-28']);
  assert.deepEqual(cycle('2026-03-01', 28), ['2026-03-01', '2026-03-28']);
});

test('statement cycles: days beyond the month clamp to its last day (Feb, leap Feb)', () => {
  // 2026: 28 days in February.
  for (const sd of [29, 30, 31]) {
    assert.deepEqual(cycle('2026-02-28', sd)[1], '2026-02-28', `day ${sd}`);
    assert.deepEqual(cycle('2026-03-01', sd)[0], '2026-03-01', `day ${sd}`);
  }
  assert.deepEqual(cycle('2026-02-15', 29), ['2026-01-30', '2026-02-28']);
  assert.deepEqual(cycle('2026-02-15', 30), ['2026-01-31', '2026-02-28']);
  assert.deepEqual(cycle('2026-02-15', 31), ['2026-02-01', '2026-02-28']);
  assert.deepEqual(cycle('2026-03-01', 30), ['2026-03-01', '2026-03-30']);
  assert.deepEqual(cycle('2026-03-31', 31), ['2026-03-01', '2026-03-31']);
  // 2028: leap February.
  assert.deepEqual(cycle('2028-02-29', 31), ['2028-02-01', '2028-02-29']);
  assert.deepEqual(cycle('2028-02-29', 30), ['2028-01-31', '2028-02-29']);
  assert.deepEqual(cycle('2028-02-29', 29), ['2028-01-30', '2028-02-29']);
  assert.deepEqual(cycle('2028-02-29', 28), ['2028-02-29', '2028-03-28']);
  assert.deepEqual(cycle('2028-03-01', 29), ['2028-03-01', '2028-03-29']);
});

test('statement cycles: statement day 1 and the year boundary', () => {
  assert.deepEqual(cycle('2026-02-01', 1), ['2026-01-02', '2026-02-01']);
  assert.deepEqual(cycle('2026-02-02', 1), ['2026-02-02', '2026-03-01']);
  assert.deepEqual(cycle('2028-03-01', 1), ['2028-02-02', '2028-03-01']);
  assert.deepEqual(cycle('2026-12-31', 1), ['2026-12-02', '2027-01-01']);
  assert.deepEqual(cycle('2027-01-01', 1), ['2026-12-02', '2027-01-01']);
  assert.deepEqual(cycle('2026-12-31', 31), ['2026-12-01', '2026-12-31']);
  assert.deepEqual(cycle('2027-01-01', 31), ['2027-01-01', '2027-01-31']);
  assert.deepEqual(cycle('2027-01-10', 15), ['2026-12-16', '2027-01-15']);
});

test('statement cycles tile the calendar: no gaps, no overlaps, for every statement day', () => {
  for (let sd = 1; sd <= 31; sd += 1) {
    let day = '2026-12-01';
    let previous = null;
    while (day <= '2029-01-31') {
      const [start, end] = cycle(day, sd);
      assert.ok(start <= day && day <= end, `day ${sd}: ${day} outside ${start}..${end}`);
      if (previous && previous[1] !== end) {
        assert.equal(start, addDays(previous[1], 1), `day ${sd}: gap or overlap after ${previous[1]}`);
      }
      previous = [start, end];
      day = addDays(day, 1);
    }
  }
});

test('cardAnchorDate: anniversary_on wins, then opened_on, then created_at (approximate)', () => {
  assert.deepEqual(
    cardAnchorDate({ anniversaryOn: '2025-03-15', openedOn: '2024-01-10', createdAt: new Date('2026-01-01T08:00:00Z') }),
    { date: '2025-03-15', approximate: false, source: 'anniversary_on' },
  );
  assert.deepEqual(
    cardAnchorDate({ anniversaryOn: null, openedOn: '2024-01-10', createdAt: new Date('2026-01-01T08:00:00Z') }),
    { date: '2024-01-10', approximate: false, source: 'opened_on' },
  );
  assert.deepEqual(
    cardAnchorDate({ anniversaryOn: null, openedOn: null, createdAt: new Date('2026-01-01T08:00:00Z') }),
    { date: '2026-01-01', approximate: true, source: 'created_at' },
  );
  assert.deepEqual(cardAnchorDate({}), { date: null, approximate: true, source: null });
});

test('cardAnchorDate: pg Date values (local midnight) keep their calendar day', () => {
  // node-pg parses a `date` column to local midnight; the calendar day is what counts.
  const local = new Date(2025, 2, 15);
  assert.equal(cardAnchorDate({ anniversaryOn: local }).date, '2025-03-15');
});

test('windowBoundsV2: calendar periods match v1 and are exact', () => {
  for (const period of ['calendar_month', 'quarter', 'half_year', 'lifetime']) {
    const v1 = periodBounds(period, at('2026-11-05'), {});
    assert.deepEqual(windowBoundsV2(period, at('2026-11-05'), {}), { ...v1, approximate: false });
  }
});

test('windowBoundsV2: annual + card_anniversary uses the anchor date; created_at is approximate', () => {
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-11-05'), { anchor: 'card_anniversary', anchorDate: '2025-03-15' }),
    { start: '2026-03-15', end: '2027-03-14', approximate: false },
  );
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-02-01'), { anchor: 'card_anniversary', anchorDate: '2025-03-15', anchorApproximate: true }),
    { start: '2025-03-15', end: '2026-03-14', approximate: true },
  );
});

test('windowBoundsV2: annual + card_anniversary with no anchor date falls back to the calendar year, approximate', () => {
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-11-05'), { anchor: 'card_anniversary', anchorDate: null }),
    { start: '2026-01-01', end: '2026-12-31', approximate: true },
  );
});

test('windowBoundsV2: calendar_year and fiscal_year anchors are calendar-based and exact', () => {
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-11-05'), { anchor: 'calendar_year', anchorDate: '2025-03-15', anchorApproximate: true }),
    { start: '2026-01-01', end: '2026-12-31', approximate: false },
  );
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-02-05'), { anchor: 'fiscal_year', anchorDate: '2025-03-15' }),
    { start: '2025-04-01', end: '2026-03-31', approximate: false },
  );
});

test('windowBoundsV2: an unknown anchor is read as null (C8 D12c), never dropped', () => {
  assert.deepEqual(
    windowBoundsV2('annual', at('2026-11-05'), { anchor: 'moon_phase', anchorDate: '2025-03-15' }),
    { start: '2026-01-01', end: '2026-12-31', approximate: false },
  );
});

test('windowBoundsV2: a statement cycle without a statement day is the calendar month, approximate', () => {
  assert.deepEqual(
    windowBoundsV2('statement_cycle', at('2026-11-05'), { statementDay: 20 }),
    { start: '2026-10-21', end: '2026-11-20', approximate: false },
  );
  assert.deepEqual(
    windowBoundsV2('statement_cycle', at('2026-11-05'), {}),
    { start: '2026-11-01', end: '2026-11-30', approximate: true },
  );
});

test('windowBoundsV2: window_days counts from the anchor date and closes after it', () => {
  const opts = { anchor: 'card_anniversary', anchorDate: '2026-10-01', windowDays: 90 };
  assert.deepEqual(windowBoundsV2('lifetime', at('2026-10-01'), opts), {
    start: '2026-10-01', end: '2026-12-29', approximate: false,
  });
  assert.deepEqual(windowBoundsV2('lifetime', at('2026-12-29'), opts), {
    start: '2026-10-01', end: '2026-12-29', approximate: false,
  });
  assert.equal(windowBoundsV2('lifetime', at('2026-12-30'), opts), null);
  assert.equal(windowBoundsV2('lifetime', at('2026-09-30'), opts), null);
});

test('windowBoundsV2: a window with no anchor date never qualifies anything', () => {
  assert.equal(windowBoundsV2('lifetime', at('2026-10-05'), { windowDays: 90, anchorDate: null }), null);
});

test('windowBoundsV2: a window on an approximate anchor is approximate', () => {
  assert.deepEqual(
    windowBoundsV2('lifetime', at('2026-10-05'), { anchorDate: '2026-10-01', anchorApproximate: true, windowDays: 30 }),
    { start: '2026-10-01', end: '2026-10-30', approximate: true },
  );
});

test('windowBoundsV2: accepts ISO strings as well as Dates', () => {
  assert.deepEqual(windowBoundsV2('calendar_month', '2026-11-05T10:00:00Z', {}), {
    start: '2026-11-01', end: '2026-11-30', approximate: false,
  });
});
