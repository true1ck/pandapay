const { normalizeMerchant } = require('./reward_math');
const { brandFor } = require('./brand_catalog');

// Financial-account movements must not become subscriptions just because a
// bank statement repeats them. Broker funding, SIPs, mutual-fund purchases,
// and generic transfer labels are money movements, not recurring services.
// Broker brand names alone (Zerodha, Groww, ...) are allowed through: their
// AMC/maintenance fees are genuine paid subscriptions, and a recurring
// SIP-like bank debit is spend the user may want surfaced. Investment
// WORDING is still blocked, and message-level funding checks
// (isInvestmentFundingMessage) still guard at ingestion.
const FINANCIAL_MOVEMENT_NAME = /\b(?:bank\s+transfer|transfer\s+to|transfer\s+between|cash\s+withdrawal|credit\s+card\s+bill\s+payment|investment\s+contribution|money\s+received|salary|refund|cashback|dividend|demat|trading|broker(?:age|ing)?|portfolio|mutual\s+fund|systematic\s+investment|sip|stocks?|shares?|equity|investment)\b/i;

const FINANCIAL_PROVIDER = /\b(?:zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money|indmoney|5paisa|motilal\s+oswal|icici\s+direct|hdfc\s+securities|demat|trading|broker(?:age|ing)?|portfolio)\b/i;
const INVESTMENT_INTENT = /\b(?:sip|systematic\s+investment|mutual\s+fund|investment|invested|invest(?:ment)?\s+account|add(?:ing|ed)?\s+(?:money|funds?)|funds?\s+(?:added|credited|transferred|deposited)|top[ -]?up|fund(?:ed|ing)|buy|bought|purchase(?:d)?|units?|stocks?|shares?|equity)\b/i;
const MOVEMENT_VERB = /\b(?:debit(?:ed)?|paid|sent|transferred|withdrawn|invested|purchased|bought|credited|received|deposited|add(?:ing|ed)?|funded|top[ -]?up)\b/i;
const FEE_ONLY = /\b(?:fee|fees|charge|charges|commission|brokerage\s+fee|annual\s+maintenance)\b/i;

// A broker (Dhan, Zerodha, Groww, etc.) reporting a settlement payout of
// trading balance into the user's own bank account. Money leaves the
// investment account and lands in the bank — an investment-proceeds
// movement: never earned income, never spending, never new funding. The
// phrase "add funds back to your <broker> account" is an instruction about
// the user's next step, not this transaction.
function isBrokerSettlementMessage(value) {
  const text = String(value || '');
  return /\b(?:dhan|zerodha|groww|upstox|angel\s+one|5paisa|sharekhan|motilal\s+oswal|hdfc\s+securities|icici\s+direct|kotak\s+securities|paytm\s+money|iifl)\b/i.test(text)
    && /\b(?:running\s+account\s+settlement|quarterly\s+settlement|account\s+settlement|settlement\s+(?:payout|credit|dated)|payout|pay-?out|funds?\s+released)\b/i.test(text);
}

/**
 * True when text describes money entering an investment/broker account or an
 * investment purchase. This is intentionally stricter than matching a broker
 * name: a broker can also send a genuine premium-product subscription alert.
 */
function isInvestmentFolioAllotment(body) {
  const text = String(body || '').toLowerCase();
  const hasAllotment = /\b(?:units?\s+allotted|allotted\s+at\s+nav|units?\s*:\s*[\d.]+\s*,\s*nav|nav\s*:\s*[\d.]+|units?\s+(?:credited|allotted)\s+under\s+folio|allotted\s+for\s+your\s+investment)\b/i.test(text);
  const hasFolioOrFund = /\b(?:folio|fund|mutual\s+fund|amc)\b/i.test(text);
  return hasAllotment && hasFolioOrFund;
}

function isInvestmentFundingMessage(value) {
  const text = String(value || '');
  if (!text || !MOVEMENT_VERB.test(text)) return false;
  if (isInvestmentFolioAllotment(text)) return false;
  const explicitInvestment = INVESTMENT_INTENT.test(text);
  const brokerFunding = FINANCIAL_PROVIDER.test(text) &&
    /\b(?:add(?:ing|ed)?|fund(?:s|ed|ing)?|top[ -]?up|debit(?:ed)?|paid|sent|transferred|credited|deposited)\b/i.test(text);
  if (!explicitInvestment && !brokerFunding) return false;
  // A settlement payout is money vacating the investment account toward the
  // bank, not funding. Must never register as an investment contribution.
  if (isBrokerSettlementMessage(text)) return false;
  // Brokerage/maintenance fees are consumption, even though the provider is
  // financial. They must remain ordinary spend rows for later categorisation.
  if (FEE_ONLY.test(text) && !/\b(?:sip|mutual\s+fund|investment|invested|add(?:ed)?\s+(?:money|funds?))\b/i.test(text)) {
    return false;
  }
  return true;
}

function isInvestmentMandateMessage(value) {
  const text = String(value || '');
  return FINANCIAL_PROVIDER.test(text) &&
    /\b(?:autopay|auto[- ]?pay|mandate|standing\s+instruction|sip)\b/i.test(text) &&
    INVESTMENT_INTENT.test(text) &&
    !FEE_ONLY.test(text);
}

function isNonSubscriptionFinancialName(value) {
  return FINANCIAL_MOVEMENT_NAME.test(String(value || ''));
}

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
 * A bank alert can put a date, account number, or cadence label after
 * "for". Those values are not merchant names, even when the rest of the
 * message looks like a mandate confirmation. Keep this check shared by the
 * SMS parser, detector, and API read path so old false-positive rows are not
 * shown while the database is being repaired naturally.
 */
function isUsableSubscriptionName(name) {
  const value = String(name || '').replace(/\s+/g, ' ').trim();
  if (value.length < 2 || value.length > 100) return false;
  if (!/[A-Za-z]{2,}/.test(value)) return false;

  // Raw UPI VPAs (containing '@') are peer/merchant transfer handles, not subscriptions
  if (value.includes('@')) return false;

  // Ordinary fuel and vehicle fill-ups are variable spends, not subscriptions
  if (/\b(?:petroleum|petrol|fuel|gas\s*station|oil\s*co|hpcl|bpcl|iocl)\b/i.test(value)) {
    return false;
  }

  const normalized = value.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  if (
    /^(?:daily|weekly|fortnightly|monthly|quarterly|half yearly|yearly|annual)(?:\s+(?:payment|charge|debit|subscription|mandate|autopay|plan))?$/.test(
      normalized
    )
  ) {
    return false;
  }
  if (/^(?:account|bank|upi|vpa|mandate|instruction|reference|ref|unknown)$/.test(normalized)) {
    return false;
  }
  return true;
}

/** Only rows with enough data to show a truthful renewal card are public. */
function isDisplayableSubscriptionRecord(record) {
  const name = record?.displayName ?? record?.display_name;
  const amount = Number(record?.typicalAmountInr ?? record?.typical_amount_inr);
  const cadence = Number(record?.cadenceDays ?? record?.cadence_days);
  const next = record?.nextExpectedOn ?? record?.next_expected_on;
  const detectionSource = record?.detectionSource ?? record?.detection_source;
  const autopayStatus = record?.autopayStatus ?? record?.autopay_status;
  const activeMandate = detectionSource === 'mandate' && autopayStatus === 'active';
  return (
    isUsableSubscriptionName(name) &&
    !isNonSubscriptionFinancialName(name) &&
    Number.isFinite(amount) &&
    (amount > 0 || activeMandate) &&
    Number.isInteger(cadence) &&
    cadence >= MIN_CADENCE_DAYS &&
    cadence <= MAX_CADENCE_DAYS &&
    (Boolean(next) || activeMandate)
  );
}

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
 * The UTC midnight of a calendar day, from any shape a `date` column can
 * arrive in.
 *
 * The driver parses a Postgres `date` (OID 1082) into a JS Date, so
 * appending a time suffix to it ("Mon Oct 21 2026 …T00:00:00Z") is not a
 * date at all — it is an invalid one, and every later `toISOString()` on it
 * throws "Invalid time value". Strings are read as plain calendar days so a
 * `YYYY-MM-DD` value keeps the day it names instead of shifting a day in
 * some other timezone.
 */
function utcDayStart(value) {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) return null;
    return new Date(Date.UTC(value.getFullYear(), value.getMonth(), value.getDate()));
  }
  const text = String(value).trim();
  if (!text) return null;
  const calendarDay = /^(\d{4})-(\d{2})-(\d{2})/.exec(text);
  if (calendarDay) {
    return new Date(
      Date.UTC(Number(calendarDay[1]), Number(calendarDay[2]) - 1, Number(calendarDay[3])),
    );
  }
  const parsed = new Date(text);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * Return the next scheduled occurrence after today.
 *
 * A recurring row can be read long after its last observed charge. Returning
 * `last + cadence` forever leaves an obviously expired date on the card. We
 * keep the cadence-based model, but roll the display date forward to the next
 * cycle while leaving the last observed charge available to the UI for stale
 * or missed-payment review.
 *
 * An unusable anchor date yields null instead of an invalid date, so one
 * malformed row can never take the whole screen down.
 */
function nextExpectedAfter(date, cadenceDays, now = new Date()) {
  let next = utcDayStart(date);
  if (!next) return null;
  next.setUTCHours(0, 0, 0, 0);
  const anchorDay = next.getUTCDate();
  const calendarMonthly = cadenceDays >= 26 && cadenceDays <= 32;
  const calendarYearly = cadenceDays >= 350;
  const advance = () => {
    if (calendarYearly) {
      const year = next.getUTCFullYear() + 1;
      const month = next.getUTCMonth();
      const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
      next = new Date(Date.UTC(year, month, Math.min(anchorDay, lastDay)));
      return;
    }
    if (calendarMonthly) {
      const year = next.getUTCFullYear();
      const month = next.getUTCMonth() + 1;
      const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
      next = new Date(Date.UTC(year, month, Math.min(anchorDay, lastDay)));
      return;
    }
    next.setUTCDate(next.getUTCDate() + Math.round(cadenceDays));
  };
  advance();
  const today = new Date(now);
  today.setUTCHours(0, 0, 0, 0);
  while (next <= today) advance();
  return next;
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
function detectRecurringSeries(rows, { now = new Date() } = {}) {
  const byMerchant = new Map();
  for (const row of rows) {
    if (row.entry_kind && row.entry_kind !== 'spend') continue;
    if (!isUsableSubscriptionName(row.merchant_name)) continue;
    if (isNonSubscriptionFinancialName(row.merchant_name)) continue;
    const key = merchantSeriesKey(row.merchant_name);
    // A charge with no merchant name can't be grouped with anything — two
    // unnamed ₹499 charges are not evidence of a subscription.
    if (!key) continue;
    if (!byMerchant.has(key)) byMerchant.set(key, []);
    byMerchant.get(key).push(row);
  }

  const series = [];
  for (const [key, group] of byMerchant) {
    // Known brands are admitted on two matching charges: a brand-name match
    // is strong prior evidence, and two hugs the pattern one transparent
    // step below the anonymous-merchant rule of three. Everything else
    // keeps the conservative rule.
    const brand = brandFor(group[group.length - 1]?.merchant_name);
    const minOccurrences = brand ? 2 : MIN_OCCURRENCES;
    if (group.length < minOccurrences) continue;

    const amounts = group.map((r) => Number(r.amount_inr));
    const typical = median(amounts);
    if (typical <= 0) continue;

    // Keep only the charges close to the typical amount. A merchant can be
    // both a subscription and an occasional purchase (Amazon Prime and
    // Amazon shopping), and mixing them produces a nonsense cadence.
    const consistent = group.filter(
      (r) => Math.abs(Number(r.amount_inr) - typical) <= typical * AMOUNT_TOLERANCE
    );
    if (consistent.length < minOccurrences) continue;

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
    const next = nextExpectedAfter(last, cadence, now);

    const latest = consistent[consistent.length - 1];
    series.push({
      merchantKey: key,
      // The canonical catalog name when the merchant matches a known brand
      // ('OPENAILLC' → 'OpenAI'), otherwise the most recent spelling: the
      // one the user will recognise on their statement.
      displayName: brand?.name ?? latest.merchant_name,
      typicalAmountInr: typical,
      cadenceDays: Math.round(cadence),
      occurrenceCount: consistent.length,
      firstSeenOn: dates[0],
      lastSeenOn: last,
      nextExpectedOn: next,
      categoryId: latest.category_id || null,
      userCategoryId: latest.user_category_id || null,
      userCardId: latest.user_card_id || null,
      paymentMethod: latest.instrument || null,
    });
  }

  // Biggest annual cost first — that is the order in which someone
  // reviewing their subscriptions wants to see them.
  series.sort((a, b) => annualCost(b) - annualCost(a));
  return series;
}

/** What a series costs per year, at its detected cadence. */
function annualCost(series) {
  return series.typicalAmountInr * annualMultiplier(series.cadenceDays);
}

/**
 * Charges per year implied by a cadence.
 *
 * `365 / cadenceDays` is wrong for calendar cycles: a ₹1,499 subscription
 * billed monthly costs ₹17,988/year, not 1,499 × 365/30 = 18,239. Calendar
 * billing (the 1st of every month) runs on 12/4/2/1 annual payments, so the
 * estimate is bucketed to the same named cycles the UI labels use
 * (cadenceLabel). Only genuinely off-calendar cadences (e.g. exact 28-day
 * cycles) fall back to 365/days — that over-counts by ~2% there, which is
 * the honest price of an odd cycle.
 */
function annualMultiplier(cadenceDays) {
  if (cadenceDays >= 350) return 1; // yearly
  if (cadenceDays >= 175) return 2; // ~6 months
  if (cadenceDays >= 85) return 4; // ~quarterly
  if (cadenceDays >= 26 && cadenceDays <= 32) return 12; // monthly
  if (cadenceDays >= 13 && cadenceDays <= 17) return 26; // fortnightly
  if (cadenceDays >= 5 && cadenceDays <= 10) return 52; // weekly
  return 365 / cadenceDays;
}

/**
 * One honest state per series, computed at read time from stored facts.
 * Replaces the previous triple-coincidence of cadence flags, renewal passing
 * and staleness that three UI checks had to reverse-engineer.
 *
 * - confirmed: the cadence is proven (user edit, mandate text, or ≥3 real
 *   charges) and the series is currently billing.
 * - needs_cadence: merchant and amount are known but the cycle is a guess;
 *   render the per-charge amount only, never an annual figure.
 * - unused: an AutoPay mandate was registered but no charges followed for
 *   longer than the mandate's own cycle — show it registered, not spending.
 * - at_risk: it used to bill and now hasn't, past one-and-a-half cycles —
 *   cancelled, paused, or a missed charge; worth one review.
 */
function engineStatus(row, now = new Date()) {
  const cadence = Number(row.cadenceDays ?? row.cadence_days) || 30;
  if (row.cadenceConfirmed === false || row.cadence_confirmed === false) {
    return 'needs_cadence';
  }
  // A saved renewal date that already passed is direct evidence the saved
  // schedule didn't happen — the user must re-assert it. This applies to
  // user-edited dates as well: their lapsed claim is their data, and it
  // stays flagged rather than being silently projected forward.
  const savedNext = row.nextExpectedOn ?? row.next_expected_on;
  if (savedNext) {
    const today = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate()
    );
    // The driver hands back a `date` column as a JS Date; normalize it to
    // the calendar day it names instead of string-concatenating a suffix.
    const savedDay = utcDayStart(savedNext);
    if (savedDay && savedDay < today) return 'at_risk';
  }
  // Manually entered subscriptions are user-asserted facts, not observed
  // patterns: they stay confirmed on trust.
  if (row.detectionSource === 'manual' || row.detection_source === 'manual') {
    return 'confirmed';
  }
  const source = row.detectionSource ?? row.detection_source;
  const anchor = row.lastSeenOn ?? row.last_seen_on ?? row.firstSeenOn ?? row.first_seen_on;
  if (!anchor) return 'confirmed';
  const anchorDay = utcDayStart(anchor);
  if (!anchorDay) return 'confirmed';
  const age = daysBetween(anchorDay, now);
  if (age > Math.round(cadence * 1.5)) {
    const occurrences = Number(row.occurrenceCount ?? row.occurrence_count) || 0;
    return source === 'mandate' && occurrences <= 1 ? 'unused' : 'at_risk';
  }
  return 'confirmed';
}

module.exports = {
  detectRecurringSeries,
  merchantSeriesKey,
  annualCost,
  annualMultiplier,
  engineStatus,
  nextExpectedAfter,
  utcDayStart,
  isUsableSubscriptionName,
  isDisplayableSubscriptionRecord,
  isInvestmentFundingMessage,
  isInvestmentFolioAllotment,
  isInvestmentMandateMessage,
  isBrokerSettlementMessage,
  isNonSubscriptionFinancialName,
  MIN_OCCURRENCES,
  AMOUNT_TOLERANCE,
  CADENCE_TOLERANCE,
};
