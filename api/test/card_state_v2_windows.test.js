'use strict';

// Card Rewards Phase 1, WP8 — v2 windows for cap_states / milestone_states
// (plan C3.6 `period` + `anchor`, C3.7 milestone windows). The v1
// periodBounds is pinned by cycles.test.js and must not move.
const test = require('node:test');
const assert = require('node:assert/strict');
const { periodBounds, cardAnchorDate, windowBoundsV2 } = require('../src/cycles');

const at = (iso) => new Date(`${iso}T10:00:00Z`);

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
    { start: '2026-10-20', end: '2026-11-19', approximate: false },
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
