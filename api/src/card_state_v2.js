'use strict';

/**
 * Server recording v2 — Card Rewards Phase 1, work package WP8.
 *
 * v2-shaped cards (reward_math_v2.isV2Card, plan C3.2 as amended by C8 D10)
 * record their transactions here instead of through reward_math.js:
 *
 *   - the reward is reward_math_v2.computeTransactionRewardV2, with the
 *     merchant directory loaded from merchant_brands / payment_platforms;
 *   - EVERY applicable cap (targets, card scope, and each parent) moves its
 *     own cap_states row, in its own period, in NATIVE units — points for
 *     *_points, ₹ for *_cashback and eligible_spend, a count for txn_count —
 *     and the row records `cap_kind` so a reader knows the unit (C8 D15f);
 *   - cap periods follow the cap's `period` + `anchor`, milestone windows
 *     follow C3.7 (anchor date anniversary_on ?? opened_on ?? created_at,
 *     the last flagged approximate; welcome milestones use window_days);
 *   - expected_points / expected_value_inr come from the v2 result;
 *   - each transaction keeps a record (transactions.card_state_v2) of every
 *     row it moved, so reversal subtracts exactly what was applied.
 *
 * Invariant: a v2 cap/milestone/fee-waiver row's value is the sum of the
 * matching entries in the records of the card's active spends. Apply and
 * reverse keep it incrementally; rebuild (GET /user-cards' reconcile, the
 * recompute script, and the repair of a v1-era row) re-establishes it from
 * the ledger by replaying transactions in date order.
 *
 * v1-shaped cards never reach this module's write paths: applyIfV2 and
 * reconcileIfV2 return null and index.js runs its unchanged v1 code.
 *
 * Context: the server never knows the payment platform (`platform` is
 * null), and the engine never infers it (C3.1), so platform-only bonuses are
 * not credited here. MCC and VPA come from the stored transaction.
 */

const rewardV2 = require('./reward_math_v2');
const { loadDirectory } = require('./merchant_directory');
const { safeErrorCode } = require('./safeErrorCode');
const {
  periodBounds, cardAnchorDate, cardIssueAnchorDate, windowBoundsV2, calendarDay, istDay, addDays,
} = require('./cycles');

const RECORD_VERSION = 1;
const RECORD_SECTIONS = ['caps', 'milestones', 'fee_waivers'];
const LEDGER_REASON = 'points earned on transaction';
const DIRECTORY_TTL_MS = 5 * 60 * 1000;
const MAX_PERIODS_PER_CAP = 5000;
const PAISE_EPS = 1e-6;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function num(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function arr(value) {
  return Array.isArray(value) ? value : [];
}

function round2(value) {
  if (!Number.isFinite(value)) return 0;
  const r = Math.round(value * 100 + (value >= 0 ? PAISE_EPS : -PAISE_EPS)) / 100;
  return r === 0 ? 0 : r;
}

/** India calendar day of a transaction timestamp — the day v2 windows use (C8 D23c). */
function dayOf(value) {
  return istDay(value);
}

function minDay(a, b) {
  return a <= b ? a : b;
}

function maxDay(a, b) {
  return a >= b ? a : b;
}

const key = (id, start) => `${id}|${start}`;

// ---------------------------------------------------------------------------
// The v2 card
// ---------------------------------------------------------------------------

/**
 * Everything recording needs about one user card: the engine card fields,
 * its rules, caps (with `targets`), milestones, and two anchor dates: the
 * card-year anchor (C3.7: anniversary_on ?? opened_on ?? created_at) and the
 * issue anchor for welcome windows (C8 D22b: opened_on ?? anniversary_on ??
 * created_at).
 */
function buildV2Card({ userCard, rules, caps, milestones }) {
  const u = userCard;
  const card = {
    point_value_inr: u.point_value_inr,
    base_reward_unit: u.base_reward_unit,
    base_reward_rate: u.base_reward_rate,
    excluded_categories: arr(u.excluded_categories),
    accrual_rounding: u.accrual_rounding ?? null,
    cashback_rounding: u.cashback_rounding ?? null,
    accrual_block_inr: u.accrual_block_inr ?? null,
  };
  const capList = arr(caps).map((c) => ({ ...c, targets: arr(c.targets) }));
  return {
    userCardId: u.id,
    profileId: u.profile_id,
    cardProductId: u.card_product_id,
    statementDay: u.statement_day ?? null,
    anchor: cardAnchorDate({ anniversaryOn: u.anniversary_on, openedOn: u.opened_on, createdAt: u.created_at }),
    issueAnchor: cardIssueAnchorDate({ anniversaryOn: u.anniversary_on, openedOn: u.opened_on, createdAt: u.created_at }),
    openedOn: calendarDay(u.opened_on),
    card,
    rules: arr(rules),
    caps: capList,
    capById: new Map(capList.map((c) => [c.id, c])),
    milestones: arr(milestones),
  };
}

function capWindow(v2, cap, when) {
  return windowBoundsV2(cap.period, when, {
    statementDay: v2.statementDay,
    anchor: cap.anchor,
    anchorDate: v2.anchor.date,
    anchorApproximate: v2.anchor.approximate,
  });
}

/** Welcome milestones (window_days) count from the issue date; the rest from the card-year anchor. */
function milestoneWindow(v2, milestone, when) {
  const windowDays = milestone.window_days ?? null;
  const anchor = windowDays != null ? v2.issueAnchor : v2.anchor;
  return windowBoundsV2(milestone.period, when, {
    statementDay: v2.statementDay,
    anchor: milestone.anchor,
    anchorDate: anchor.date,
    anchorApproximate: anchor.approximate,
    windowDays,
  });
}

/**
 * The cap's amount in its native unit for `kind` — as reward_math_v2
 * normalises it: a v2 cap's `cap_amount`; a legacy `reward_value` cap read as
 * points is `cap_value / point_value_inr` (C3.6).
 */
function capNativeAmount(cap, kind, card) {
  if (cap.cap_kind != null) return num(cap.cap_amount);
  const value = num(cap.cap_value);
  if (value == null) return null;
  if (cap.measure === 'reward_value' && (kind === 'total_points' || kind === 'bonus_points')) {
    const pointValue = num(card && card.point_value_inr) || 0;
    return pointValue > 0 ? value / pointValue : null;
  }
  return value;
}

/**
 * The figure expected_points carries, as v1 did: points when the spend earns
 * points, else ₹ of cashback (a cashback card). The cashback of a spend that
 * earns both is kept in expected_cashback_inr only (see earnedSplit).
 */
function nativeAmount(result) {
  if (result.points != null) return result.points;
  if (result.cashbackInr != null) return result.cashbackInr;
  return 0;
}

/** Points and ₹ cashback kept apart, each null when the result has none. */
function earnedSplit(result) {
  return {
    points: result.points != null ? round2(result.points) : null,
    cashback: result.cashbackInr != null ? round2(result.cashbackInr) : null,
  };
}

/**
 * Ledger rows for one spend: the expected_points figure under the v1 reason,
 * exactly as v1 writes it (₹ on a cashback-only card). The cashback of a
 * spend that also earns points gets NO ledger row (WP8 review ruling): every
 * reader of points_ledger, installed apps included, sums all rows as points;
 * that cashback lives in transactions.expected_cashback_inr only.
 */
function ledgerRows(outcome) {
  return outcome.native > 0 ? [{ reason: LEDGER_REASON, delta: outcome.native }] : [];
}

/** C3.1 context from a stored transaction row (or the same fields from a write path). */
function transactionContext(row) {
  return {
    amount: Number(row.amount_inr),
    occurred: row.occurred_at,
    category_id: row.category_id || null,
    merchant_name: row.merchant_name || null,
    merchant_vpa: row.merchant_vpa || null,
    mcc: row.mcc || null,
    rail: row.rail || 'unknown',
    platform: null,
  };
}

// ---------------------------------------------------------------------------
// One transaction
// ---------------------------------------------------------------------------

/**
 * The rule this transaction earns under and the caps it counts against, each
 * with its window; `excluded` when the engine excludes the spend (an
 * exclusion rule, including a D16b minimum amount, or the card's excluded
 * categories).
 */
function capPlan(v2, directory, ctx) {
  const c = rewardV2.resolveContext(ctx, directory);
  const pick = rewardV2.pickRuleV2(v2.rules, c, v2.card);
  if (pick.excluded || !(c.amount > 0)) return { ctx: c, caps: [], excluded: Boolean(pick.excluded) };
  const caps = rewardV2.applicableCaps({ card: v2.card, capRules: v2.caps, rule: pick.rule, ctx: c });
  return {
    ctx: c,
    excluded: false,
    caps: caps.map((cap) => ({ cap, window: capWindow(v2, v2.capById.get(cap.id), c.occurred) })),
  };
}

/**
 * Prices one transaction on a v2 card. `consumedOf(capId, periodStart)` is
 * each cap's native consumption before this transaction, in the period the
 * transaction falls in. Returns the engine result, one cap entry per cap
 * that moved (`{ id, kind, amount, start, end, approximate, delta }`), the
 * native figure for expected_points, points and cashback apart, the ₹ value,
 * and whether the spend is excluded.
 */
function computeTransactionV2(v2, directory, ctx, consumedOf, plan = null) {
  const p = plan || capPlan(v2, directory, ctx);
  const before = {};
  for (const { cap, window } of p.caps) before[cap.id] = consumedOf(cap.id, window.start) || 0;
  const result = rewardV2.computeTransactionRewardV2({
    card: v2.card, rewardRules: v2.rules, capRules: v2.caps, capConsumedBefore: before, ctx: p.ctx, directory,
  });
  const capEntries = [];
  for (const { cap, window } of p.caps) {
    const delta = num(result.capDeltas[cap.id]);
    if (!delta) continue;
    capEntries.push({
      id: cap.id, kind: cap.kind, amount: cap.amount,
      start: window.start, end: window.end, approximate: window.approximate, delta,
    });
  }
  return {
    result,
    capEntries,
    native: round2(nativeAmount(result)),
    ...earnedSplit(result),
    value: round2(result.valueInr),
    excluded: Boolean(result.excluded || p.excluded),
  };
}

/**
 * C3.7 + C8 D22a: the milestone rows this spend qualifies for. A spend the
 * engine excludes (`excluded`: an exclusion rule, a minimum amount, the
 * card's excluded categories) never qualifies; neither does a category in
 * the milestone's excluded_category_ids. Welcome milestones only count
 * inside their window.
 */
function milestoneEntries(v2, ctx, { excluded = false } = {}) {
  const category = ctx.category_id || null;
  const amount = Number(ctx.amount);
  if (excluded || !(amount > 0)) return [];
  if (category != null && v2.card.excluded_categories.includes(category)) return [];
  const out = [];
  for (const m of v2.milestones) {
    if (category != null && arr(m.excluded_category_ids).includes(category)) continue;
    const w = milestoneWindow(v2, m, ctx.occurred);
    if (!w) continue;
    out.push({ id: m.id, start: w.start, end: w.end, approximate: w.approximate, delta: round2(amount) });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Records (transactions.card_state_v2)
// ---------------------------------------------------------------------------

function recordEntry(e) {
  const out = { id: e.id, start: e.start, end: e.end, delta: round2(Number(e.delta)) };
  if (e.kind !== undefined) out.kind = e.kind;
  return out;
}

function sortEntries(entries) {
  return [...entries].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
}

/** A record from sections of entries; null when nothing moved. */
function toRecord(userCardId, sections) {
  const record = { v: RECORD_VERSION, user_card_id: userCardId };
  let any = false;
  for (const name of RECORD_SECTIONS) {
    const entries = sortEntries(arr(sections[name]).map(recordEntry));
    if (entries.length > 0) {
      record[name] = entries;
      any = true;
    }
  }
  return any ? record : null;
}

function canonical(record) {
  if (!record) return 'null';
  const out = { v: record.v, user_card_id: record.user_card_id };
  for (const name of RECORD_SECTIONS) {
    if (arr(record[name]).length > 0) out[name] = sortEntries(arr(record[name]).map(recordEntry));
  }
  return JSON.stringify(out);
}

// ---------------------------------------------------------------------------
// Directory
// ---------------------------------------------------------------------------

let directoryCache = null;

/**
 * The merchant/platform directory (C5) from merchant_brands /
 * payment_platforms, cached in-process for DIRECTORY_TTL_MS. Inactive
 * merchants are loaded too: they are never resolved but still count as
 * ancestors (C8 D9(10)).
 */
async function loadDirectoryCached(client, { now = Date.now() } = {}) {
  if (directoryCache && now - directoryCache.at < DIRECTORY_TTL_MS) return directoryCache.directory;
  const merchants = await client.query(
    `SELECT slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc, is_active
       FROM merchant_brands ORDER BY slug`,
  );
  const platforms = await client.query(
    `SELECT slug, name, kind, issuer_slug, aliases, is_active FROM payment_platforms ORDER BY slug`,
  );
  const directory = loadDirectory({ merchants: merchants.rows, platforms: platforms.rows });
  directoryCache = { directory, at: now };
  return directory;
}

/** Drops the directory and v1-shape caches (tests; after a catalogue publish in-process). */
function clearDirectoryCache() {
  directoryCache = null;
  v1ShapeCache.clear();
}

// ---------------------------------------------------------------------------
// Loading a user card
// ---------------------------------------------------------------------------

const RULE_COLUMNS = `id, category_id, merchant_pattern, rail, unit, rate, min_txn_inr, max_txn_inr,
       excluded_categories, effective_from, effective_to, priority, rule_role, merchant_slugs,
       platform_slugs, mcc_include, mcc_exclude, except_merchant_slugs, except_platform_slugs,
       block_inr, min_engine_version, max_engine_version, display_note`;

// Card products known to be v1-shaped at a given data_version (bumped by every
// rule/cap change) and rounding settings, so a v1 card costs one query here.
const V1_SHAPE_CACHE_MAX = 5000;
const v1ShapeCache = new Set();

function shapeKey(row) {
  return `${row.card_product_id}|${row.data_version}|${row.accrual_rounding ?? ''}|${row.cashback_rounding ?? ''}`;
}

/**
 * The user card as a v2 card, or null when its product is v1-shaped (or the
 * card isn't visible, or belongs to another profile when `profileId` is
 * given — C8 D23e). Rules and caps are read in the v2 feed's order (C8 D22d:
 * rules by priority, source_local_id nulls last, id; caps by
 * source_local_id nulls last, id): that is the "catalogue order" that breaks
 * ties between equally binding caps (D9(8)).
 */
async function loadV2Card(client, userCardId, { profileId = null } = {}) {
  if (!userCardId) return null;
  const cards = await client.query(
    `SELECT uc.id, uc.profile_id, uc.card_product_id, uc.statement_day, uc.opened_on,
            uc.anniversary_on, uc.created_at, cp.data_version,
            cp.point_value_inr, cp.base_reward_unit, cp.base_reward_rate, cp.excluded_categories,
            cp.accrual_rounding, cp.cashback_rounding, cp.accrual_block_inr
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.id = $1 AND ($2::uuid IS NULL OR uc.profile_id = $2)`,
    [userCardId, profileId],
  );
  const userCard = cards.rows[0];
  if (!userCard) return null;
  if (v1ShapeCache.has(shapeKey(userCard))) return null;
  const rules = await client.query(
    `SELECT ${RULE_COLUMNS} FROM reward_rules WHERE card_product_id = $1
      ORDER BY priority, source_local_id NULLS LAST, id`,
    [userCard.card_product_id],
  );
  const caps = await client.query(
    `SELECT k.id, k.reward_rule_id, k.category_id, k.label, k.measure, k.period, k.cap_value,
            k.post_cap_unit, k.post_cap_rate, k.cap_kind, k.cap_amount, k.scope, k.parent_cap_id,
            k.post_cap_behavior, k.anchor, k.min_engine_version,
            COALESCE((SELECT array_agg(t.reward_rule_id::text ORDER BY t.reward_rule_id)
                        FROM cap_rule_targets t WHERE t.cap_rule_id = k.id), '{}'::text[]) AS targets
       FROM cap_rules k WHERE k.card_product_id = $1
      ORDER BY k.source_local_id NULLS LAST, k.id`,
    [userCard.card_product_id],
  );
  const card = {
    accrual_rounding: userCard.accrual_rounding,
    cashback_rounding: userCard.cashback_rounding,
  };
  if (!rewardV2.isV2Card(card, rules.rows, caps.rows)) {
    if (v1ShapeCache.size >= V1_SHAPE_CACHE_MAX) v1ShapeCache.clear();
    v1ShapeCache.add(shapeKey(userCard));
    return null;
  }
  const milestones = await client.query(
    `SELECT id, label, period, anchor, threshold_spend_inr, window_days, excluded_category_ids
       FROM milestone_rules WHERE card_product_id = $1`,
    [userCard.card_product_id],
  );
  return buildV2Card({ userCard, rules: rules.rows, caps: caps.rows, milestones: milestones.rows });
}

// ---------------------------------------------------------------------------
// Row writes shared by apply / reverse
// ---------------------------------------------------------------------------

const CAP_STATE_RETURNING = `cap_rule_id, period_start, period_end, consumed, cap_value_snapshot,
                             cap_kind, cap_amount, approximate_window`;
const MILESTONE_STATE_RETURNING = 'milestone_rule_id, period_start, period_end, qualified_spend, approximate_window';
const FEE_WAIVER_STATE_RETURNING = 'id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at';

/** Mirrors index.js's v1 fee-waiver marking: waived at/above the threshold, un-waived below it. */
async function settleFeeWaiver(client, state, threshold) {
  if (!state) return state;
  if (!state.waived_at && Number(state.qualified_spend) >= Number(threshold)) {
    const marked = await client.query(
      `UPDATE fee_waiver_states SET waived_at = now() WHERE id = $1 RETURNING ${FEE_WAIVER_STATE_RETURNING}`,
      [state.id],
    );
    return marked.rows[0];
  }
  if (state.waived_at && Number(state.qualified_spend) < Number(threshold)) {
    const unmarked = await client.query(
      `UPDATE fee_waiver_states SET waived_at = NULL WHERE id = $1 RETURNING ${FEE_WAIVER_STATE_RETURNING}`,
      [state.id],
    );
    return unmarked.rows[0];
  }
  return state;
}

/**
 * Subtracts a record's entries from the rows they were added to. UPDATE
 * only: a row that no longer exists (its rule was deleted with a catalogue
 * re-import) has nothing left to undo.
 */
async function reverseRecord(client, profileId, record) {
  const out = { capStates: [], milestoneStates: [], feeWaiverStates: [] };
  if (!record || typeof record !== 'object') return out;
  const userCardId = record.user_card_id;
  for (const e of arr(record.caps)) {
    const updated = await client.query(
      `UPDATE cap_states
          SET consumed = GREATEST(0::numeric, consumed - $4::numeric), updated_at = now()
        WHERE user_card_id = $1 AND cap_rule_id = $2 AND period_start = $3 AND profile_id = $5
        RETURNING ${CAP_STATE_RETURNING}`,
      [userCardId, e.id, e.start, e.delta, profileId],
    );
    if (updated.rows[0]) out.capStates.push(updated.rows[0]);
  }
  for (const e of arr(record.milestones)) {
    const updated = await client.query(
      `UPDATE milestone_states
          SET qualified_spend = GREATEST(0::numeric, qualified_spend - $4::numeric), updated_at = now()
        WHERE user_card_id = $1 AND milestone_rule_id = $2 AND period_start = $3 AND profile_id = $5
        RETURNING ${MILESTONE_STATE_RETURNING}`,
      [userCardId, e.id, e.start, e.delta, profileId],
    );
    if (updated.rows[0]) out.milestoneStates.push(updated.rows[0]);
  }
  for (const e of arr(record.fee_waivers)) {
    const updated = await client.query(
      `UPDATE fee_waiver_states fw
          SET qualified_spend = GREATEST(0::numeric, fw.qualified_spend - $4::numeric), updated_at = now()
        WHERE fw.user_card_id = $1 AND fw.fee_waiver_rule_id = $2 AND fw.period_start = $3 AND fw.profile_id = $5
        RETURNING fw.id, fw.fee_waiver_rule_id, fw.period_start, fw.period_end, fw.qualified_spend, fw.waived_at,
                  (SELECT r.threshold_spend_inr FROM fee_waiver_rules r WHERE r.id = fw.fee_waiver_rule_id) AS threshold`,
      [userCardId, e.id, e.start, e.delta, profileId],
    );
    const row = updated.rows[0];
    if (!row) continue;
    const { threshold, ...state } = row;
    out.feeWaiverStates.push(await settleFeeWaiver(client, state, threshold));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Live recording: apply / reverse
// ---------------------------------------------------------------------------

/** Reads each planned cap's row for its period. `stale` = a row the v1 path wrote (no cap_kind). */
async function readCapRows(client, v2, plan) {
  const consumed = new Map();
  let stale = false;
  for (const { cap, window } of plan.caps) {
    const row = await client.query(
      `SELECT consumed, cap_kind FROM cap_states
        WHERE user_card_id = $1 AND cap_rule_id = $2 AND period_start = $3 AND profile_id = $4`,
      [v2.userCardId, cap.id, window.start, v2.profileId],
    );
    if (!row.rows[0]) continue;
    if (row.rows[0].cap_kind == null) stale = true;
    consumed.set(key(cap.id, window.start), Number(row.rows[0].consumed));
  }
  return { consumed, stale };
}

async function applyTransactionV2(client, userId, v2, args) {
  const { txnId, amount, occurred, categoryId, merchantName, rail } = args;
  const userCardId = v2.userCardId;
  const stored = await client.query(
    `SELECT merchant_vpa, mcc, card_state_v2 FROM transactions WHERE id = $1 AND profile_id = $2`,
    [txnId, userId],
  );
  const txn = stored.rows[0] || {};
  // Applying twice must not count twice: undo whatever this transaction
  // still carries before recording it again.
  if (txn.card_state_v2) {
    await reverseRecord(client, userId, txn.card_state_v2);
    await client.query(`DELETE FROM points_ledger WHERE transaction_id = $1 AND profile_id = $2`, [txnId, userId]);
  }

  const directory = await loadDirectoryCached(client);
  const ctx = transactionContext({
    amount_inr: amount, occurred_at: occurred, category_id: categoryId, merchant_name: merchantName,
    merchant_vpa: txn.merchant_vpa, mcc: txn.mcc, rail,
  });
  const plan = capPlan(v2, directory, ctx);
  let rows = await readCapRows(client, v2, plan);
  if (rows.stale) {
    // A row in v1 units (written before this card became v2-shaped): rebuild
    // the card's periods around this date from the ledger, then price.
    await rebuildCardState(client, userId, v2, { asOf: occurred, caps: true, excludeTxnIds: [txnId] });
    rows = await readCapRows(client, v2, plan);
  }
  const outcome = computeTransactionV2(v2, directory, ctx, (id, start) => rows.consumed.get(key(id, start)) || 0, plan);

  const capStates = [];
  for (const e of outcome.capEntries) {
    const cap = v2.capById.get(e.id);
    const upserted = await client.query(
      `INSERT INTO cap_states
         (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed,
          cap_value_snapshot, cap_kind, cap_amount, approximate_window)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric), $7, $8, $9, $10)
       ON CONFLICT (user_card_id, cap_rule_id, period_start)
       DO UPDATE SET consumed = GREATEST(0::numeric, cap_states.consumed + $6::numeric),
                     period_end = EXCLUDED.period_end, cap_kind = EXCLUDED.cap_kind,
                     cap_amount = EXCLUDED.cap_amount, approximate_window = EXCLUDED.approximate_window,
                     updated_at = now()
       RETURNING ${CAP_STATE_RETURNING}`,
      [userId, userCardId, e.id, e.start, e.end, e.delta, num(cap && cap.cap_value) ?? 0, e.kind, e.amount, e.approximate],
    );
    capStates.push(upserted.rows[0]);
  }

  // C8 D22a: an excluded spend makes no milestone or fee-waiver progress.
  const milestones = milestoneEntries(v2, ctx, { excluded: outcome.excluded });
  const milestoneStates = [];
  for (const e of milestones) {
    const upserted = await client.query(
      `INSERT INTO milestone_states
         (profile_id, user_card_id, milestone_rule_id, period_start, period_end, qualified_spend, approximate_window)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric), $7)
       ON CONFLICT (user_card_id, milestone_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0::numeric, milestone_states.qualified_spend + $6::numeric),
                     period_end = EXCLUDED.period_end, approximate_window = EXCLUDED.approximate_window,
                     updated_at = now()
       RETURNING ${MILESTONE_STATE_RETURNING}`,
      [userId, userCardId, e.id, e.start, e.end, e.delta, e.approximate],
    );
    milestoneStates.push(upserted.rows[0]);
  }

  // Fee waivers: v1's spend-based rules and periods, recorded so reversal can
  // undo them. C8 D22a: an excluded spend (which covers the card's excluded
  // categories) counts toward none of them; the rule's own excluded
  // categories still apply. One rounding for the row and the record.
  const feeWaiverRules = outcome.excluded
    ? { rows: [] }
    : await client.query(
      `SELECT id, threshold_spend_inr, period, excluded_categories FROM fee_waiver_rules
        WHERE card_product_id = $1`,
      [v2.cardProductId],
    );
  const feeWaiverStates = [];
  const feeWaiverEntries = [];
  const feeWaiverDelta = round2(Number(amount));
  for (const rule of feeWaiverRules.rows) {
    if (categoryId && arr(rule.excluded_categories).includes(categoryId)) continue;
    const { start, end } = periodBounds(rule.period, occurred instanceof Date ? occurred : new Date(occurred), {
      statementDay: v2.statementDay,
    });
    const upserted = await client.query(
      `INSERT INTO fee_waiver_states (profile_id, user_card_id, fee_waiver_rule_id, period_start, period_end, qualified_spend)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric))
       ON CONFLICT (user_card_id, fee_waiver_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0::numeric, fee_waiver_states.qualified_spend + $6::numeric), updated_at = now()
       RETURNING ${FEE_WAIVER_STATE_RETURNING}`,
      [userId, userCardId, rule.id, start, end, feeWaiverDelta],
    );
    feeWaiverStates.push(await settleFeeWaiver(client, upserted.rows[0], rule.threshold_spend_inr));
    feeWaiverEntries.push({ id: rule.id, start, end, delta: feeWaiverDelta });
  }

  const record = toRecord(userCardId, { caps: outcome.capEntries, milestones, fee_waivers: feeWaiverEntries });
  await client.query(
    `UPDATE transactions
        SET expected_value_inr = $3, expected_points = $4, expected_cashback_inr = $5,
            card_state_v2 = $6::jsonb, updated_at = now()
      WHERE id = $1 AND profile_id = $2`,
    [txnId, userId, outcome.value, outcome.native, outcome.cashback, record ? JSON.stringify(record) : null],
  );

  let pointsLedgerEntry = null;
  for (const row of ledgerRows(outcome)) {
    const inserted = await client.query(
      `INSERT INTO points_ledger (profile_id, user_card_id, transaction_id, delta_points, reason, state, occurred_at)
       VALUES ($1, $2, $3, $4, $5, 'estimated', $6)
       RETURNING id, delta_points, reason, occurred_at`,
      [userId, userCardId, txnId, row.delta, row.reason, occurred],
    );
    if (row.reason === LEDGER_REASON) pointsLedgerEntry = inserted.rows[0];
  }

  return { capStates, milestoneStates, pointsLedgerEntry, feeWaiverStates };
}

/**
 * Undo exactly what this transaction's record says it added, zero its
 * expected values and delete its ledger rows (the v1 reverse does the same
 * for the ledger and expected values). A transaction with no record added
 * nothing to v2 state, so there is nothing to subtract.
 */
async function reverseTransactionV2(client, userId, v2, args) {
  const stored = await client.query(
    `SELECT card_state_v2 FROM transactions WHERE id = $1 AND profile_id = $2`,
    [args.txnId, userId],
  );
  const record = stored.rows[0] && stored.rows[0].card_state_v2;
  const reversed = await reverseRecord(client, userId, record);
  await client.query(
    `UPDATE transactions
        SET expected_value_inr = 0, expected_points = 0,
            expected_cashback_inr = CASE WHEN expected_cashback_inr IS NULL THEN NULL ELSE 0 END,
            card_state_v2 = NULL, updated_at = now()
      WHERE id = $1 AND profile_id = $2`,
    [args.txnId, userId],
  );
  await client.query(`DELETE FROM points_ledger WHERE transaction_id = $1 AND profile_id = $2`, [args.txnId, userId]);
  return { ...reversed, pointsLedgerEntry: null };
}

const HOOK_SAVEPOINT = 'card_state_v2';
const DEFERRED_STATE = Object.freeze({ capStates: [], milestoneStates: [], pointsLedgerEntry: null, feeWaiverStates: [] });

/**
 * index.js's applyTransactionState hook. Returns the state updates for a
 * v2-shaped card (sign +1 records, sign −1 reverses), or null so the v1
 * path runs unchanged. Callers that change an existing transaction hold the
 * user's `transaction-ingest:<user>` advisory lock first (C8 D23d), so a
 * rebuild never interleaves; this hook takes no lock of its own.
 *
 * C8 D33c: card-state recording never fails ingest. Everything runs inside
 * SAVEPOINT card_state_v2 — every caller (insert, edit, ignore/restore,
 * duplicate resolution, bulk apply, sync apply, repair) goes through here.
 * On any error the work is rolled back to the savepoint (so nothing is ever
 * half-applied or half-reversed), only safeErrorCode is logged, the
 * transaction keeps card_state_v2 = NULL (a later reversal then subtracts
 * nothing), and the next reconcile or recompute rebuilds the state. A failed
 * reversal still does what v1's reversal does to the transaction itself:
 * expected values to 0 and its ledger rows removed, so an ignored spend
 * never keeps counting. A v1-shaped card leaves the savepoint before the v1
 * path runs, which is unchanged.
 */
async function applyIfV2(client, userId, userCard, args) {
  const userCardId = (args && args.userCardId) || (userCard && userCard.id);
  await client.query(`SAVEPOINT ${HOOK_SAVEPOINT}`);
  try {
    const v2 = await loadV2Card(client, userCardId, { profileId: userId });
    const result = !v2
      ? null
      : args.sign < 0
        ? await reverseTransactionV2(client, userId, v2, args)
        : await applyTransactionV2(client, userId, v2, args);
    await client.query(`RELEASE SAVEPOINT ${HOOK_SAVEPOINT}`);
    return result;
  } catch (err) {
    await client.query(`ROLLBACK TO SAVEPOINT ${HOOK_SAVEPOINT}`);
    await client.query(`RELEASE SAVEPOINT ${HOOK_SAVEPOINT}`);
    console.warn('card_state_v2 deferred to the next rebuild', safeErrorCode(err));
    if (args && args.txnId) {
      if (args.sign < 0) {
        await client.query(
          `UPDATE transactions
              SET expected_value_inr = 0, expected_points = 0,
                  expected_cashback_inr = CASE WHEN expected_cashback_inr IS NULL THEN NULL ELSE 0 END,
                  card_state_v2 = NULL, updated_at = now()
            WHERE id = $1 AND profile_id = $2`,
          [args.txnId, userId],
        );
        await client.query(`DELETE FROM points_ledger WHERE transaction_id = $1 AND profile_id = $2`, [args.txnId, userId]);
      } else {
        await client.query(
          `UPDATE transactions SET card_state_v2 = NULL, updated_at = now() WHERE id = $1 AND profile_id = $2`,
          [args.txnId, userId],
        );
      }
    }
    return { ...DEFERRED_STATE };
  }
}

// ---------------------------------------------------------------------------
// Rebuild: replay the ledger for the periods around a date
// ---------------------------------------------------------------------------

function monthStart(day) {
  return `${day.slice(0, 8)}01`;
}

/**
 * Which days a rebuild replays and which it reads only for seeds.
 *
 * caps: `start`/`end` cover every cap's period containing `asOf` (plus the
 * current month when expected values are rebuilt, and `since`). Every cap
 * period intersecting [start, end] is rebuilt. Only a period containing
 * `start` can begin earlier, and only one containing `end` can finish
 * later; `seedFrom`/`seedTo` reach the edges of those, whose spends outside
 * the window count through their stored records.
 *
 * milestones: each milestone's window containing `asOf` (closed welcome
 * windows are history and are not rebuilt).
 *
 * Expected values are priced against the replayed caps, so `expected`
 * implies a cap rebuild.
 *
 * `floor` (C8 D23f) is the first day the card can have spends — opened_on or
 * its first transaction. Nothing is read or replayed before it, so a
 * lifetime cap or milestone rebuilds from the card's start, not from 1970.
 * Period keys are unchanged (a lifetime row still starts 1970-01-01).
 */
function rebuildRange(v2, {
  asOf = new Date(), since = null, caps = true, milestones = false, expected = false, floor = null,
} = {}) {
  const day = dayOf(asOf);
  const floorDay = floor ? minDay(calendarDay(floor), day) : null;
  const atFloor = (d) => (floorDay ? maxDay(d, floorDay) : d);
  let capRange = null;
  if (caps || expected) {
    let start = day;
    let end = day;
    for (const cap of v2.caps) {
      const w = capWindow(v2, cap, day);
      start = minDay(start, w.start);
      // C8 D33f: a lifetime window ends 9999-12-31; it must not stretch the
      // replay for the card's other caps. Later spends still count toward the
      // lifetime row as seeds, through their records.
      if (cap.period !== 'lifetime') end = maxDay(end, w.end);
    }
    if (expected) start = minDay(start, monthStart(day));
    if (since) start = minDay(start, calendarDay(since));
    start = atFloor(start);
    let seedFrom = start;
    let seedTo = end;
    for (const cap of v2.caps) {
      seedFrom = minDay(seedFrom, capWindow(v2, cap, start).start);
      seedTo = maxDay(seedTo, capWindow(v2, cap, end).end);
    }
    capRange = { start, end, seedFrom: atFloor(seedFrom), seedTo };
  }
  const milestoneWindows = [];
  if (milestones) {
    for (const m of v2.milestones) {
      const w = milestoneWindow(v2, m, day);
      if (w) milestoneWindows.push({ id: m.id, ...w });
    }
  }
  let loadFrom = capRange ? capRange.seedFrom : null;
  let loadTo = capRange ? capRange.seedTo : null;
  for (const w of milestoneWindows) {
    loadFrom = loadFrom == null ? atFloor(w.start) : minDay(loadFrom, atFloor(w.start));
    loadTo = loadTo == null ? w.end : maxDay(loadTo, w.end);
  }
  return { asOf: day, caps: capRange, milestones: milestoneWindows, loadFrom, loadTo };
}

/**
 * The periods a rebuild enumerates, per cap: those intersecting the replay
 * window, but never past the cap's own period containing `asOf` (C8 D33f).
 * A later spend in the window still gets its row (planReplay adds it).
 */
function rebuildPeriods(v2, range) {
  const out = new Map();
  if (!range.caps) return out;
  for (const cap of v2.caps) {
    const own = capWindow(v2, cap, range.asOf).end;
    out.set(cap.id, capPeriodsBetween(v2, cap, range.caps.start, minDay(range.caps.end, own)));
  }
  return out;
}

/** Every period of `cap` that intersects [start, end]. */
function capPeriodsBetween(v2, cap, start, end) {
  const out = [];
  let w = capWindow(v2, cap, start);
  for (let i = 0; w && i < MAX_PERIODS_PER_CAP; i += 1) {
    out.push(w);
    if (w.end >= end) break;
    w = capWindow(v2, cap, addDays(w.end, 1));
  }
  return out;
}

function sameNumber(a, b) {
  const x = num(a);
  const y = num(b);
  if (x == null || y == null) return x === y;
  return Math.abs(x - y) < 0.005;
}

/**
 * The pure replay. `transactions` are the card's rows from
 * `range.loadFrom`..`range.loadTo` (active spends, plus any row still
 * carrying a record), with id, amount_inr, occurred_at, category_id,
 * merchant_name, merchant_vpa, mcc, rail, status, instrument, entry_kind,
 * is_backfill, expected_points, expected_value_inr and card_state_v2.
 *
 * Returns the rebuilt rows (consumed > 0 only), the transactions whose
 * record or expected values change, and a diff against `existing*Rows`.
 */
function planReplay({
  v2, directory, range, transactions, expected = false, excludeTxnIds = [],
  existingCapRows = [], existingMilestoneRows = [],
}) {
  const excluded = new Set(arr(excludeTxnIds).map(String));
  const isEligible = (t) => t.status === 'active' && t.instrument === 'credit_card' && t.entry_kind === 'spend'
    && t.is_backfill !== true && !excluded.has(String(t.id));
  const ordered = [...arr(transactions)].sort((a, b) => {
    const time = new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime();
    return time || (String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0);
  });

  // --- caps -----------------------------------------------------------------
  // Every period of every cap that intersects the replay window is rebuilt.
  const caps = range.caps;
  const capRows = new Map(); // key -> row being rebuilt
  if (caps) {
    const periods = rebuildPeriods(v2, range);
    for (const cap of v2.caps) {
      for (const w of periods.get(cap.id)) {
        capRows.set(key(cap.id, w.start), {
          cap_rule_id: cap.id, period_start: w.start, period_end: w.end, consumed: 0,
          cap_kind: null, cap_amount: null, approximate_window: w.approximate,
          cap_value_snapshot: num(cap.cap_value) ?? 0,
        });
      }
    }
  }
  // A record entry for one of this card's caps whose period overlaps the
  // window is superseded by the rebuild — including a period that moved
  // because the card's anchor date changed.
  const supersededCapEntry = (e) => capRows.has(key(e.id, e.start))
    || (caps != null && v2.capById.has(e.id) && e.start <= caps.end && (e.end || e.start) >= caps.start);
  const addToCapRow = (e) => {
    const row = capRows.get(key(e.id, e.start));
    if (!row) return false;
    row.consumed += Number(e.delta);
    if (row.cap_kind == null && e.kind) {
      row.cap_kind = e.kind;
      const cap = v2.capById.get(e.id);
      row.cap_amount = e.amount != null ? e.amount : cap ? capNativeAmount(cap, e.kind, v2.card) : null;
    }
    return true;
  };

  const newCapEntries = new Map(); // txn id -> entries (replayed spends)
  const expectedUpdates = [];
  if (caps) {
    for (const t of ordered) {
      if (!isEligible(t)) continue;
      const day = dayOf(t.occurred_at);
      if (day < caps.start || day > caps.end) {
        // A seed: its period is rebuilt but the spend is outside the window,
        // so it counts through what its record says it added.
        for (const e of arr(t.card_state_v2 && t.card_state_v2.caps)) addToCapRow(e);
        continue;
      }
      const out = computeTransactionV2(v2, directory, transactionContext(t), (id, start) => {
        const row = capRows.get(key(id, start));
        return row ? row.consumed : 0;
      });
      for (const e of out.capEntries) {
        if (addToCapRow(e)) continue;
        // Defensive: a period the enumeration missed is still rebuilt.
        capRows.set(key(e.id, e.start), {
          cap_rule_id: e.id, period_start: e.start, period_end: e.end, consumed: Number(e.delta),
          cap_kind: e.kind, cap_amount: e.amount, approximate_window: e.approximate,
          cap_value_snapshot: num(v2.capById.get(e.id) && v2.capById.get(e.id).cap_value) ?? 0,
        });
      }
      newCapEntries.set(String(t.id), out.capEntries);
      if (expected && !(sameNumber(t.expected_points, out.native) && sameNumber(t.expected_value_inr, out.value)
          && sameNumber(t.expected_cashback_inr, out.cashback))) {
        expectedUpdates.push({
          id: t.id, occurred_at: t.occurred_at, native: out.native, value: out.value,
          points: out.points, cashback: out.cashback,
          before: { native: num(t.expected_points), value: num(t.expected_value_inr), cashback: num(t.expected_cashback_inr) },
        });
      }
    }
  }

  // --- milestones -------------------------------------------------------------
  const milestoneRows = new Map();
  for (const w of range.milestones) {
    milestoneRows.set(key(w.id, w.start), {
      milestone_rule_id: w.id, period_start: w.start, period_end: w.end, qualified_spend: 0,
      approximate_window: w.approximate,
    });
  }
  const milestoneWindowById = new Map(range.milestones.map((w) => [w.id, w]));
  const supersededMilestoneEntry = (e) => {
    if (milestoneRows.has(key(e.id, e.start))) return true;
    const w = milestoneWindowById.get(e.id);
    return w != null && e.start <= w.end && (e.end || e.start) >= w.start;
  };
  const newMilestoneEntries = new Map(); // txn id -> entries for rebuilt milestone rows
  if (milestoneRows.size > 0) {
    for (const t of ordered) {
      if (!isEligible(t)) continue;
      const ctx = transactionContext(t);
      // C8 D22a: the same exclusion test the engine applies to the reward.
      const { excluded: spendExcluded } = capPlan(v2, directory, ctx);
      const entries = milestoneEntries(v2, ctx, { excluded: spendExcluded })
        .filter((e) => milestoneRows.has(key(e.id, e.start)));
      for (const e of entries) milestoneRows.get(key(e.id, e.start)).qualified_spend += e.delta;
      newMilestoneEntries.set(String(t.id), entries);
    }
  }

  // --- records ----------------------------------------------------------------
  const recordUpdates = [];
  for (const t of ordered) {
    const id = String(t.id);
    if (excluded.has(id)) continue;
    const old = t.card_state_v2 && typeof t.card_state_v2 === 'object' ? t.card_state_v2 : null;
    const eligible = isEligible(t);
    const sections = {};
    for (const name of RECORD_SECTIONS) sections[name] = arr(old && old[name]);
    // Replayed spends get their new entries; rows that no longer count
    // (ignored, moved, backfill) lose the entries the rebuild supersedes.
    if (caps && (newCapEntries.has(id) || !eligible)) {
      sections.caps = sections.caps.filter((e) => !supersededCapEntry(e));
      if (eligible) sections.caps = sections.caps.concat(newCapEntries.get(id));
    }
    if (milestoneRows.size > 0 && (newMilestoneEntries.has(id) || !eligible)) {
      sections.milestones = sections.milestones.filter((e) => !supersededMilestoneEntry(e));
      if (eligible) sections.milestones = sections.milestones.concat(newMilestoneEntries.get(id));
    }
    const next = toRecord(v2.userCardId, sections);
    if (canonical(next) !== canonical(old)) recordUpdates.push({ id: t.id, record: next });
  }

  // --- rows and diff ------------------------------------------------------------
  const plannedCaps = [...capRows.values()]
    .map((r) => ({ ...r, consumed: round2(r.consumed), cap_amount: r.cap_amount == null ? null : round2(r.cap_amount) }))
    .filter((r) => r.consumed > 0);
  const plannedMilestones = [...milestoneRows.values()]
    .map((r) => ({ ...r, qualified_spend: round2(r.qualified_spend) }))
    .filter((r) => r.qualified_spend > 0);

  const diff = { caps: [], milestones: [], transactions: [] };
  const plannedCapByKey = new Map(plannedCaps.map((r) => [key(r.cap_rule_id, r.period_start), r]));
  const existingCaps = new Map();
  const capsToDelete = [];
  for (const r of arr(existingCapRows)) {
    const start = calendarDay(r.period_start);
    const k = key(r.cap_rule_id, start);
    existingCaps.set(k, r);
    // An overlapping row the rebuild doesn't produce (a period that moved) goes.
    if (caps && !capRows.has(k) && v2.capById.has(r.cap_rule_id)
        && start <= caps.end && calendarDay(r.period_end) >= caps.start) {
      capsToDelete.push({ cap_rule_id: r.cap_rule_id, period_start: start });
      diff.caps.push({
        cap_rule_id: r.cap_rule_id, period_start: start,
        before: { consumed: num(r.consumed), cap_kind: r.cap_kind ?? null }, after: null,
      });
    }
  }
  for (const [k, slot] of capRows) {
    const before = existingCaps.get(k) || null;
    const after = plannedCapByKey.get(k) || null;
    if (!before && !after) continue;
    if (before && !after) capsToDelete.push({ cap_rule_id: slot.cap_rule_id, period_start: slot.period_start });
    const same = before && after && sameNumber(before.consumed, after.consumed)
      && (before.cap_kind ?? null) === after.cap_kind && sameNumber(before.cap_amount, after.cap_amount)
      && Boolean(before.approximate_window) === after.approximate_window
      && calendarDay(before.period_end) === after.period_end;
    if (!same) {
      diff.caps.push({
        cap_rule_id: slot.cap_rule_id, period_start: slot.period_start,
        before: before ? { consumed: num(before.consumed), cap_kind: before.cap_kind ?? null } : null,
        after: after ? { consumed: after.consumed, cap_kind: after.cap_kind } : null,
      });
    }
  }
  const plannedMilestoneByKey = new Map(plannedMilestones.map((r) => [key(r.milestone_rule_id, r.period_start), r]));
  const existingMilestones = new Map();
  const milestonesToDelete = [];
  for (const r of arr(existingMilestoneRows)) {
    const start = calendarDay(r.period_start);
    const w = milestoneWindowById.get(r.milestone_rule_id);
    // Only rows overlapping a rebuilt window are in scope; older periods are history.
    if (!w || start > w.end || calendarDay(r.period_end) < w.start) continue;
    const k = key(r.milestone_rule_id, start);
    existingMilestones.set(k, r);
    if (!milestoneRows.has(k)) {
      milestonesToDelete.push({ milestone_rule_id: r.milestone_rule_id, period_start: start });
      diff.milestones.push({
        milestone_rule_id: r.milestone_rule_id, period_start: start,
        before: { qualified_spend: num(r.qualified_spend) }, after: null,
      });
    }
  }
  for (const [k, slot] of milestoneRows) {
    const before = existingMilestones.get(k) || null;
    const after = plannedMilestoneByKey.get(k) || null;
    if (!before && !after) continue;
    if (before && !after) milestonesToDelete.push({ milestone_rule_id: slot.milestone_rule_id, period_start: slot.period_start });
    const same = before && after && sameNumber(before.qualified_spend, after.qualified_spend)
      && Boolean(before.approximate_window) === after.approximate_window
      && calendarDay(before.period_end) === after.period_end;
    if (!same) {
      diff.milestones.push({
        milestone_rule_id: slot.milestone_rule_id, period_start: slot.period_start,
        before: before ? { qualified_spend: num(before.qualified_spend) } : null,
        after: after ? { qualified_spend: after.qualified_spend } : null,
      });
    }
  }
  for (const u of expectedUpdates) {
    diff.transactions.push({ id: u.id, before: u.before, after: { native: u.native, value: u.value } });
  }

  return {
    userCardId: v2.userCardId,
    range,
    capRows: plannedCaps,
    capsToDelete,
    milestoneRows: plannedMilestones,
    milestonesToDelete,
    txnRecordUpdates: recordUpdates,
    txnExpectedUpdates: expectedUpdates,
    diff,
  };
}

// Days are India calendar days (C8 D23c); rows are the card owner's only (D23e).
const TXN_SELECT = `SELECT id, amount_inr, occurred_at, category_id, merchant_name, merchant_vpa, mcc, rail,
       status, instrument, entry_kind, is_backfill, expected_points, expected_value_inr,
       expected_cashback_inr, card_state_v2
  FROM transactions
 WHERE user_card_id = $1 AND profile_id = $4
   AND occurred_at >= ($2::date::timestamp AT TIME ZONE 'Asia/Kolkata')
   AND occurred_at < (($3::date + 1)::timestamp AT TIME ZONE 'Asia/Kolkata')
   AND (card_state_v2 IS NOT NULL
        OR (status = 'active' AND instrument = 'credit_card' AND entry_kind = 'spend'
            AND COALESCE(is_backfill, false) = false))
 ORDER BY occurred_at ASC, id ASC`;

/**
 * C8 D23f: the first day the card can have spends — the earlier of
 * opened_on and its first transaction (India day); null when neither exists.
 */
async function cardFloorDay(client, v2) {
  const first = await client.query(
    `SELECT to_char(min(occurred_at) AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD') AS day
       FROM transactions WHERE user_card_id = $1 AND profile_id = $2`,
    [v2.userCardId, v2.profileId],
  );
  const firstDay = first.rows[0] && first.rows[0].day;
  if (v2.openedOn && firstDay) return minDay(v2.openedOn, firstDay);
  return v2.openedOn || firstDay || null;
}

/** Reads what a rebuild needs and plans it (no writes). */
async function planCardRebuild(client, v2, opts = {}) {
  const floor = await cardFloorDay(client, v2);
  const range = rebuildRange(v2, { ...opts, floor: floor || dayOf(opts.asOf || new Date()) });
  if (range.loadFrom == null) {
    return planReplay({ v2, directory: null, range, transactions: [] });
  }
  const directory = await loadDirectoryCached(client);
  const transactions = await client.query(TXN_SELECT, [v2.userCardId, range.loadFrom, range.loadTo, v2.profileId]);
  const existingCapRows = range.caps
    ? (await client.query(
      `SELECT cap_rule_id, to_char(period_start, 'YYYY-MM-DD') AS period_start,
              to_char(period_end, 'YYYY-MM-DD') AS period_end, consumed, cap_kind, cap_amount, approximate_window
         FROM cap_states
        WHERE user_card_id = $1 AND profile_id = $4 AND period_start <= $3::date AND period_end >= $2::date`,
      [v2.userCardId, range.caps.start, range.caps.end, v2.profileId],
    )).rows
    : [];
  const existingMilestoneRows = range.milestones.length > 0
    ? (await client.query(
      `SELECT milestone_rule_id, to_char(period_start, 'YYYY-MM-DD') AS period_start,
              to_char(period_end, 'YYYY-MM-DD') AS period_end, qualified_spend, approximate_window
         FROM milestone_states
        WHERE user_card_id = $1 AND profile_id = $3 AND milestone_rule_id = ANY($2::uuid[])`,
      [v2.userCardId, range.milestones.map((w) => w.id), v2.profileId],
    )).rows
    : [];
  return planReplay({
    v2, directory, range, transactions: transactions.rows, expected: Boolean(opts.expected),
    excludeTxnIds: opts.excludeTxnIds || [], existingCapRows, existingMilestoneRows,
  });
}

/** Writes a plan: only what differs, so a second run changes nothing. */
async function applyCardRebuild(client, userId, v2, plan) {
  const changedCaps = new Set(plan.diff.caps.map((d) => key(d.cap_rule_id, d.period_start)));
  for (const r of plan.capRows) {
    if (!changedCaps.has(key(r.cap_rule_id, r.period_start))) continue;
    await client.query(
      `INSERT INTO cap_states
         (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed,
          cap_value_snapshot, cap_kind, cap_amount, approximate_window)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       ON CONFLICT (user_card_id, cap_rule_id, period_start)
       DO UPDATE SET period_end = EXCLUDED.period_end, consumed = EXCLUDED.consumed,
                     cap_value_snapshot = EXCLUDED.cap_value_snapshot, cap_kind = EXCLUDED.cap_kind,
                     cap_amount = EXCLUDED.cap_amount, approximate_window = EXCLUDED.approximate_window,
                     updated_at = now()`,
      [userId, v2.userCardId, r.cap_rule_id, r.period_start, r.period_end, r.consumed,
        r.cap_value_snapshot, r.cap_kind, r.cap_amount, r.approximate_window],
    );
  }
  for (const r of plan.capsToDelete) {
    await client.query(
      `DELETE FROM cap_states WHERE user_card_id = $1 AND cap_rule_id = $2 AND period_start = $3 AND profile_id = $4`,
      [v2.userCardId, r.cap_rule_id, r.period_start, userId],
    );
  }
  const changedMilestones = new Set(plan.diff.milestones.map((d) => key(d.milestone_rule_id, d.period_start)));
  for (const r of plan.milestoneRows) {
    if (!changedMilestones.has(key(r.milestone_rule_id, r.period_start))) continue;
    await client.query(
      `INSERT INTO milestone_states
         (profile_id, user_card_id, milestone_rule_id, period_start, period_end, qualified_spend, approximate_window)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (user_card_id, milestone_rule_id, period_start)
       DO UPDATE SET period_end = EXCLUDED.period_end, qualified_spend = EXCLUDED.qualified_spend,
                     approximate_window = EXCLUDED.approximate_window, updated_at = now()`,
      [userId, v2.userCardId, r.milestone_rule_id, r.period_start, r.period_end, r.qualified_spend, r.approximate_window],
    );
  }
  for (const r of plan.milestonesToDelete) {
    await client.query(
      `DELETE FROM milestone_states
        WHERE user_card_id = $1 AND milestone_rule_id = $2 AND period_start = $3 AND profile_id = $4`,
      [v2.userCardId, r.milestone_rule_id, r.period_start, userId],
    );
  }
  for (const u of plan.txnRecordUpdates) {
    await client.query(
      `UPDATE transactions SET card_state_v2 = $3::jsonb, updated_at = now() WHERE id = $1 AND profile_id = $2`,
      [u.id, userId, u.record ? JSON.stringify(u.record) : null],
    );
  }
  for (const u of plan.txnExpectedUpdates) {
    await client.query(
      `UPDATE transactions
          SET expected_points = $3, expected_value_inr = $4, expected_cashback_inr = $5, updated_at = now()
        WHERE id = $1 AND profile_id = $2`,
      [u.id, userId, u.native, u.value, u.cashback],
    );
    // The estimated earn row follows the transaction; confirmed rows are left alone.
    await client.query(
      `DELETE FROM points_ledger
        WHERE transaction_id = $1 AND profile_id = $2 AND reason = $3 AND state = 'estimated'`,
      [u.id, userId, LEDGER_REASON],
    );
    for (const row of ledgerRows(u)) {
      await client.query(
        `INSERT INTO points_ledger (profile_id, user_card_id, transaction_id, delta_points, reason, state, occurred_at)
         VALUES ($1, $2, $3, $4, $5, 'estimated', $6)`,
        [userId, v2.userCardId, u.id, row.delta, row.reason, u.occurred_at],
      );
    }
  }
  return {
    capRows: plan.diff.caps.length,
    milestoneRows: plan.diff.milestones.length,
    records: plan.txnRecordUpdates.length,
    expected: plan.txnExpectedUpdates.length,
  };
}

async function rebuildCardState(client, userId, v2, opts = {}) {
  const plan = await planCardRebuild(client, v2, opts);
  const written = await applyCardRebuild(client, userId, v2, plan);
  return { plan, written };
}

// ---------------------------------------------------------------------------
// Fee waivers (C8 D33b): rebuilt by recompute_card_state.js
//
// A forced catalogue re-import deletes and re-creates fee_waiver_rules, and
// fee_waiver_states cascades away with them. The recompute replays each
// rule's CURRENT period over the card's spends with exactly the maths the
// live path uses (v1's periodBounds keyed by the spend's own period, the
// rule's excluded categories, the raw amount; on a v2 card also the D22a
// exclusion), then settles waived_at. Earlier periods are history and are
// not rebuilt. Statement-cycle rules get the same approximation the live
// path uses (v1's statement-cycle bounds), never a wider window.
// ---------------------------------------------------------------------------

const FEE_WINDOW_MARGIN_DAYS = 5; // v1's statement-cycle bounds can end up to 3 days before a spend in them

/** Each rule's current window as the live path keys it: v1's periodBounds on the UTC day of `asOf`. */
function feeWaiverWindows(rules, asOf, statementDay) {
  const ref = asOf instanceof Date ? asOf : new Date(asOf);
  return arr(rules).map((rule) => ({ rule, ...periodBounds(rule.period, ref, { statementDay }) }));
}

function isEligibleSpend(t) {
  return t.status === 'active' && t.instrument === 'credit_card' && t.entry_kind === 'spend' && t.is_backfill !== true;
}

/**
 * Pure. `windows` from feeWaiverWindows; `transactions` the card's rows
 * around them; `excludedOf(t)` the engine's exclusion on a v2 card (null on
 * v1). Returns the rebuilt rows, the rows to write (changed amount or
 * waiver), and — when `userCardId` is given (v2) — record updates for the
 * fee_waivers section.
 */
function planFeeWaivers({
  windows, transactions, statementDay = null, excludedOf = null, existingRows = [], userCardId = null,
}) {
  const totals = new Map(windows.map((w) => [key(w.rule.id, w.start), 0]));
  const recordUpdates = [];
  const ordered = [...arr(transactions)].sort((a, b) => new Date(a.occurred_at) - new Date(b.occurred_at)
    || (String(a.id) < String(b.id) ? -1 : 1));
  for (const t of ordered) {
    const entries = [];
    if (isEligibleSpend(t) && !(excludedOf && excludedOf(t))) {
      for (const w of windows) {
        const own = periodBounds(w.rule.period, new Date(t.occurred_at), { statementDay });
        if (own.start !== w.start) continue;
        if (t.category_id && arr(w.rule.excluded_categories).includes(t.category_id)) continue;
        const delta = round2(Number(t.amount_inr));
        totals.set(key(w.rule.id, w.start), totals.get(key(w.rule.id, w.start)) + delta);
        entries.push({ id: w.rule.id, start: w.start, end: w.end, delta });
      }
    }
    if (userCardId) {
      const old = t.card_state_v2 && typeof t.card_state_v2 === 'object' ? t.card_state_v2 : null;
      const sections = {};
      for (const name of RECORD_SECTIONS) sections[name] = arr(old && old[name]);
      sections.fee_waivers = sections.fee_waivers.filter((e) => !totals.has(key(e.id, e.start))).concat(entries);
      const next = toRecord(userCardId, sections);
      if (canonical(next) !== canonical(old)) recordUpdates.push({ id: t.id, record: next });
    }
  }

  const existing = new Map(arr(existingRows).map((r) => [key(r.fee_waiver_rule_id, calendarDay(r.period_start)), r]));
  const rows = [];
  const toWrite = [];
  const diff = [];
  for (const w of windows) {
    const k = key(w.rule.id, w.start);
    const qualified = round2(totals.get(k));
    const threshold = num(w.rule.threshold_spend_inr) ?? 0;
    const row = {
      fee_waiver_rule_id: w.rule.id, period_start: w.start, period_end: w.end,
      qualified_spend: qualified, threshold, waived: qualified >= threshold,
    };
    rows.push(row);
    const before = existing.get(k) || null;
    if (!before && qualified === 0) continue;
    const same = before && sameNumber(before.qualified_spend, qualified)
      && Boolean(before.waived_at) === row.waived && calendarDay(before.period_end) === w.end;
    if (same) continue;
    toWrite.push(row);
    diff.push({
      fee_waiver_rule_id: w.rule.id, period_start: w.start,
      before: before ? { qualified_spend: num(before.qualified_spend), waived: Boolean(before.waived_at) } : null,
      after: { qualified_spend: qualified, waived: row.waived },
    });
  }
  return { rows, toWrite, diff, recordUpdates };
}

/**
 * Reads and plans the fee-waiver rebuild for one user card (v1 or v2), or
 * null when its product has no fee-waiver rules. `card` is
 * `{ userCardId, profileId, cardProductId, statementDay }`; pass the loaded
 * v2 card for a v2-shaped one (adds the D22a exclusion and record updates).
 */
async function planFeeWaiverRebuild(client, card, { asOf = new Date(), v2 = null } = {}) {
  const rules = await client.query(
    `SELECT id, threshold_spend_inr, period, excluded_categories FROM fee_waiver_rules
      WHERE card_product_id = $1 ORDER BY id`,
    [card.cardProductId],
  );
  if (rules.rows.length === 0) return null;
  const windows = feeWaiverWindows(rules.rows, asOf, card.statementDay);
  const from = windows.reduce((d, w) => minDay(d, w.start), windows[0].start);
  const to = windows.reduce((d, w) => maxDay(d, w.end), windows[0].end);
  const transactions = await client.query(
    `SELECT id, amount_inr, occurred_at, category_id, merchant_name, merchant_vpa, mcc, rail,
            status, instrument, entry_kind, is_backfill, card_state_v2
       FROM transactions
      WHERE user_card_id = $1 AND profile_id = $2
        AND occurred_at >= (($3::date - $5::int)::timestamp AT TIME ZONE 'UTC')
        AND occurred_at < (($4::date + $5::int + 1)::timestamp AT TIME ZONE 'UTC')
        AND (card_state_v2 IS NOT NULL
             OR (status = 'active' AND instrument = 'credit_card' AND entry_kind = 'spend'
                 AND COALESCE(is_backfill, false) = false))
      ORDER BY occurred_at ASC, id ASC`,
    [card.userCardId, card.profileId, from, to, FEE_WINDOW_MARGIN_DAYS],
  );
  const existing = await client.query(
    `SELECT fee_waiver_rule_id, to_char(period_start, 'YYYY-MM-DD') AS period_start,
            to_char(period_end, 'YYYY-MM-DD') AS period_end, qualified_spend, waived_at
       FROM fee_waiver_states
      WHERE user_card_id = $1 AND profile_id = $2 AND fee_waiver_rule_id = ANY($3::uuid[])`,
    [card.userCardId, card.profileId, rules.rows.map((r) => r.id)],
  );
  let excludedOf = null;
  if (v2) {
    const directory = await loadDirectoryCached(client);
    excludedOf = (t) => capPlan(v2, directory, transactionContext(t)).excluded;
  }
  return planFeeWaivers({
    windows, transactions: transactions.rows, statementDay: card.statementDay, excludedOf,
    existingRows: existing.rows, userCardId: v2 ? v2.userCardId : null,
  });
}

/** Writes a fee-waiver plan: absolute qualified spend, then waived_at settled as the live path does. */
async function applyFeeWaiverRebuild(client, userId, card, plan) {
  for (const r of plan.toWrite) {
    const upserted = await client.query(
      `INSERT INTO fee_waiver_states (profile_id, user_card_id, fee_waiver_rule_id, period_start, period_end, qualified_spend)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (user_card_id, fee_waiver_rule_id, period_start)
       DO UPDATE SET qualified_spend = EXCLUDED.qualified_spend, period_end = EXCLUDED.period_end, updated_at = now()
       RETURNING ${FEE_WAIVER_STATE_RETURNING}`,
      [userId, card.userCardId, r.fee_waiver_rule_id, r.period_start, r.period_end, r.qualified_spend],
    );
    await settleFeeWaiver(client, upserted.rows[0], r.threshold);
  }
  for (const u of plan.recordUpdates) {
    await client.query(
      `UPDATE transactions SET card_state_v2 = $3::jsonb, updated_at = now() WHERE id = $1 AND profile_id = $2`,
      [u.id, userId, u.record ? JSON.stringify(u.record) : null],
    );
  }
  return { rows: plan.toWrite.length, records: plan.recordUpdates.length };
}

/**
 * index.js's reconcileCurrentCapStates hook: for a v2-shaped card, rebuild
 * the current cap periods in native units (and the records that back them);
 * null for a v1-shaped card so the v1 repair runs unchanged. "Current" is
 * the India calendar day now (C8 D23c), not the caller's server date.
 */
async function reconcileIfV2(client, userId, userCardId) {
  const v2 = await loadV2Card(client, userCardId, { profileId: userId });
  if (!v2) return null;
  const { plan } = await rebuildCardState(client, userId, v2, { asOf: new Date(), caps: true });
  return { rebuiltCaps: plan.capRows.length };
}

// ---------------------------------------------------------------------------
// Reads for GET /user-cards
// ---------------------------------------------------------------------------

const POINTS_KINDS = ['bonus_points', 'total_points'];

/**
 * Current-period cap rows for the wallet (C8 D22c).
 *   - `consumed` keeps its v1 meaning for installed apps (H1): for a points
 *     kind it is native consumption × point_value_inr (₹ reward value, 2 dp);
 *     for ₹, spend and count kinds, and for v1 rows, it is as stored.
 *   - `consumed_native` is the stored native figure, null on a v1 row
 *     (`cap_kind` null) so v2 clients can tell the two apart.
 *   - `cap_kind`, `cap_amount` (native), `period_start` / `period_end`
 *     ('YYYY-MM-DD') and `approximate_window`.
 * "Current" is the India calendar day of `now` for v2 rows (their windows
 * are IST, C8 D23c) and the database's CURRENT_DATE for v1 rows, as before.
 * Rows are the signed-in owner's only (C8 D23e; RLS does the same).
 */
async function currentCapStates(client, userCardId, { now = new Date() } = {}) {
  const result = await client.query(
    `SELECT cs.cap_rule_id,
            CASE WHEN cs.cap_kind = ANY($2::text[])
                 THEN round(cs.consumed * COALESCE(cp.point_value_inr, 0), 2)
                 ELSE cs.consumed END AS consumed,
            CASE WHEN cs.cap_kind IS NULL THEN NULL ELSE cs.consumed END AS consumed_native,
            cs.cap_value_snapshot, cs.cap_kind, cs.cap_amount,
            to_char(cs.period_start, 'YYYY-MM-DD') AS period_start,
            to_char(cs.period_end, 'YYYY-MM-DD') AS period_end, cs.approximate_window
       FROM cap_states cs
       JOIN user_cards uc ON uc.id = cs.user_card_id
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE cs.user_card_id = $1
        AND cs.profile_id = pandapay.uid()
        AND cs.period_start <= CASE WHEN cs.cap_kind IS NULL THEN CURRENT_DATE ELSE $3::date END
        AND cs.period_end >= CASE WHEN cs.cap_kind IS NULL THEN CURRENT_DATE ELSE $3::date END`,
    [userCardId, POINTS_KINDS, istDay(now)],
  );
  return result.rows;
}

/**
 * Current-period milestone rows; `period_end` keeps its existing encoding,
 * `period_start` is 'YYYY-MM-DD'. "Current" is the India day of `now` on a
 * v2-shaped card (C8 D23c) and CURRENT_DATE on a v1 card, as before; `v2`
 * may be passed when the caller already knows the card's shape.
 */
async function currentMilestoneStates(client, userCardId, { now = new Date(), v2 = null } = {}) {
  const isV2 = v2 != null ? Boolean(v2) : Boolean(await loadV2Card(client, userCardId));
  const result = await client.query(
    `SELECT milestone_rule_id, qualified_spend, period_end,
            to_char(period_start, 'YYYY-MM-DD') AS period_start, approximate_window
       FROM milestone_states
      WHERE user_card_id = $1
        AND profile_id = pandapay.uid()
        AND period_start <= CASE WHEN $2::boolean THEN $3::date ELSE CURRENT_DATE END
        AND period_end >= CASE WHEN $2::boolean THEN $3::date ELSE CURRENT_DATE END`,
    [userCardId, isV2, istDay(now)],
  );
  return result.rows;
}

module.exports = {
  // index.js hooks
  applyIfV2,
  reconcileIfV2,
  currentCapStates,
  currentMilestoneStates,
  // recording and rebuild
  loadV2Card,
  applyTransactionV2,
  reverseTransactionV2,
  rebuildCardState,
  planCardRebuild,
  applyCardRebuild,
  loadDirectoryCached,
  clearDirectoryCache,
  // pure parts (tests, the recompute script)
  buildV2Card,
  transactionContext,
  computeTransactionV2,
  milestoneEntries,
  rebuildRange,
  rebuildPeriods,
  planReplay,
  feeWaiverWindows,
  planFeeWaivers,
  planFeeWaiverRebuild,
  applyFeeWaiverRebuild,
  toRecord,
  nativeAmount,
  ledgerRows,
  capNativeAmount,
  capWindow,
  milestoneWindow,
};
