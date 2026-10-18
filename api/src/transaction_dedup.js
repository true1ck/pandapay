'use strict';

const AMOUNT_TOLERANCE_INR = 0.005;
const MAX_TIME_DISTANCE_MS = 10 * 60 * 1000;
// SMS delivery timestamps distinguish a duplicated alert from two purchases
// that happen to have the same bank-supplied calendar date.
const MAX_SMS_NOTIFICATION_DISTANCE_MS = 15 * 60 * 1000;
const REVIEW_THRESHOLD = 0.72;

/** Sources that are different transports for the same logical channel. */
function sourceFamily(source) {
  if (source === 'sms' || source === 'sms_bulk') return 'sms';
  // A screenshot import is a separate transport so it can be compared with
  // a statement import for cross-source duplication, while repeated rows
  // from the same transport remain protected by their exact source key.
  if (source === 'statement') return 'statement';
  if (source === 'imported') return 'imported';
  return source || 'manual';
}

function normalizeMerchant(value) {
  return String(value || '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
}

function compareMerchants(left, right) {
  const a = normalizeMerchant(left);
  const b = normalizeMerchant(right);
  if (!a || !b || ['unknown', 'unknownmerchant', 'other', 'na'].includes(a) || ['unknown', 'unknownmerchant', 'other', 'na'].includes(b)) return { kind: 'missing', score: 0.06 };
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

// App-local row IDs and invoice numbers are not portable bank identities.
function referenceOf(row) {
  const explicit = row.bankReference ?? row.bank_reference;
  if (explicit && /^[a-z0-9-]{6,40}$/i.test(String(explicit))) return String(explicit).toUpperCase().replace(/-/g, '');
  const text = String(row.merchantName ?? row.merchant_name ?? '');
  const match = /(?:UTR|RRN|UPI\s*REF(?:ERENCE)?|(?:TXN|TRANSACTION)\s*(?:ID|REF)|REF(?:ERENCE)?(?:\s*(?:NO|NUMBER|ID))?)\s*[:#.-]?\s*([A-Z0-9][A-Z0-9-]{5,39})\b/i.exec(text);
  return match ? match[1].toUpperCase().replace(/-/g, '') : null;
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
  const incomingKind = incoming.entryKind || incoming.entry_kind || 'spend';
  const candidateKind = candidate.entryKind || candidate.entry_kind || 'spend';
  if (incomingKind !== candidateKind) return null;

  const incomingSource = sourceFamily(incoming.source);
  const candidateSource = sourceFamily(candidate.source);
  // Repeated SMS observations are intentionally one family and rely on
  // exact message identity. Screenshot files can overlap without having the
  // same file hash (for example, two cropped pages), so imported rows still
  // need row-level duplicate detection within their family.
  const incomingRef = referenceOf(incoming);
  const candidateRef = referenceOf(candidate);
  if (incomingRef && candidateRef && incomingRef !== candidateRef) return null;
  const sameReference = Boolean(incomingRef && incomingRef === candidateRef);
  // Non-spending rows such as salary credits and transfers repeat legitimately.
  // Only an exact bank reference, exact amount, and matching account can safely
  // identify a duplicate for these kinds; never fuzzy-match them by merchant/date.
  if (incomingKind !== 'spend' && !sameReference) return null;
  const sameSmsFamily = incomingSource === 'sms' && candidateSource === 'sms';
  if (incomingSource === candidateSource && incomingSource !== 'imported' && !sameReference && !sameSmsFamily) return null;

  const incomingInstrument = incoming.instrument || 'credit_card';
  const candidateInstrument = candidate.instrument || 'credit_card';
  if (incomingInstrument !== candidateInstrument && ![incomingInstrument, candidateInstrument].includes('other')) return null;

  const incomingCard = incoming.userCardId ?? incoming.user_card_id ?? null;
  const candidateCard = candidate.userCardId ?? candidate.user_card_id ?? null;
  if (incomingCard && candidateCard && incomingCard !== candidateCard) return null;

  const leftAccount = incoming.accountLast4 ?? incoming.source_account_last4;
  const rightAccount = candidate.accountLast4 ?? candidate.source_account_last4;
  if (leftAccount && rightAccount && leftAccount !== rightAccount) return null;

  const amountDifference = Math.abs(Number(incoming.amount ?? incoming.amount_inr) - Number(candidate.amount ?? candidate.amount_inr));
  if (!Number.isFinite(amountDifference) || amountDifference > AMOUNT_TOLERANCE_INR) return null;

  // Different alert templates for one swipe (for example a bank's initial
  // push followed by its final transaction SMS) have different body hashes.
  // They are safe to suppress only when their *delivery* times are close,
  // the amount and normalized merchant are exact, and the resolved card is
  // the same. Never use the transaction date here: many SMS formats carry a
  // date without a time, which would merge legitimate repeat purchases.
  if (sameSmsFamily && !sameReference) {
    const incomingObserved = asMillis(incoming.observedAt ?? incoming.observed_at);
    const candidateObserved = asMillis(candidate.observedAt ?? candidate.observed_at);
    const merchants = compareMerchants(
      incoming.merchantName ?? incoming.merchant_name,
      candidate.merchantName ?? candidate.merchant_name,
    );
    if (
      incomingObserved === null || candidateObserved === null ||
      Math.abs(incomingObserved - candidateObserved) > MAX_SMS_NOTIFICATION_DISTANCE_MS ||
      amountDifference >= 0.005 || merchants?.kind !== 'exact' ||
      !incomingCard || !candidateCard || incomingCard !== candidateCard
    ) return null;
    return {
      score: 0.998,
      automatic: true,
      amountDifference: 0,
      timeDifferenceMinutes: Math.round(Math.abs(incomingObserved - candidateObserved) / 60000),
      merchantMatch: 'exact',
      sourceFamilies: [candidateSource, incomingSource],
      reason: 'same SMS card, amount and merchant within 15 minutes of notification delivery',
    };
  }

  const incomingTime = asMillis(incoming.occurred ?? incoming.occurred_at);
  const candidateTime = asMillis(candidate.occurred ?? candidate.occurred_at);
  if (incomingTime === null || candidateTime === null) return null;
  const timeDifferenceMs = Math.abs(incomingTime - candidateTime);
  if (timeDifferenceMs > MAX_TIME_DISTANCE_MS && !sameReference) return null;

  const merchants = compareMerchants(
    incoming.merchantName ?? incoming.merchant_name,
    candidate.merchantName ?? candidate.merchant_name,
  );
  if (!merchants && !sameReference) return null;
  if (sameReference) {
    if (amountDifference >= 0.005) return null;
    return { score: 0.999, automatic: true, amountDifference: 0, timeDifferenceMinutes: Math.round(timeDifferenceMs / 60000), merchantMatch: merchants?.kind || 'different', sourceFamilies: [candidateSource, incomingSource], reason: 'same bank reference and exact amount; no conflicting account' };
  }

  let score = amountDifference < 0.005 ? 0.24 : 0.20;
  score += merchants.score;
  if (incomingCard && candidateCard) score += 0.20;
  else if (incomingCard || candidateCard) score += 0.05;

  if (timeDifferenceMs <= 10 * 60 * 1000) score += 0.25;
  else if (timeDifferenceMs <= 2 * 60 * 60 * 1000) score += 0.20;
  else if (timeDifferenceMs <= 24 * 60 * 60 * 1000) score += 0.12;
  else score += 0.08;
  if (incomingSource !== candidateSource) score += 0.05; // independent-source evidence
  score = Math.min(0.999, Number(score.toFixed(3)));

  if (score < REVIEW_THRESHOLD) return null;
  return {
    score,
    automatic: false,
    amountDifference: Number(amountDifference.toFixed(2)),
    timeDifferenceMinutes: Math.round(timeDifferenceMs / 60000),
    merchantMatch: merchants.kind,
    sourceFamilies: [candidateSource, incomingSource],
    reason: [
      'exact amount',
      `merchant ${merchants.kind}`,
      incomingCard && candidateCard ? 'same card' : 'card unavailable on one channel',
      `within ${Math.round(timeDifferenceMs / 60000)} minutes`,
      `${candidateSource}+${incomingSource}`,
    ].join('; '),
  };
}

function bestDuplicate(incoming, candidates) {
  const ranked = candidates
    .map((candidate) => ({ candidate, match: evaluateDuplicate(incoming, candidate) }))
    .filter((item) => item.match)
    .sort((left, right) =>
      right.match.score - left.match.score
      || left.match.timeDifferenceMinutes - right.match.timeDifferenceMinutes
    );
  const selected = ranked[0] || null;
  if (selected?.match.automatic && ranked.filter((item) => item.match.automatic).length > 1) {
    selected.match = { ...selected.match, automatic: false, reason: `${selected.match.reason}; multiple possible transactions` };
  }
  return selected;
}

module.exports = {
  AMOUNT_TOLERANCE_INR,
  MAX_TIME_DISTANCE_MS,
  MAX_SMS_NOTIFICATION_DISTANCE_MS,
  REVIEW_THRESHOLD,
  sourceFamily,
  referenceOf,
  normalizeMerchant,
  compareMerchants,
  evaluateDuplicate,
  bestDuplicate,
};
