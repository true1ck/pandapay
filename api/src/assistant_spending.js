'use strict';

/**
 * Assistant-facing projection of a spend report.
 *
 * Keep this deliberately smaller than /spend-report: assistants only need a
 * trustworthy headline and freshness metadata, never the user's raw ledger,
 * merchant list, card identifiers, or SMS-derived observation text.
 */
function buildAssistantSpendingSummary({
  period,
  timeZone,
  bounds,
  totals,
  latestSmsObservedAt,
}) {
  return {
    period,
    timeZone,
    periodStart: bounds.start.toISOString(),
    periodEnd: bounds.end.toISOString(),
    currency: 'INR',
    totalSpendInr: totals.spend.totalInr,
    transactionCount: totals.spend.txnCount,
    rewardsInr: totals.spend.rewardsInr,
    latestSmsObservedAt: latestSmsObservedAt || null,
  };
}

module.exports = { buildAssistantSpendingSummary };
