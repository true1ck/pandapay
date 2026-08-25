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

/**
 * Inclusive start / EXCLUSIVE end for the period containing [anchor].
 *
 * Weeks start Monday: that is how Indian bank statements, salary cycles and
 * most people's mental "this week" line up, and an ISO week is the least
 * surprising choice when the alternative is picking a day arbitrarily.
 */
function periodBounds(period, anchor = new Date()) {
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
function previousPeriodBounds(period, anchor = new Date()) {
  const current = periodBounds(period, anchor);
  // One day before the current period starts is always inside the previous
  // one, for every period length — safer than subtracting a fixed offset,
  // which breaks on month and quarter boundaries of unequal length.
  return periodBounds(period, addDays(current.start, -1));
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
    categorySlug: r.category_slug,
    // Null category is real and common (an import we couldn't classify) —
    // labelled rather than dropped, so the totals always reconcile.
    categoryName: r.category_name || 'Uncategorized',
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
      GROUP BY t.user_card_id, cp.name, uc.nickname, cp.annual_fee_inr
      ORDER BY total DESC`,
    [userId, start, end]
  );
  return result.rows.map((r) => {
    const totalInr = Number(r.total);
    const rewardsInr = Number(r.rewards);
    return {
      cardId: r.user_card_id,
      cardName: r.card_nickname || r.card_name || 'Cash & other',
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
async function spendSeries(client, userId, period, buckets, anchor = new Date()) {
  // `date_trunc` and `interval` do NOT share a vocabulary, and conflating
  // them is a runtime error rather than a compile-time one:
  // `date_trunc('quarter', ...)` is valid, `'1 quarter'::interval` is not —
  // Postgres has no quarter interval unit. Using one string for both made
  // every quarter request a 500. They are separate values now.
  const truncUnit = period === 'quarter' ? 'quarter' : period === 'year' ? 'year' : period === 'week' ? 'week' : 'month';
  const stepInterval = {
    week: '1 week',
    month: '1 month',
    quarter: '3 months',
    year: '1 year',
  }[period];
  const { start, end } = periodBounds(period, anchor);

  const result = await client.query(
    `WITH bounds AS (
       SELECT date_trunc($2, $5::timestamptz) - (($4::int - 1) * $6::interval) AS series_start,
              $3::timestamptz AS series_end
     ),
     buckets AS (
       SELECT generate_series(
         (SELECT series_start FROM bounds),
         (SELECT series_end FROM bounds) - interval '1 microsecond',
         $6::interval
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
        AND t.occurred_at < b.bucket_start + $6::interval
      GROUP BY b.bucket_start
      ORDER BY b.bucket_start`,
    [userId, truncUnit, end, buckets, start, stepInterval]
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
  spendSeries,
  budgetSpend,
  budgetPeriodBounds,
  periodElapsedFraction,
};
