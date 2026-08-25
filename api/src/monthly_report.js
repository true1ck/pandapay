const rewardMath = require('./reward_math');

/**
 * The monthly savings report: what the user's wallet earned, what a single
 * card would have earned, and what a perfect month would have earned.
 *
 * `monthly_reports` has carried `baseline_single_card_inr`,
 * `extra_earned_inr` and `value_missed_inr` since migration 0004, and all
 * three were always zero. The route that populated the table wrote a
 * literal apology into the `breakdown` column instead:
 * "baseline/value-missed not computed this pass". So the screen built on
 * top of it could only ever show total spend and total rewards — the two
 * figures that need no comparison to produce, and the two that say least.
 *
 * CAP STATE IS SIMULATED, not assumed away. Walking the month's
 * transactions in date order and tracking each hypothetical card's cap
 * consumption as it goes is what makes "you'd have earned more on card X"
 * honest: without it, every counterfactual card looks freshly-uncapped, and
 * a 5%-capped card appears to pay 5% on the entire month's spend. That
 * overstates the missed value enormously, and it overstates it most for
 * exactly the cards the app would then recommend.
 */

/**
 * Evaluates one wallet against one month of transactions.
 *
 * `cards` is `[{ card, rewardRules, capRules }]` where `card` carries the
 * base-rate and exclusion fields reward_math needs. `txns` must be ordered
 * oldest-first — cap simulation depends on it.
 *
 * Returns `{ totalValue, byCardId }`, where `byCardId` is what each card
 * earned on the transactions actually assigned to it.
 */
function evaluateWallet(cards, txns) {
  // capRuleId -> consumed so far, per card. Reset per evaluation so a
  // counterfactual run never inherits another run's consumption.
  const consumed = new Map();
  const key = (cardId, capRuleId) => `${cardId}|${capRuleId}`;

  let totalValue = 0;
  const byCardId = {};

  for (const txn of txns) {
    const entry = cards.find((c) => c.card.user_card_id === txn.user_card_id);
    if (!entry) continue; // spend on a card that is no longer in the wallet

    const ctx = {
      amount: Number(txn.amount_inr),
      categoryId: txn.category_id || null,
      merchantName: txn.merchant_name || null,
      rail: txn.rail || 'unknown',
      occurred: txn.occurred_at,
    };

    const rule = rewardMath.pickRule(entry.rewardRules, ctx);
    const capRule = rule ? rewardMath.pickCapRule(entry.capRules, rule, ctx) : null;
    const before = capRule ? (consumed.get(key(entry.card.user_card_id, capRule.id)) || 0) : 0;

    const result = rewardMath.computeTransactionReward({
      card: entry.card,
      rewardRules: entry.rewardRules,
      capRules: entry.capRules,
      capConsumedBefore: before,
      ctx,
    });

    if (capRule && result.capConsumedDelta) {
      consumed.set(key(entry.card.user_card_id, capRule.id), before + result.capConsumedDelta);
    }

    totalValue += result.valueInr;
    byCardId[txn.user_card_id] = (byCardId[txn.user_card_id] || 0) + result.valueInr;
  }

  return { totalValue, byCardId };
}

/**
 * What ONE card would have earned on the whole month's spend, on its own.
 *
 * This is the report's baseline: the "what if I'd just used one card for
 * everything" counterfactual that makes the multi-card strategy's value
 * legible. Cap state is simulated across the month, which matters more here
 * than anywhere else — a single card absorbing a month of spend hits its
 * caps early, and ignoring that would make the baseline look far better
 * than it is and the wallet's advantage look far smaller.
 */
function evaluateSingleCard(entry, txns) {
  const consumed = new Map();
  let total = 0;

  for (const txn of txns) {
    const ctx = {
      amount: Number(txn.amount_inr),
      categoryId: txn.category_id || null,
      merchantName: txn.merchant_name || null,
      rail: txn.rail || 'unknown',
      occurred: txn.occurred_at,
    };

    const rule = rewardMath.pickRule(entry.rewardRules, ctx);
    const capRule = rule ? rewardMath.pickCapRule(entry.capRules, rule, ctx) : null;
    const before = capRule ? (consumed.get(capRule.id) || 0) : 0;

    const result = rewardMath.computeTransactionReward({
      card: entry.card,
      rewardRules: entry.rewardRules,
      capRules: entry.capRules,
      capConsumedBefore: before,
      ctx,
    });

    if (capRule && result.capConsumedDelta) {
      consumed.set(capRule.id, before + result.capConsumedDelta);
    }
    total += result.valueInr;
  }
  return total;
}

/**
 * The most a perfect month could have earned: for each transaction, the
 * best card available at that moment, with every card's cap state carried
 * forward.
 *
 * Greedy per transaction rather than a global optimum. A true optimum would
 * need to consider deliberately NOT using the best card early so its cap
 * survives for a bigger purchase later — which is a scheduling problem, and
 * more importantly is not the advice the app gives in the moment. The
 * greedy figure is the one the recommender would actually have produced, so
 * it is the honest measure of what following the app perfectly would have
 * been worth.
 */
function evaluateOptimal(cards, txns) {
  const consumed = new Map();
  const kkey = (cardId, capRuleId) => `${cardId}|${capRuleId}`;
  let total = 0;
  const perTxn = [];

  for (const txn of txns) {
    const ctx = {
      amount: Number(txn.amount_inr),
      categoryId: txn.category_id || null,
      merchantName: txn.merchant_name || null,
      rail: txn.rail || 'unknown',
      occurred: txn.occurred_at,
    };

    let best = null;
    for (const entry of cards) {
      const cardId = entry.card.user_card_id;
      const rule = rewardMath.pickRule(entry.rewardRules, ctx);
      const capRule = rule ? rewardMath.pickCapRule(entry.capRules, rule, ctx) : null;
      const before = capRule ? (consumed.get(kkey(cardId, capRule.id)) || 0) : 0;

      const result = rewardMath.computeTransactionReward({
        card: entry.card,
        rewardRules: entry.rewardRules,
        capRules: entry.capRules,
        capConsumedBefore: before,
        ctx,
      });
      if (!best || result.valueInr > best.result.valueInr) {
        best = { entry, capRule, before, result };
      }
    }
    if (!best) continue;

    if (best.capRule && best.result.capConsumedDelta) {
      consumed.set(
        kkey(best.entry.card.user_card_id, best.capRule.id),
        best.before + best.result.capConsumedDelta
      );
    }
    total += best.result.valueInr;
    perTxn.push({
      transactionId: txn.id,
      bestCardId: best.entry.card.user_card_id,
      bestValueInr: best.result.valueInr,
    });
  }

  return { total, perTxn };
}

/**
 * Builds the full report for one month.
 *
 * `actualTotal` comes from the stored `expected_value_inr` sum rather than
 * being recomputed, so the report can never disagree with what Home and
 * Insights show for the same month — those read the same column.
 */
function buildMonthlyReport({ cards, txns, actualTotal, totalSpend }) {
  const optimal = evaluateOptimal(cards, txns);

  // The best single card, evaluated across the whole month on its own.
  let baseline = 0;
  let baselineCardId = null;
  for (const entry of cards) {
    const value = evaluateSingleCard(entry, txns);
    if (baselineCardId === null || value > baseline) {
      baseline = value;
      baselineCardId = entry.card.user_card_id;
    }
  }

  // Floored at zero on purpose. Floating-point drift and the greedy
  // approximation can put "optimal" a fraction below "actual"; reporting a
  // negative missed value would read as the app claiming the user did
  // better than perfect.
  const valueMissed = Math.max(0, optimal.total - actualTotal);
  const extraEarned = Math.max(0, actualTotal - baseline);

  const missedByTxn = new Map(optimal.perTxn.map((p) => [p.transactionId, p]));
  const topMissed = txns
    .map((t) => {
      const best = missedByTxn.get(t.id);
      if (!best) return null;
      const missed = best.bestValueInr - Number(t.expected_value_inr || 0);
      if (missed <= 0.01) return null;
      return {
        transactionId: t.id,
        merchantName: t.merchant_name,
        amountInr: Number(t.amount_inr),
        occurredAt: t.occurred_at,
        usedCardId: t.user_card_id,
        betterCardId: best.bestCardId,
        missedInr: missed,
      };
    })
    .filter(Boolean)
    .sort((a, b) => b.missedInr - a.missedInr)
    .slice(0, 5);

  return {
    totalSpendInr: totalSpend,
    rewardsEarnedInr: actualTotal,
    baselineSingleCardInr: baseline,
    baselineCardId,
    extraEarnedInr: extraEarned,
    valueMissedInr: valueMissed,
    optimalInr: optimal.total,
    topMissed,
  };
}

module.exports = { buildMonthlyReport, evaluateWallet, evaluateSingleCard, evaluateOptimal };
