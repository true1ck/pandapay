/**
 * Period-bounds computation for cap_states/milestone_states — "which
 * period_start/period_end row does this transaction's date fall into."
 * Simplification, documented rather than hidden: cap_rules periods are
 * always calendar-anchored (calendar month/quarter/half-year/year) since
 * cap_rules carries no anchor column; milestone_rules DOES carry an
 * `anchor` column and this respects it (card_anniversary/calendar_year/
 * fiscal_year/statement_cycle). A real product might want cap periods
 * aligned to the statement cycle even for calendar-labelled caps — not
 * modeled here because the schema doesn't carry that distinction.
 */

function pad(n) {
  return String(n).padStart(2, '0');
}

function toDateOnly(d) {
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

function lastDayOfMonth(year, monthIndex0) {
  return new Date(Date.UTC(year, monthIndex0 + 1, 0)).getUTCDate();
}

function calendarMonthBounds(ref) {
  const y = ref.getUTCFullYear();
  const m = ref.getUTCMonth();
  return {
    start: toDateOnly(new Date(Date.UTC(y, m, 1))),
    end: toDateOnly(new Date(Date.UTC(y, m, lastDayOfMonth(y, m)))),
  };
}

function calendarQuarterBounds(ref) {
  const y = ref.getUTCFullYear();
  const qStartMonth = Math.floor(ref.getUTCMonth() / 3) * 3;
  return {
    start: toDateOnly(new Date(Date.UTC(y, qStartMonth, 1))),
    end: toDateOnly(new Date(Date.UTC(y, qStartMonth + 2, lastDayOfMonth(y, qStartMonth + 2)))),
  };
}

function calendarHalfYearBounds(ref) {
  const y = ref.getUTCFullYear();
  const hStartMonth = ref.getUTCMonth() < 6 ? 0 : 6;
  return {
    start: toDateOnly(new Date(Date.UTC(y, hStartMonth, 1))),
    end: toDateOnly(new Date(Date.UTC(y, hStartMonth + 5, lastDayOfMonth(y, hStartMonth + 5)))),
  };
}

function calendarYearBounds(ref) {
  const y = ref.getUTCFullYear();
  return { start: toDateOnly(new Date(Date.UTC(y, 0, 1))), end: toDateOnly(new Date(Date.UTC(y, 11, 31))) };
}

function fiscalYearBounds(ref) {
  // India fiscal year: April 1 - March 31.
  const y = ref.getUTCFullYear();
  const startYear = ref.getUTCMonth() >= 3 ? y : y - 1;
  return {
    start: toDateOnly(new Date(Date.UTC(startYear, 3, 1))),
    end: toDateOnly(new Date(Date.UTC(startYear + 1, 2, 31))),
  };
}

function anniversaryYearBounds(ref, anchorDate) {
  const anchor = new Date(anchorDate);
  const month = anchor.getUTCMonth();
  const day = anchor.getUTCDate();
  let startYear = ref.getUTCFullYear();
  const thisYearAnniversary = new Date(Date.UTC(startYear, month, day));
  if (ref < thisYearAnniversary) startYear -= 1;
  const start = new Date(Date.UTC(startYear, month, day));
  const end = new Date(Date.UTC(startYear + 1, month, day - 1));
  return { start: toDateOnly(start), end: toDateOnly(end) };
}

function statementCycleBounds(ref, statementDay) {
  if (!statementDay) return calendarMonthBounds(ref);
  const y = ref.getUTCFullYear();
  const m = ref.getUTCMonth();
  const day = ref.getUTCDate();
  let startYear = y;
  let startMonth = m;
  if (day < statementDay) {
    startMonth -= 1;
    if (startMonth < 0) {
      startMonth = 11;
      startYear -= 1;
    }
  }
  const clampedStartDay = Math.min(statementDay, lastDayOfMonth(startYear, startMonth));
  const start = new Date(Date.UTC(startYear, startMonth, clampedStartDay));
  let endMonth = startMonth + 1;
  let endYear = startYear;
  if (endMonth > 11) {
    endMonth = 0;
    endYear += 1;
  }
  const clampedEndDay = Math.min(statementDay, lastDayOfMonth(endYear, endMonth)) - 1;
  const end = new Date(Date.UTC(endYear, endMonth, Math.max(clampedEndDay, 1)));
  return { start: toDateOnly(start), end: toDateOnly(end) };
}

const LIFETIME_BOUNDS = { start: '1970-01-01', end: '9999-12-31' };

/**
 * @param period one of cap_period's enum values
 * @param occurredAt Date the transaction happened
 * @param opts { statementDay?: number, anchor?: string, anchorDate?: string }
 *   `anchor`/`anchorDate` only apply to milestone_rules (cap_rules has no
 *   anchor column, so cap periods are always calendar-anchored regardless
 *   of what's passed here).
 */
function periodBounds(period, occurredAt, opts = {}) {
  const { statementDay, anchor, anchorDate } = opts;

  if (period === 'lifetime') return LIFETIME_BOUNDS;
  if (period === 'statement_cycle') return statementCycleBounds(occurredAt, statementDay);
  if (period === 'calendar_month') return calendarMonthBounds(occurredAt);
  if (period === 'quarter') return calendarQuarterBounds(occurredAt);
  if (period === 'half_year') return calendarHalfYearBounds(occurredAt);
  if (period === 'annual') {
    if (anchor === 'card_anniversary' && anchorDate) return anniversaryYearBounds(occurredAt, anchorDate);
    if (anchor === 'fiscal_year') return fiscalYearBounds(occurredAt);
    if (anchor === 'statement_cycle') return statementCycleBounds(occurredAt, statementDay);
    return calendarYearBounds(occurredAt); // anchor === 'calendar_year' or no anchor (cap_rules)
  }
  throw new Error(`Unknown cap_period: ${period}`);
}

// ---------------------------------------------------------------------------
// Card Rewards Phase 1 (WP8) — v2 windows, plan C3.6 / C3.7.
//
// periodBounds above stays exactly as it was: v1-shaped cards keep their
// windows byte-for-byte. v2-shaped cards (reward_math_v2.isV2Card) use
// windowBoundsV2, which adds cap anchors, the C3.7 anchor-date fallback,
// welcome windows (`window_days`) and an `approximate` flag readers can show.
// ---------------------------------------------------------------------------

const KNOWN_ANCHORS = new Set(['card_anniversary', 'calendar_year', 'fiscal_year', 'statement_cycle']);
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Calendar day of a date-ish value as 'YYYY-MM-DD', or null. A 'YYYY-MM-DD'
 * string is taken as written. A Date uses its LOCAL calendar day, because
 * node-pg parses a Postgres `date` column to local midnight.
 */
function calendarDay(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'string' && DATE_ONLY.test(value.slice(0, 10)) && value.length <= 10) return value;
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/**
 * C3.7: the user card's anchor date is `anniversary_on ?? opened_on`; when
 * both are null it is the day the card was added, and anything measured from
 * it is `approximate`.
 */
function cardAnchorDate({ anniversaryOn, openedOn, createdAt } = {}) {
  const anniversary = calendarDay(anniversaryOn);
  if (anniversary) return { date: anniversary, approximate: false, source: 'anniversary_on' };
  const opened = calendarDay(openedOn);
  if (opened) return { date: opened, approximate: false, source: 'opened_on' };
  const created = calendarDay(createdAt);
  if (created) return { date: created, approximate: true, source: 'created_at' };
  return { date: null, approximate: true, source: null };
}

function addDays(dateOnly, days) {
  const d = new Date(`${dateOnly}T00:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return toDateOnly(d);
}

/**
 * The window a v2 cap or milestone counts this transaction in:
 * `{ start, end, approximate }` (dates as 'YYYY-MM-DD'), or `null` when the
 * rule has `windowDays` and the transaction falls outside that window.
 *
 * - `anchor` outside the known set is read as null (C8 D12c).
 * - `windowDays` (welcome milestones, C3.7) counts from `anchorDate`: the
 *   window is [anchorDate, anchorDate + windowDays − 1]. No anchor date →
 *   nothing qualifies (never guessed).
 * - `annual` + `card_anniversary` runs anniversary to anniversary from
 *   `anchorDate` (`approximate` follows `anchorApproximate`); with no anchor
 *   date it falls back to the calendar year, approximate.
 * - `statement_cycle` without a statement day is the calendar month, approximate.
 * - Everything else is exactly periodBounds.
 */
function windowBoundsV2(period, occurredAt, opts = {}) {
  const { statementDay, anchorDate = null, anchorApproximate = false, windowDays = null } = opts;
  const anchor = KNOWN_ANCHORS.has(opts.anchor) ? opts.anchor : null;
  const ref = occurredAt instanceof Date ? occurredAt : new Date(occurredAt);

  if (windowDays != null) {
    const days = Number(windowDays);
    if (!(days > 0) || !anchorDate) return null;
    const start = calendarDay(anchorDate);
    const end = addDays(start, Math.floor(days) - 1);
    const day = toDateOnly(ref);
    if (day < start || day > end) return null;
    return { start, end, approximate: Boolean(anchorApproximate) };
  }

  if (period === 'annual' && anchor === 'card_anniversary') {
    if (!anchorDate) return { ...calendarYearBounds(ref), approximate: true };
    return { ...anniversaryYearBounds(ref, calendarDay(anchorDate)), approximate: Boolean(anchorApproximate) };
  }

  const bounds = periodBounds(period, ref, { statementDay, anchor });
  const usesStatementCycle = period === 'statement_cycle' || (period === 'annual' && anchor === 'statement_cycle');
  return { ...bounds, approximate: usesStatementCycle && !statementDay };
}

/**
 * Mirrors packages/pandapay_domain's RewardUnit.effectiveRatePerRupee —
 * kept in sync by hand (no shared package between the Node and Dart sides
 * yet). Used to convert a spend amount into the actual reward VALUE it
 * earns, for reward_value-measure cap_states.consumed (Chunk 17 fix: this
 * used to increment consumed by the raw spend amount regardless of
 * measure, the exact class of bug Chunk 9 fixed in the ranking engine
 * itself — caught here before it shipped, not after).
 */
function effectiveRatePerRupee(unit, rate, pointValueInr) {
  switch (unit) {
    case 'cashback_percent':
    case 'discount_percent':
      return rate / 100;
    case 'points_per_100':
      return (rate * pointValueInr) / 100;
    case 'points_per_150':
      return (rate * pointValueInr) / 150;
    case 'points_per_200':
      return (rate * pointValueInr) / 200;
    case 'miles_per_100':
      return (rate * pointValueInr) / 100;
    case 'flat_points':
      return 0; // fixed bonus, not a per-rupee rate — same as the Dart engine
    default:
      return 0;
  }
}

/**
 * Points actually earned per rupee, in the reward's own native unit
 * (points/miles/cashback-rupees) — distinct from effectiveRatePerRupee's
 * INR *value*. Used for points_ledger.delta_points, which records what the
 * card issuer would show as earned, not what it's worth.
 */
function effectivePointsPerRupee(unit, rate) {
  switch (unit) {
    case 'cashback_percent':
    case 'discount_percent':
      return rate / 100;
    case 'points_per_100':
    case 'miles_per_100':
      return rate / 100;
    case 'points_per_150':
      return rate / 150;
    case 'points_per_200':
      return rate / 200;
    case 'flat_points':
      return 0; // fixed bonus, not a per-rupee rate
    default:
      return 0;
  }
}

module.exports = {
  periodBounds,
  effectiveRatePerRupee,
  effectivePointsPerRupee,
  cardAnchorDate,
  windowBoundsV2,
  calendarDay,
  addDays,
};
