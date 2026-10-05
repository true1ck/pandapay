/**
 * Spend reporting: the aggregation behind Trends, per-card reports and
 * budget progress.
 *
 * All of it reads `transactions`, which already carried everything needed —
 * GET /transactions has accepted from/to/cardId/categoryId/source filters
 * for a long time. What was missing was never the data, it was any way to
 * ask "how does this month compare to last", "what does THIS card cost me",
 * or "am I over the line I set". Spending Overview answered exactly one
 * question (this calendar month, by category) and said in its own
 * doc-comment that a budget was deliberately out of scope.
 *
 * Two rules run through every query here, and getting either wrong silently
 * corrupts every figure downstream:
 *
 *   1. `status = 'active'` — ignored, reversed and merged-duplicate rows
 *      were never real spend.
 *   2. `entry_kind = 'spend'` — income, investments and transfers between
 *      the user's own accounts are NOT spending, and adding them into a
 *      spend total is the single easiest way to make a budget meaningless.
 *      They are reported, on their own lines, by [periodTotals].
 */

const PERIODS = ['week', 'month', 'quarter', 'year'];

/** Local-midnight date, so period maths never drifts on a DST-free tz. */
function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function addDays(d, n) {
  const out = new Date(d);
  out.setDate(out.getDate() + n);
  return out;
}

// The report API receives the device's IANA timezone. Keep all calendar
// boundaries in that zone, then hand Postgres UTC instants for its half-open
// timestamp filters. This matters in India too: a transaction at 00:15 IST is
// still in the previous UTC day.
function zonedParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    calendar: 'gregory',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const values = Object.fromEntries(parts
    .filter((part) => part.type !== 'literal')
    .map((part) => [part.type, Number(part.value)]));
  return values;
}

function zonedMidnight(year, month, day, timeZone) {
  const wallClock = Date.UTC(year, month - 1, day);
  let guess = new Date(wallClock);
  // Solve UTC = local wall-clock - zone offset. Two passes are enough for
  // ordinary zones and the extra passes keep this safe across DST changes.
  for (let i = 0; i < 4; i += 1) {
    const local = zonedParts(guess, timeZone);
    const representedWallClock = Date.UTC(
      local.year,
      local.month - 1,
      local.day,
      local.hour,
      local.minute,
      local.second,
    );
    const offsetMs = representedWallClock - guess.getTime();
    const next = new Date(wallClock - offsetMs);
    if (next.getTime() === guess.getTime()) return next;
    guess = next;
  }
  return guess;
}

function shiftCalendarDate(parts, days) {
  const date = new Date(Date.UTC(parts.year, parts.month - 1, parts.day));
  date.setUTCDate(date.getUTCDate() + days);
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate() };
}

function periodBoundsInTimeZone(period, anchor, timeZone) {
  const current = zonedParts(anchor, timeZone);
  let startDate;
  let endDate;
  if (period === 'week') {
    const day = new Date(Date.UTC(current.year, current.month - 1, current.day));
    const offset = (day.getUTCDay() + 6) % 7;
    startDate = shiftCalendarDate(current, -offset);
    endDate = shiftCalendarDate(startDate, 7);
  } else if (period === 'month') {
    startDate = { year: current.year, month: current.month, day: 1 };
    endDate = current.month === 12
      ? { year: current.year + 1, month: 1, day: 1 }
      : { year: current.year, month: current.month + 1, day: 1 };
  } else if (period === 'quarter') {
    const startMonth = Math.floor((current.month - 1) / 3) * 3 + 1;
    startDate = { year: current.year, month: startMonth, day: 1 };
    const endMonth = startMonth + 3;
    endDate = endMonth > 12
      ? { year: current.year + 1, month: endMonth - 12, day: 1 }
      : { year: current.year, month: endMonth, day: 1 };
  } else if (period === 'year') {
    startDate = { year: current.year, month: 1, day: 1 };
    endDate = { year: current.year + 1, month: 1, day: 1 };
  } else {
    throw new Error(`unknown period: ${period}`);
  }
  return {
    start: zonedMidnight(startDate.year, startDate.month, startDate.day, timeZone),
    end: zonedMidnight(endDate.year, endDate.month, endDate.day, timeZone),
  };
}

/**
 * Inclusive start / EXCLUSIVE end for the period containing [anchor].
 *
 * Weeks start Monday: that is how Indian bank statements, salary cycles and
 * most people's mental "this week" line up, and an ISO week is the least
 * surprising choice when the alternative is picking a day arbitrarily.
 */
function periodBounds(period, anchor = new Date(), options = {}) {
  if (options.timeZone) return periodBoundsInTimeZone(period, anchor, options.timeZone);
  const a = startOfDay(anchor);
  switch (period) {
    case 'week': {
      // getDay(): 0 = Sunday. Shift so Monday is 0.
      const offset = (a.getDay() + 6) % 7;
      const start = addDays(a, -offset);
      return { start, end: addDays(start, 7) };
    }
    case 'month':
      return {
        start: new Date(a.getFullYear(), a.getMonth(), 1),
        end: new Date(a.getFullYear(), a.getMonth() + 1, 1),
      };
    case 'quarter': {
      const q = Math.floor(a.getMonth() / 3);
      return {
        start: new Date(a.getFullYear(), q * 3, 1),
        end: new Date(a.getFullYear(), q * 3 + 3, 1),
      };
    }
    case 'year':
      return {
        start: new Date(a.getFullYear(), 0, 1),
        end: new Date(a.getFullYear() + 1, 0, 1),
      };
    default:
      throw new Error(`unknown period: ${period}`);
  }
}

/** The period immediately before the one containing [anchor]. */
function previousPeriodBounds(period, anchor = new Date(), options = {}) {
  const current = periodBounds(period, anchor, options);
  // One day before the current period starts is always inside the previous
  // one, for every period length — safer than subtracting a fixed offset,
  // which breaks on month and quarter boundaries of unequal length.
  const previousAnchor = options.timeZone
    ? new Date(current.start.getTime() - 1)
    : addDays(current.start, -1);
  return periodBounds(period, previousAnchor, options);
}

/**
 * Headline figures for one period, plus the same figures for the period
 * before it so the UI can show a real comparison rather than a number with
 * no context.
 *
 * `spend`, `income` and `investment` are returned separately and never
 * summed together here — see this module's header.
 */
async function periodTotals(client, userId, { start, end }) {
  const result = await client.query(
    `SELECT entry_kind,
            COALESCE(SUM(amount_inr), 0) AS total,
            COUNT(*) AS txn_count,
            COALESCE(SUM(expected_value_inr), 0) AS rewards
       FROM transactions
      WHERE profile_id = $1 AND status = 'active'
        AND occurred_at >= $2 AND occurred_at < $3
      GROUP BY entry_kind`,
    [userId, start, end]
  );

  const byKind = {};
  for (const row of result.rows) {
    byKind[row.entry_kind] = {
      totalInr: Number(row.total),
      txnCount: Number(row.txn_count),
      rewardsInr: Number(row.rewards),
    };
  }
  const zero = { totalInr: 0, txnCount: 0, rewardsInr: 0 };
  return {
    spend: byKind.spend || zero,
    income: byKind.income || zero,
    investment: byKind.investment || zero,
    transfer: byKind.transfer || zero,
  };
}

/** Spend split by category, biggest first. */
async function spendByCategory(client, userId, { start, end }) {
  const result = await client.query(
    `SELECT t.category_id, sc.slug AS category_slug, sc.name AS category_name,
            COALESCE(SUM(t.amount_inr), 0) AS total, COUNT(*) AS txn_count
       FROM transactions t
       LEFT JOIN spend_categories sc ON sc.id = t.category_id
      WHERE t.profile_id = $1 AND t.status = 'active' AND t.entry_kind = 'spend'
        AND t.occurred_at >= $2 AND t.occurred_at < $3
      GROUP BY t.category_id, sc.slug, sc.name
      ORDER BY total DESC`,
    [userId, start, end]
  );
  return result.rows.map((r) => ({
    categoryId: r.category_id,
    categorySlug: r.category_slug || 'other',
    // Null category is real and common (an import we couldn't classify) —
    // labelled rather than dropped, so the totals always reconcile.
    // Older rows may point at a literal `Uncategorized` bucket. That label
    // is an implementation state, not a useful spending category; surface it
    // as the explicit catch-all while the reconciliation endpoint backfills
    // the row to the canonical `other` category.
    categoryName: ['uncategorized', 'unclassified'].includes(
      String(r.category_name || '').trim().toLowerCase(),
    ) ? 'Other' : (r.category_name || 'Other'),
    totalInr: Number(r.total),
    txnCount: Number(r.txn_count),
  }));
}

/** Spend split by merchant, biggest first. */
async function spendByMerchant(client, userId, { start, end }, limit = 15) {
  const result = await client.query(
    `SELECT COALESCE(merchant_name, 'Unknown merchant') AS merchant,
            COALESCE(SUM(amount_inr), 0) AS total, COUNT(*) AS txn_count
       FROM transactions
      WHERE profile_id = $1 AND status = 'active' AND entry_kind = 'spend'
        AND occurred_at >= $2 AND occurred_at < $3
      GROUP BY 1
      ORDER BY total DESC
      LIMIT $4`,
    [userId, start, end, limit]
  );
  return result.rows.map((r) => ({
    merchant: r.merchant,
    totalInr: Number(r.total),
    txnCount: Number(r.txn_count),
  }));
}

/**
 * Spend and rewards split by card, plus the EFFECTIVE rate each card
 * actually paid over the period.
 *
 * The effective rate is the honest number this whole feature exists to
 * produce: `rewards / spend`, not the rate the card advertises. A card with
 * a 5% headline that is capped at 3,000/month and sees 40,000 of spend has
 * an effective rate near 1%, and that is what tells the user whether the
 * annual fee is worth paying.
 *
 * Includes non-card rows under a null cardId so the per-card breakdown
 * always reconciles with the period total, rather than quietly omitting
 * cash and leaving the user to wonder where the difference went.
 */
async function spendByCard(client, userId, { start, end }) {
  const result = await client.query(
    `SELECT t.user_card_id,
            t.instrument,
            cp.name AS card_name, uc.nickname AS card_nickname,
            cp.annual_fee_inr,
            COALESCE(SUM(t.amount_inr), 0) AS total,
            COALESCE(SUM(t.expected_value_inr), 0) AS rewards,
            COUNT(*) AS txn_count
       FROM transactions t
       LEFT JOIN user_cards uc ON uc.id = t.user_card_id
       LEFT JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE t.profile_id = $1 AND t.status = 'active' AND t.entry_kind = 'spend'
        AND t.occurred_at >= $2 AND t.occurred_at < $3
      GROUP BY t.user_card_id, t.instrument, cp.name, uc.nickname, cp.annual_fee_inr
      ORDER BY total DESC`,
    [userId, start, end]
  );
  return result.rows.map((r) => {
    const totalInr = Number(r.total);
    const rewardsInr = Number(r.rewards);
    return {
      cardId: r.user_card_id,
      cardName: r.card_nickname || r.card_name || (r.instrument === 'upi_bank'
        ? 'UPI / bank account'
        : r.instrument === 'debit_card'
          ? 'Debit card (unmatched)'
          : r.instrument === 'credit_card'
            ? 'Credit card (unmatched)'
            : r.instrument === 'wallet'
              ? 'Wallet'
              : 'Cash & other'),
      annualFeeInr: r.annual_fee_inr == null ? null : Number(r.annual_fee_inr),
      totalInr,
      rewardsInr,
      txnCount: Number(r.txn_count),
      // Null rather than 0 when nothing was spent: "no data" and "earned
      // nothing on what you spent" are different statements about a card.
      effectiveRatePerRupee: totalInr > 0 ? rewardsInr / totalInr : null,
    };
  });
}

/** Spend split by the payment instrument detected on the transaction. */
async function spendByInstrument(client, userId, { start, end }) {
  const result = await client.query(
    // `instrument` is a Postgres enum. Cast it before comparing with an
    // empty string: otherwise Postgres tries to cast '' to txn_instrument
    // before NULLIF can remove it, which turns uncategorized imports into a
    // 500 for the entire Insights report.
    `SELECT COALESCE(NULLIF(t.instrument::text, ''), 'other') AS instrument,
            COALESCE(SUM(t.amount_inr), 0) AS total,
            COUNT(*) AS txn_count
       FROM transactions t
      WHERE t.profile_id = $1 AND t.status = 'active' AND t.entry_kind = 'spend'
        AND t.occurred_at >= $2 AND t.occurred_at < $3
      GROUP BY 1
      ORDER BY total DESC`,
    [userId, start, end]
  );
  return result.rows.map((r) => ({
    instrument: r.instrument,
    totalInr: Number(r.total),
    txnCount: Number(r.txn_count),
  }));
}

/**
 * A bucketed series for the trend chart — one point per week/month/quarter
 * going back [buckets] periods, oldest first.
 *
 * Buckets are produced by `generate_series` and LEFT JOINed rather than
 * derived from the transactions present, so a period with no spend appears
 * as a genuine zero instead of vanishing and making the chart lie about
 * continuity.
 *
 * ANCHORED ON THE PERIOD'S START, not its end. The end is EXCLUSIVE (1
 * September for an August month), so truncating it lands on the FOLLOWING
 * period and the window comes out one bucket short — asking for 12 months
 * returned 11. Found by running this against a real database; the unit
 * tests cover `periodBounds` but cannot exercise SQL, which is exactly
 * where the off-by-one lived.
 */
async function spendSeries(client, userId, period, buckets, anchor = new Date(), options = {}) {
  // Anchor the series on the already-correct local-calendar start. Using
  // date_trunc(start) here would truncate the UTC instant again and move an
  // India-local midnight back to the previous UTC day.
  const stepInterval = {
    week: '1 week',
    month: '1 month',
    quarter: '3 months',
    year: '1 year',
  }[period];
  const { start } = periodBounds(period, anchor, options);

  const result = await client.query(
    `WITH buckets AS (
       SELECT generate_series(
         $3::timestamptz - (($2::int - 1) * $4::interval),
         $3::timestamptz,
         $4::interval
       ) AS bucket_start
     )
     SELECT b.bucket_start,
            COALESCE(SUM(t.amount_inr) FILTER (WHERE t.entry_kind = 'spend'), 0) AS spend,
            COALESCE(SUM(t.expected_value_inr) FILTER (WHERE t.entry_kind = 'spend'), 0) AS rewards,
            COUNT(t.id) FILTER (WHERE t.entry_kind = 'spend') AS txn_count
       FROM buckets b
       LEFT JOIN transactions t
         ON t.profile_id = $1
        AND t.status = 'active'
        AND t.occurred_at >= b.bucket_start
        AND t.occurred_at < b.bucket_start + $4::interval
      GROUP BY b.bucket_start
      ORDER BY b.bucket_start`,
    [userId, buckets, start, stepInterval]
  );

  return result.rows.map((r) => ({
    periodStart: r.bucket_start,
    spendInr: Number(r.spend),
    rewardsInr: Number(r.rewards),
    txnCount: Number(r.txn_count),
  }));
}

/**
 * Actual spend against one budget's current period.
 *
 * Scope decides the filter: an overall budget counts everything, a category
 * budget counts one category, a card budget counts one card. All three are
 * spend-only, for the reason in this module's header.
 */
async function budgetSpend(client, userId, budget, { start, end }) {
  const conditions = [
    `profile_id = $1`,
    `status = 'active'`,
    `entry_kind = 'spend'`,
    `occurred_at >= $2`,
    `occurred_at < $3`,
  ];
  const params = [userId, start, end];
  if (budget.scope === 'category') {
    params.push(budget.scope_ref_id);
    conditions.push(`category_id = $${params.length}`);
  } else if (budget.scope === 'card') {
    params.push(budget.scope_ref_id);
    conditions.push(`user_card_id = $${params.length}`);
  }
  const result = await client.query(
    `SELECT COALESCE(SUM(amount_inr), 0) AS total, COUNT(*) AS txn_count
       FROM transactions WHERE ${conditions.join(' AND ')}`,
    params
  );
  return {
    spentInr: Number(result.rows[0].total),
    txnCount: Number(result.rows[0].txn_count),
  };
}

/**
 * Maps a budget's own period vocabulary onto [periodBounds], anchored on
 * `starts_on` for weekly budgets so a user whose week begins Thursday gets
 * a week that begins Thursday.
 */
function budgetPeriodBounds(budget, now = new Date()) {
  if (budget.period === 'weekly') {
    const anchor = startOfDay(new Date(budget.starts_on));
    const today = startOfDay(now);
    const daysSince = Math.floor((today - anchor) / 86400000);
    const whole = Math.floor(daysSince / 7);
    const start = addDays(anchor, whole * 7);
    return { start, end: addDays(start, 7) };
  }
  const map = { monthly: 'month', quarterly: 'quarter', yearly: 'year' };
  return periodBounds(map[budget.period], now);
}

/**
 * How far through the current period we are, 0..1.
 *
 * This is what makes "you're at 60% of your budget" actionable: 60% spent
 * on day 3 of a month is a problem, and on day 25 it is fine. A projection
 * without it is a number that alarms people for no reason.
 */
function periodElapsedFraction({ start, end }, now = new Date()) {
  const total = end - start;
  if (total <= 0) return 1;
  const done = now - start;
  if (done <= 0) return 0;
  if (done >= total) return 1;
  return done / total;
}

module.exports = {
  PERIODS,
  periodBounds,
  previousPeriodBounds,
  periodTotals,
  spendByCategory,
  spendByMerchant,
  spendByCard,
  spendByInstrument,
  spendSeries,
  budgetSpend,
  budgetPeriodBounds,
  periodElapsedFraction,
};
