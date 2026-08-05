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

module.exports = { periodBounds, effectiveRatePerRupee };
