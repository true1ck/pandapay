const { periodBounds } = require('./cycles');
const rewardMath = require('./reward_math');

function dateOnly(value) {
  const date = new Date(value);
  return date.toISOString().slice(0, 10);
}

/**
 * Replays the current cap period from the canonical transaction ledger.
 *
 * This deliberately uses the same reward_math module as live transaction
 * writes. It returns cap consumption by cap-rule id and never mutates a
 * database, which keeps the repair path deterministic and testable.
 */
function replayCurrentCapConsumption({
  card,
  rewardRules,
  capRules,
  transactions,
  asOf,
}) {
  const periods = new Map(
    capRules.map((cap) => [
      cap.id,
      periodBounds(cap.period, asOf, { statementDay: card.statement_day }),
    ]),
  );
  const consumed = new Map();

  const orderedTransactions = [...transactions].sort((a, b) => {
    const time = new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime();
    return time || String(a.id).localeCompare(String(b.id));
  });

  for (const transaction of orderedTransactions) {
    const occurred = new Date(transaction.occurred_at);
    const context = {
      amount: Number(transaction.amount_inr),
      categoryId: transaction.category_id || null,
      merchantName: transaction.merchant_name || null,
      rail: transaction.rail || 'unknown',
      occurred,
    };
    const rule = rewardMath.pickRule(rewardRules, context);
    const cap = rule ? rewardMath.pickCapRule(capRules, rule, context) : null;
    if (!cap) continue;

    const period = periods.get(cap.id);
    const transactionDay = dateOnly(occurred);
    if (!period || transactionDay < period.start || transactionDay > period.end) continue;

    const before = consumed.get(cap.id) || 0;
    const result = rewardMath.computeTransactionReward({
      card,
      rewardRules,
      capRules,
      capConsumedBefore: before,
      ctx: context,
    });
    if (result.capConsumedDelta) {
      consumed.set(cap.id, before + result.capConsumedDelta);
    }
  }

  return { consumed, periods };
}

module.exports = { replayCurrentCapConsumption };
