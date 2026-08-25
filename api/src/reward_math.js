const { effectiveRatePerRupee, effectivePointsPerRupee } = require('./cycles');

/**
 * The server-side mirror of `packages/pandapay_domain`'s
 * RecommendationEngine rule-matching and cap-blending.
 *
 * WHY THIS EXISTS
 * ---------------
 * Two implementations of "what does this card pay on this spend" run in
 * this product, and they must agree:
 *
 *   - The Dart engine ranks cards BEFORE a purchase ("use this card").
 *   - This module records what was actually earned AFTER it
 *     (`transactions.expected_value_inr`, which GET /home-summary,
 *     GET /monthly-reports and every Insights "earned" figure SUM over).
 *
 * They did not agree, in two ways that both showed up as wrong money on
 * screen:
 *
 *   1. Cap matching. The engine attached a cap to its reward rule; the SQL
 *      attached it to a category with `category_id IS NULL` acting as a
 *      wildcard. A cap modelled the normal way — reward_rule_id set,
 *      category_id null — was therefore consumed by EVERY spend on the
 *      card, so a ₹50,000 rent payment silently burned a grocery cap.
 *   2. Cap blending. The recorded value was `amount × nominal rate` with no
 *      cap awareness at all, so once a cap was exhausted the app kept
 *      recording 5% on spend that earned 1%. "Rewards earned this month"
 *      over-reported, permanently and invisibly.
 *
 * Keeping the arithmetic in one module on this side, written to the same
 * rules as the Dart side, is what makes the pair testable against each
 * other (see api/test/reward_math.test.js, which asserts the shared
 * fixtures both implementations are checked against).
 *
 * All amounts here are plain JavaScript numbers in RUPEES, matching the
 * `numeric` columns pg hands back — not the Dart side's integer paise.
 */

/**
 * Lowercased and stripped to letters+digits, so a catalogue pattern written
 * as 'amazon' matches the 'AMAZON  PAY IND*ORD' a bank SMS actually
 * carries. Mirrors both the Dart engine's `_normalizeMerchant` and the
 * normalization `pandapay.dedupe_hash()` already applies.
 */
function normalizeMerchant(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** Midnight local-time on the day `value` names. */
function startOfDay(value) {
  const d = new Date(value);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/**
 * Whether a reward rule applies to this transaction at all.
 *
 * Deliberately the same predicate, in the same order, as
 * RecommendationEngine.ruleApplies in the Dart package — including the two
 * judgement calls:
 *
 *   - An unknown merchant cannot satisfy a merchant restriction (an
 *     Amazon-only rate must not pay at an unidentified merchant).
 *   - An unknown RAIL is treated as unverified rather than as a mismatch.
 *     Every SMS/email import lands with rail 'unknown' because no parser
 *     extracts it, so failing the match there would under-report the earn
 *     rate on essentially all imported spend — as wrong as over-reporting.
 *
 * `maxTxn` is intentionally not checked here: it splits the transaction
 * rather than voiding the rule. See [rewardPortions].
 */
function ruleApplies(rule, ctx) {
  if (rule.category_id != null && rule.category_id !== ctx.categoryId) return false;

  const excluded = rule.excluded_categories || [];
  if (ctx.categoryId && excluded.includes(ctx.categoryId)) return false;

  const pattern = rule.merchant_pattern;
  if (pattern && String(pattern).trim() !== '') {
    if (!ctx.merchantName) return false;
    if (!normalizeMerchant(ctx.merchantName).includes(normalizeMerchant(pattern))) return false;
  }

  const rail = ctx.rail || 'unknown';
  if (rule.rail != null && rail !== 'unknown' && rule.rail !== rail) return false;

  if (rule.min_txn_inr != null && ctx.amount < Number(rule.min_txn_inr)) return false;

  if (ctx.occurred) {
    const when = new Date(ctx.occurred);
    if (rule.effective_from && when < startOfDay(rule.effective_from)) return false;
    if (rule.effective_to) {
      // A DATE bound is inclusive of its whole final day: a rule valid "to
      // 2026-03-31" still applies at 18:00 on the 31st.
      const end = startOfDay(rule.effective_to);
      end.setDate(end.getDate() + 1);
      if (when >= end) return false;
    }
  }

  return true;
}

/** Highest-priority (lowest number) applicable rule, or null. */
function pickRule(rules, ctx) {
  const applicable = rules.filter((r) => ruleApplies(r, ctx));
  if (applicable.length === 0) return null;
  applicable.sort((a, b) => (a.priority ?? 100) - (b.priority ?? 100));
  return applicable[0];
}

/**
 * The cap governing `rule` for this transaction: attached either to the
 * rule itself or to the transaction's category.
 *
 * `category_id IS NULL` is NOT a wildcard here, which is the entire point.
 * A cap row with neither key set belongs to no rule and no category, and
 * treating it as card-wide is what let unrelated spend consume it.
 */
function pickCapRule(capRules, rule, ctx) {
  return (
    (capRules || []).find(
      (c) =>
        (c.reward_rule_id != null && c.reward_rule_id === rule.id) ||
        (c.category_id != null && c.category_id === ctx.categoryId)
    ) || null
  );
}

/** The card's everything-else rate, or 0 when the catalogue doesn't state one. */
function baseRatePerRupee(card) {
  if (!card.base_reward_unit || card.base_reward_rate == null) return 0;
  return effectiveRatePerRupee(
    card.base_reward_unit,
    Number(card.base_reward_rate),
    Number(card.point_value_inr) || 0
  );
}

function basePointsPerRupee(card) {
  if (!card.base_reward_unit || card.base_reward_rate == null) return 0;
  return effectivePointsPerRupee(card.base_reward_unit, Number(card.base_reward_rate));
}

/**
 * The unit+rate that applies once `capRule`'s cap is spent.
 *
 * A NULL `post_cap_rate` means the catalogue never stated one, which is the
 * normal case: issuers write "5% on groceries up to ₹3,000/month" and leave
 * "1% after that" implicit because the 1% is just the card's base rate.
 * Resolving null to the base rate rather than to zero is migration 0038's
 * whole subject — see that file's header.
 *
 * An explicit 0 is preserved as 0: some cards genuinely stop earning past
 * the cap, and that is a different fact from silence.
 */
function resolvePostCap(capRule, rule, card) {
  if (capRule.post_cap_rate == null) {
    return { unit: card.base_reward_unit, rate: card.base_reward_rate == null ? 0 : Number(card.base_reward_rate) };
  }
  return { unit: capRule.post_cap_unit || rule.unit, rate: Number(capRule.post_cap_rate) };
}

/**
 * Splits `amount` into the portions that earn at different rates, in the
 * same order and by the same rules as the Dart engine.
 *
 * Each portion is `{ amountInr, unit, rate, valueInr? }`. `valueInr`, when
 * present, pins that portion's rupee value exactly rather than letting it
 * be re-derived as amount×rate — needed for reward-value caps, where the
 * pre-cap portion is worth precisely the remaining headroom and
 * re-deriving it would round differently.
 *
 * `capConsumedBefore` is the cap's consumption as it stood BEFORE this
 * transaction, which is why the caller must read cap_states before
 * upserting it.
 */
function rewardPortions({ card, rule, capRule, capConsumedBefore, amount }) {
  const portions = [];
  const pointValue = Number(card.point_value_inr) || 0;
  const bonusRate = effectiveRatePerRupee(rule.unit, Number(rule.rate), pointValue);

  // Per-transaction ceiling: the portion above it earns the card's base
  // rate, not the bonus rate and not nothing. "5% on the first ₹5,000 per
  // transaction" is the wording this models.
  const maxTxn = rule.max_txn_inr == null ? null : Number(rule.max_txn_inr);
  const bonusEligible = maxTxn != null && amount > maxTxn ? maxTxn : amount;
  const overMax = amount - bonusEligible;

  let capConsumedDelta = 0;

  if (!capRule) {
    portions.push({ amountInr: bonusEligible, unit: rule.unit, rate: Number(rule.rate) });
  } else {
    const capValue = Number(capRule.cap_value);
    const consumed = Number(capConsumedBefore) || 0;
    const remaining = Math.max(0, capValue - consumed);
    const post = resolvePostCap(capRule, rule, card);

    if (capRule.measure === 'spend_amount') {
      const preCap = Math.min(bonusEligible, remaining);
      const postCap = bonusEligible - preCap;
      if (preCap > 0) portions.push({ amountInr: preCap, unit: rule.unit, rate: Number(rule.rate) });
      if (postCap > 0) portions.push({ amountInr: postCap, unit: post.unit, rate: post.rate });
      // Only bonus-eligible spend consumes a spend cap — the over-ceiling
      // remainder never earned the capped rate, so it never touched it.
      capConsumedDelta = bonusEligible;
    } else if (capRule.measure === 'reward_value') {
      if (remaining <= 0 || bonusRate <= 0) {
        // No headroom (or a rule that can't consume value headroom at all,
        // e.g. a flat-points bonus) — the whole eligible amount is post-cap.
        if (bonusEligible > 0) {
          const p = remaining <= 0
            ? { amountInr: bonusEligible, unit: post.unit, rate: post.rate }
            : { amountInr: bonusEligible, unit: rule.unit, rate: Number(rule.rate) };
          portions.push(p);
        }
        capConsumedDelta = 0;
      } else {
        const preCapSpend = Math.min(bonusEligible, remaining / bonusRate);
        const postCapSpend = bonusEligible - preCapSpend;
        if (preCapSpend > 0) {
          portions.push({
            amountInr: preCapSpend,
            unit: rule.unit,
            rate: Number(rule.rate),
            // Pinned: the pre-cap portion is worth exactly the headroom it
            // consumed when it exhausts the cap.
            valueInr: postCapSpend > 0 ? remaining : preCapSpend * bonusRate,
          });
        }
        if (postCapSpend > 0) {
          portions.push({ amountInr: postCapSpend, unit: post.unit, rate: post.rate });
        }
        capConsumedDelta = Math.min(remaining, preCapSpend * bonusRate);
      }
    } else {
      // txn_count — a single transaction can't be split across pre/post-cap.
      const withinCount = remaining >= 1;
      portions.push(
        withinCount
          ? { amountInr: bonusEligible, unit: rule.unit, rate: Number(rule.rate) }
          : { amountInr: bonusEligible, unit: post.unit, rate: post.rate }
      );
      capConsumedDelta = 1;
    }
  }

  if (overMax > 0) {
    portions.push({ amountInr: overMax, unit: card.base_reward_unit, rate: Number(card.base_reward_rate) || 0 });
  }

  return { portions, capConsumedDelta, bonusEligible };
}

/**
 * What this transaction earns, and what it consumes.
 *
 * Returns `{ valueInr, points, capConsumedDelta, ruleId, capRuleId,
 * excluded }`. `excluded` is true when the card earns nothing at all on
 * this category — rent, wallet loads, fuel, insurance premiums and the rest
 * of the usual Indian exclusion list — in which case nothing is earned and
 * no cap is consumed, because no rule applied.
 *
 * When no rule applies but the card isn't excluded, the card's base rate
 * still earns: a 1% cashback card really does pay 1% at a pharmacy the
 * catalogue never enumerated.
 */
function computeTransactionReward({ card, rewardRules, capRules, capConsumedBefore, ctx }) {
  const pointValue = Number(card.point_value_inr) || 0;
  const empty = { valueInr: 0, points: 0, capConsumedDelta: 0, ruleId: null, capRuleId: null, excluded: false };

  const cardExcluded = (card.excluded_categories || []).includes(ctx.categoryId);
  if (ctx.categoryId && cardExcluded) {
    return { ...empty, excluded: true };
  }

  const rule = pickRule(rewardRules || [], ctx);
  if (!rule) {
    // Base-rate fallback. No rule means no cap either — a cap is always
    // attached to a rule or a category, never to the fallback.
    const rate = baseRatePerRupee(card);
    return {
      ...empty,
      valueInr: ctx.amount * rate,
      points: ctx.amount * basePointsPerRupee(card),
    };
  }

  const capRule = pickCapRule(capRules, rule, ctx);
  const { portions, capConsumedDelta } = rewardPortions({
    card,
    rule,
    capRule,
    capConsumedBefore,
    amount: ctx.amount,
  });

  let valueInr = 0;
  let points = 0;
  for (const p of portions) {
    if (!p.unit) continue; // no base rate stated -> that portion earns nothing
    valueInr += p.valueInr != null ? p.valueInr : p.amountInr * effectiveRatePerRupee(p.unit, p.rate, pointValue);
    points += p.amountInr * effectivePointsPerRupee(p.unit, p.rate);
  }

  return {
    valueInr,
    points,
    capConsumedDelta,
    ruleId: rule.id,
    capRuleId: capRule ? capRule.id : null,
    excluded: false,
  };
}

module.exports = {
  normalizeMerchant,
  ruleApplies,
  pickRule,
  pickCapRule,
  baseRatePerRupee,
  basePointsPerRupee,
  resolvePostCap,
  rewardPortions,
  computeTransactionReward,
};
