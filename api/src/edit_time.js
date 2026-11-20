'use strict';

/**
 * When the person made an edit, as the phone reports it (its server-adjusted
 * clock), for the endpoints that change one independent thing about a
 * transaction (note, "don't count in spending", ignore / restore).
 *
 * Returns `{ time }` (a Date never later than `now`, or null when the request
 * carries none) or `{ error }`. Never later than now: a wrong phone clock must
 * not outrank every later edit. A request without a time (an older app) is
 * stamped with the server's clock by the SQL and always applies.
 */
function parseEditTime(value, now = Date.now()) {
  if (value === undefined || value === null) return { time: null };
  const parsed = typeof value === 'string' ? new Date(value) : null;
  if (!parsed || Number.isNaN(parsed.getTime())) return { error: 'editedAt is not a valid date' };
  return { time: new Date(Math.min(parsed.getTime(), now)) };
}

/** True when an edit made at `time` is older than the stored clock `stored`. */
const isStaleEdit = (time, stored) => Boolean(time && stored && time.getTime() < new Date(stored).getTime());

/**
 * SQL that records an edit on one clock column and never moves it backwards: a
 * late delivery of an older edit must not make the row look as if it was last
 * changed earlier. `param` is the placeholder holding the edit time.
 */
const stampClockSql = (column, param) =>
  `${column} = GREATEST(COALESCE(${column}, '-infinity'::timestamptz), COALESCE(${param}::timestamptz, now()))`;

/** SQL condition: the stored clock is not newer than the edit (or either side has no time). */
const notStaleSql = (column, param) =>
  `(${param}::timestamptz IS NULL OR ${column} IS NULL OR ${column} <= ${param}::timestamptz)`;

module.exports = { parseEditTime, isStaleEdit, stampClockSql, notStaleSql };
