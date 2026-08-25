const { normalizeMerchant } = require('./reward_math');

/**
 * Subscription detection: finding the charges that repeat, from the user's
 * own history.
 *
 * Detected rather than declared. Asking people to list their subscriptions
 * is asking them to remember the ones they've forgotten — which are exactly
 * the ones worth surfacing. Everything needed was already in
 * `transactions`; nothing was reading it.
 *
 * The detector is deliberately conservative. A false positive here is worse
 * than a miss: telling someone a one-off purchase will recur next month,
 * and predicting a date for it, makes every other number on the screen
 * suspect. So it requires a real pattern — same merchant, similar amount,
 * a consistent gap, and enough repeats that coincidence is implausible —
 * and stays silent otherwise.
 */

/** Minimum occurrences before a pattern counts as recurring. */
const MIN_OCCURRENCES = 3;

/** How much the amount may vary and still be "the same" charge, ±10%. */
const AMOUNT_TOLERANCE = 0.1;

/**
 * How much the gaps between charges may vary, as a fraction of the median.
 *
 * Real billing is not metronomic: a monthly subscription lands on the 3rd,
 * then the 5th because the 3rd was a Sunday, then the 2nd. A 25% band
 * absorbs that while still rejecting a merchant someone happens to visit
 * at irregular intervals.
 */
const CADENCE_TOLERANCE = 0.25;

/** Shortest and longest cadence treated as a subscription, in days. */
const MIN_CADENCE_DAYS = 6;
const MAX_CADENCE_DAYS = 400;

/**
 * The key two charges must share to be considered the same subscription.
 *
 * Deliberately NOT `normalizeMerchant` on its own. That function strips to
 * letters and digits, which is right for duplicate detection and reward
 * matching but leaves 'NETFLIX.COM', 'Netflix' and 'netflix*subscription'
 * as three different merchants — so one subscription would be reported as
 * three, each with too few occurrences to be detected at all.
 *
 * Indian bank descriptors put the brand first and a detail after a
 * separator: 'NETFLIX.COM', 'SWIGGY*ORDER', 'AMAZON#12345', 'HOTSTAR 0725'.
 * Taking the leading segment before the first `*`, `.`, `#`, `/` or digit
 * run recovers the brand.
 *
 * SPACES ARE NOT SEPARATORS. Splitting on them would turn 'Blue Tokai' into
 * 'blue' and merge it with every other merchant starting with that word.
 * Multi-word brands ('Amazon Prime', 'Tata Play', 'Blue Tokai') are common
 * enough that the space rule would cause more wrong merges than the
 * separator rule fixes.
 */
function merchantSeriesKey(name) {
  const raw = String(name || '').trim();
  if (!raw) return '';
  // Cut at the first real separator or at a run of digits, whichever is
  // earlier. Digits in a descriptor are an order/date reference, never part
  // of the brand.
  const brand = raw.split(/[*.#/\\|]|\d{2,}/)[0];
  return normalizeMerchant(brand) || normalizeMerchant(raw);
}

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function daysBetween(a, b) {
  return Math.round((b - a) / 86400000);
}

/**
 * Groups transactions by normalized merchant and returns the groups that
 * look like a subscription.
 *
 * `rows` must be ordered oldest-first and carry
 * `{ merchant_name, amount_inr, occurred_at, category_id, user_card_id }`.
 *
 * Uses the MEDIAN gap rather than the mean, and the median amount rather
 * than the mean, because one unusual entry (an annual plan bought
 * alongside a monthly one, a refund-and-recharge) drags a mean far enough
 * to either invent a pattern or destroy a real one.
 */
function detectRecurringSeries(rows) {
  const byMerchant = new Map();
  for (const row of rows) {
    const key = merchantSeriesKey(row.merchant_name);
    // A charge with no merchant name can't be grouped with anything — two
    // unnamed ₹499 charges are not evidence of a subscription.
    if (!key) continue;
    if (!byMerchant.has(key)) byMerchant.set(key, []);
    byMerchant.get(key).push(row);
  }

  const series = [];
  for (const [key, group] of byMerchant) {
    if (group.length < MIN_OCCURRENCES) continue;

    const amounts = group.map((r) => Number(r.amount_inr));
    const typical = median(amounts);
    if (typical <= 0) continue;

    // Keep only the charges close to the typical amount. A merchant can be
    // both a subscription and an occasional purchase (Amazon Prime and
    // Amazon shopping), and mixing them produces a nonsense cadence.
    const consistent = group.filter(
      (r) => Math.abs(Number(r.amount_inr) - typical) <= typical * AMOUNT_TOLERANCE
    );
    if (consistent.length < MIN_OCCURRENCES) continue;

    const dates = consistent.map((r) => new Date(r.occurred_at)).sort((a, b) => a - b);
    const gaps = [];
    for (let i = 1; i < dates.length; i += 1) gaps.push(daysBetween(dates[i - 1], dates[i]));
    if (gaps.length === 0) continue;

    const cadence = median(gaps);
    if (cadence < MIN_CADENCE_DAYS || cadence > MAX_CADENCE_DAYS) continue;

    // Every gap has to be near the median. A merchant charged on the 1st,
    // the 3rd, and then eight months later is not a subscription, even
    // though its median gap might land in range.
    const regular = gaps.every((g) => Math.abs(g - cadence) <= Math.max(3, cadence * CADENCE_TOLERANCE));
    if (!regular) continue;

    const last = dates[dates.length - 1];
    const next = new Date(last);
    next.setDate(next.getDate() + Math.round(cadence));

    const latest = consistent[consistent.length - 1];
    series.push({
      merchantKey: key,
      // The most recent spelling, not the first: merchants rename
      // themselves and the newest string is the one the user will
      // recognise on their statement.
      displayName: latest.merchant_name,
      typicalAmountInr: typical,
      cadenceDays: Math.round(cadence),
      occurrenceCount: consistent.length,
      firstSeenOn: dates[0],
      lastSeenOn: last,
      nextExpectedOn: next,
      categoryId: latest.category_id || null,
      userCardId: latest.user_card_id || null,
    });
  }

  // Biggest annual cost first — that is the order in which someone
  // reviewing their subscriptions wants to see them.
  series.sort((a, b) => {
    const aYear = (a.typicalAmountInr * 365) / a.cadenceDays;
    const bYear = (b.typicalAmountInr * 365) / b.cadenceDays;
    return bYear - aYear;
  });
  return series;
}

/** What a series costs per year, at its detected cadence. */
function annualCost(series) {
  return (series.typicalAmountInr * 365) / series.cadenceDays;
}

module.exports = {
  detectRecurringSeries,
  merchantSeriesKey,
  annualCost,
  MIN_OCCURRENCES,
  AMOUNT_TOLERANCE,
  CADENCE_TOLERANCE,
};
