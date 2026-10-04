'use strict';

const AMOUNT_TOLERANCE_INR = 1;
const MAX_TIME_DISTANCE_MS = 36 * 60 * 60 * 1000;
const REVIEW_THRESHOLD = 0.72;

/** Sources that are different transports for the same logical channel. */
function sourceFamily(source) {
  if (source === 'sms' || source === 'sms_bulk') return 'sms';
  if (source === 'statement' || source === 'imported') return 'statement';
  return source || 'manual';
}

function normalizeMerchant(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function compareMerchants(left, right) {
  const a = normalizeMerchant(left);
  const b = normalizeMerchant(right);
  if (!a || !b) return { kind: 'missing', score: 0.06 };
  if (a === b) return { kind: 'exact', score: 0.35 };

  // Bank channels commonly decorate a merchant (AMAZONPAYIND vs AMAZON).
  // Containment is accepted only for a meaningful token; short fragments
  // such as "HP" are too collision-prone to be evidence.
  if (Math.min(a.length, b.length) >= 5 && (a.includes(b) || b.includes(a))) {
    return { kind: 'contained', score: 0.30 };
  }
  return null;
}

function asMillis(value) {
  const result = new Date(value).getTime();
  return Number.isFinite(result) ? result : null;
}

/**
 * Scores whether two rows may describe one real-world spend.
 *
 * This is deliberately conservative: contradictory card, instrument, or
 * merchant evidence rejects a match. A returned result is safe to suppress
 * temporarily because it still requires enough independent evidence to reach
 * REVIEW_THRESHOLD, and the user can reactivate it with "keep both".
 */
function evaluateDuplicate(incoming, candidate) {
  if ((incoming.entryKind || incoming.entry_kind || 'spend') !== 'spend') return null;
  if ((candidate.entryKind || candidate.entry_kind || 'spend') !== 'spend') return null;

  const incomingSource = sourceFamily(incoming.source);
  const candidateSource = sourceFamily(candidate.source);
  if (incomingSource === candidateSource) return null;

  const incomingInstrument = incoming.instrument || 'credit_card';
  const candidateInstrument = candidate.instrument || 'credit_card';
  if (incomingInstrument !== candidateInstrument) return null;

  const incomingCard = incoming.userCardId ?? incoming.user_card_id ?? null;
  const candidateCard = candidate.userCardId ?? candidate.user_card_id ?? null;
  if (incomingCard && candidateCard && incomingCard !== candidateCard) return null;

  const amountDifference = Math.abs(Number(incoming.amount ?? incoming.amount_inr) - Number(candidate.amount ?? candidate.amount_inr));
  if (!Number.isFinite(amountDifference) || amountDifference > AMOUNT_TOLERANCE_INR) return null;

  const incomingTime = asMillis(incoming.occurred ?? incoming.occurred_at);
  const candidateTime = asMillis(candidate.occurred ?? candidate.occurred_at);
  if (incomingTime === null || candidateTime === null) return null;
  const timeDifferenceMs = Math.abs(incomingTime - candidateTime);
  if (timeDifferenceMs > MAX_TIME_DISTANCE_MS) return null;

  const merchants = compareMerchants(
    incoming.merchantName ?? incoming.merchant_name,
    candidate.merchantName ?? candidate.merchant_name,
  );
  if (!merchants) return null;

  let score = amountDifference < 0.005 ? 0.24 : 0.20;
  score += merchants.score;
  if (incomingCard && candidateCard) score += 0.20;
  else if (incomingCard || candidateCard) score += 0.05;

  if (timeDifferenceMs <= 10 * 60 * 1000) score += 0.25;
  else if (timeDifferenceMs <= 2 * 60 * 60 * 1000) score += 0.20;
  else if (timeDifferenceMs <= 24 * 60 * 60 * 1000) score += 0.12;
  else score += 0.08;
  score += 0.05; // independent-source evidence
  score = Math.min(0.999, Number(score.toFixed(3)));

  if (score < REVIEW_THRESHOLD) return null;
  return {
    score,
    amountDifference: Number(amountDifference.toFixed(2)),
    timeDifferenceMinutes: Math.round(timeDifferenceMs / 60000),
    merchantMatch: merchants.kind,
    sourceFamilies: [candidateSource, incomingSource],
    reason: [
      `amount within INR ${amountDifference.toFixed(2)}`,
      `merchant ${merchants.kind}`,
      incomingCard && candidateCard ? 'same card' : 'card unavailable on one channel',
      `${Math.round(timeDifferenceMs / 60000)} minutes apart`,
      `${candidateSource}+${incomingSource}`,
    ].join('; '),
  };
}

function bestDuplicate(incoming, candidates) {
  return candidates
    .map((candidate) => ({ candidate, match: evaluateDuplicate(incoming, candidate) }))
    .filter((item) => item.match)
    .sort((left, right) =>
      right.match.score - left.match.score
      || left.match.timeDifferenceMinutes - right.match.timeDifferenceMinutes
    )[0] || null;
}

module.exports = {
  AMOUNT_TOLERANCE_INR,
  MAX_TIME_DISTANCE_MS,
  REVIEW_THRESHOLD,
  sourceFamily,
  normalizeMerchant,
  compareMerchants,
  evaluateDuplicate,
  bestDuplicate,
};
