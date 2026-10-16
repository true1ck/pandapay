/**
 * Card discovery — "which of your cards can we recognise in this text?"
 *
 * Shared by the SMS and the email path deliberately: a bank's card name
 * appears in an alert SMS and in a statement email in the same words, so
 * running two different matchers would mean two different answers for the
 * same card. Callers supply the text; this module has no IO.
 *
 * The rule throughout is that a match must be *evidenced*. Every candidate
 * returned carries the exact substring that produced it, so the UI can show
 * the user why a card was suggested and they can dismiss a wrong one. A
 * card is never added automatically — this returns suggestions, and a human
 * confirms. That matters because the failure mode here is silently adding a
 * card someone doesn't own and then ranking against it.
 */

const { extractCreditLimit } = require('./card_limit_parser');

/**
 * Normalise for comparison: casefold, collapse whitespace, and drop
 * punctuation that varies between issuers' own spellings ("IDFC FIRST" vs
 * "IDFC-FIRST", "Amex" vs "AMEX.").
 */
function normalise(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Words too generic to be evidence on their own. Matching on these alone
 * would suggest every card in the catalogue for any bank email.
 */
const STOPWORDS = new Set([
  'card', 'cards', 'credit', 'debit', 'bank', 'the', 'a', 'an', 'of', 'and',
  'ltd', 'limited', 'india', 'indian', 'pvt', 'co', 'inr', 'rs',
  'purchase', 'mobile', 'upi', 'rupay', 'visa', 'mastercard',
  'premium', 'rewards', 'smart', 'cashback', 'save', 'plus', 'infinity',
  'wholesale', 'online', 'statement', 'payment', 'txn', 'transaction',
  'spent', 'debited', 'credited', 'account', 'acct', 'alert'
]);

/**
 * Significant tokens of a card/issuer name — what's left after stopwords.
 * A name that reduces to nothing (there is no such card today, but a future
 * catalogue row could be literally "Credit Card") yields no tokens and so
 * can never match, which is the safe direction.
 */
function significantTokens(name) {
  return normalise(name)
    .split(' ')
    .filter((t) => t.length > 1 && !STOPWORDS.has(t));
}

/**
 * A bank-account reference and its trailing digits — "A/c XX1797",
 * "Account No. XXXX 1772", "AC ...1234". Those digits are an *account*
 * suffix, never a card number, so extractLast4 strips these spans before
 * scanning: reading them as a card last-4 let debit/UPI alerts masquerade
 * as card alerts and seed placeholder cards.
 */
const ACCOUNT_NUMBER_SPAN =
  /\b(?:a\/c|ac|acct|account)\b(?:\s*(?:no\.?|number|#|ending(?:\s+(?:in|with))?))?\s*[:\-]?\s*[x*.•]*\s*\d{3,}|\bbank\s+[x*•]+\s*\d{3,}|\b(?:aadhaar|aadhar|uidai|pan|gstin)\b\s*[:\-]?\s*[x*.•]*\s*\d{3,}/gi;

/**
 * Last-4 digits mentioned in the text, e.g. "ending 4568", "XX4568",
 * "****4568". Account-number spans ("a/c ...4568") are removed first — see
 * ACCOUNT_NUMBER_SPAN. Returned for display as evidence only — this module
 * never uses them to *identify* a product (a last-4 says nothing about which
 * product it is) and the app never stores them.
 */
function extractLast4(text) {
  const cleaned = String(text || '').replace(ACCOUNT_NUMBER_SPAN, ' ');
  const hits = new Set();
  const re = /(?:ending\s+in|ending\s+with|ending|no\.?\s*x+|xx+|\*{2,}|\.{3,}|\b(?:x+|dc))\s*(\d{4})\b/gi;
  let m;
  while ((m = re.exec(cleaned)) !== null) hits.add(m[1]);
  return [...hits];
}

/**
 * Marketing / promotional SMS markers.
 *
 * A bank's own marketing blast names its card products in full ("Apply now
 * for the Tata Neu Infinity HDFC Bank Credit Card") and, left unfiltered,
 * seeds the user's wallet with every card the bank sells. SMS card
 * discovery must ignore these outright — the screenshots that motivated
 * this filter showed six HDFC cards and an SBI card all "found in your SMS"
 * from a single promotional message.
 */
const PROMO_MARKERS = [
  'apply now', 'apply today', 'pre-approved', 'pre approved', 'preapproved',
  'lifetime free', 'ltf', 'no joining fee', 'no annual fee', 'joining fee waived',
  'annual fee waived', 'exclusive offer', 'special offer', 'limited period',
  'limited time', 'click here', 'hurry', 't&c apply', 't & c apply', 'tnc apply',
  'offer ends', 'offer valid', 'get it now', 'avail now', 'you are eligible',
  "you're eligible", 'you re eligible', 'eligible for', 'now eligible',
  'congratulations', 'know more', 'unlock', 'upgrade to', 'upgrade your',
  '0% interest', 'no cost emi', 'emi offer', 'instant loan', 'personal loan',
  'redeem now', 'points expiring', 'expiring soon', 'bit.ly', 'tinyurl',
  'http://', 'https://', 'www.',
];

/** True when the text reads like a marketing message rather than an alert. */
function looksPromotionalSms(text) {
  const lower = String(text || '').toLowerCase();
  return PROMO_MARKERS.some((m) => lower.includes(m));
}

/**
 * Transaction / statement markers — the SMS shapes a card the user actually
 * holds produces. SMS card discovery is gated on one of these appearing, so
 * a card name is only trusted when it rides on a real spend or statement
 * alert.
 */
const TXN_MARKERS = [
  'spent', 'debited', 'credited', 'charged', 'txn', 'transaction', 'purchase of',
  'purchase at', ' paid ', 'used at', 'used for', 'withdrawn', 'payment of',
  'payment received', 'received on your', 'avl bal', 'available balance',
  'avl. bal', 'avl lmt', 'available limit', 'outstanding', 'statement',
  'amount due', 'due date', 'min amt due', 'total amount due', 'e-statement',
  'autopay', 'auto pay', 'auto-pay', 'has been credited', 'has been debited',
  'credit limit', 'total credit limit',
];

/** True when the text carries a real transaction/statement signal. */
function looksTransactionalSms(text) {
  const lower = String(text || '').toLowerCase();
  return TXN_MARKERS.some((m) => lower.includes(m));
}

/**
 * Account / debit-card alert markers.
 *
 * PandaPay ranks *credit* cards — a debit-card or savings-account spend
 * alert has no rewards to optimise, so the placeholder fallback ignores a
 * message that reads like one. Confident catalogue matches are unaffected
 * (they already require a card *product* name, which a debit alert never
 * carries). A genuine credit-card alert that an issuer happens to word with
 * "debited" is kept in by CREDIT_CARD_MARKERS below.
 */
const DEBIT_ACCOUNT_MARKERS = [
  'debit card', 'a/c', 'ac no', 'acct', 'account no', 'from a/c', 'to a/c',
  'savings a/c', 'salary a/c', 'imps', 'neft', 'atm', 'upi/', 'by upi',
  'vpa', 'withdrawn from', 'withdrawn rs', 'block dc', ' dc ', 'account ending',
  'deducted from', 'deposited in',
];

/**
 * Credit-card-specific markers. Their presence overrides the debit filter,
 * so a "Rs X debited from your Credit Card" alert still yields a placeholder.
 */
const CREDIT_CARD_MARKERS = [
  'credit card', 'avl lmt', 'available limit', 'avl. limit', 'credit limit',
  'outstanding', 'statement', 'min amt due', 'minimum amount due',
  'total amount due', 'amount due', 'cc bill', 'card bill', 'block cc',
  ' cc ', 'card ending with', 'available credit',
];

/** True when the text reads like a bank-account / debit-card alert. */
function looksDebitAccountSms(text) {
  const lower = String(text || '').toLowerCase();
  return DEBIT_ACCOUNT_MARKERS.some((m) => lower.includes(m));
}

/** True when the text carries an unambiguous credit-card signal. */
function looksCreditCardSms(text) {
  const lower = String(text || '').toLowerCase();
  return CREDIT_CARD_MARKERS.some((m) => lower.includes(m));
}

/** True when the message identifies a physical debit card, not an account. */
function looksDebitCardSms(text) {
  const lower = String(text || '').toLowerCase();
  return /\bdebit\s+card\b/.test(lower)
    || /\b(?:atm|cash\s+withdrawal|withdrawn\s+from\s+(?:your\s+)?(?:bank\s+)?card)\b/.test(lower)
    || /\bblock\s+dc\b/.test(lower);
}

/**
 * Scan one message for cards from `catalogue`.
 *
 * @param {{subject?: string, body?: string, sender?: string}} message
 * @param {Array<{id: string, name: string, slug?: string, issuer_name?: string, issuer_slug?: string}>} catalogue
 * @returns {Array<{cardProductId: string, name: string, score: number, evidence: string[]}>}
 *   ordered strongest first. Empty when nothing matched — never a guess.
 */
function discoverCardsInMessage(message, catalogue) {
  const haystack = normalise(
    [message?.subject, message?.body, message?.sender].filter(Boolean).join(' ')
  );
  if (!haystack) return [];
  const messageIsDebit = looksDebitCardSms(haystack);
  const messageIsCredit = looksCreditCardSms(haystack);

  // Whole-word view of the same text. A product token has to appear as a
  // WORD, not as a substring, or short card names manufacture matches out
  // of ordinary prose: "Axis Ace" was being suggested at score 1.0 from
  // routine Axis Bank emails because "ace" is inside "interface", "place"
  // and "space". That is exactly the failure this module's header says it
  // exists to prevent — a card the user doesn't own, then ranked against.
  //
  // Issuer tokens deliberately keep substring matching (below): they're
  // long and distinctive, and matching them inside a sender domain like
  // `alerts@hdfcbank.net` is genuinely useful rather than accidental.
  const haystackWords = new Set(haystack.split(' '));

  // Some issuers send only the product mark in the alert (for example
  // "MoneyBack+ xx8708" or "Flipkart card ending 7105") and put the bank
  // name in the sender/header instead. A product token is safe without the
  // issuer only when it uniquely identifies one catalogue row; family words
  // such as Tata/Neu remain ambiguous and still require the issuer.
  const productTokenOwners = new Map();
  for (const candidate of catalogue || []) {
    for (const token of significantTokens(candidate.name)) {
      if (!productTokenOwners.has(token)) productTokenOwners.set(token, new Set());
      productTokenOwners.get(token).add(candidate.id);
    }
  }

  const results = [];
  for (const card of catalogue || []) {
    // A catalogue product name can be identical across credit/debit variants.
    // Keep the SMS's explicit instrument type authoritative when the catalogue
    // supplies card_type; otherwise retain the legacy matching behaviour.
    if (card.card_type === 'debit' && messageIsCredit && !messageIsDebit) continue;
    if (card.card_type === 'credit' && messageIsDebit && !messageIsCredit) continue;
    const nameTokens = significantTokens(card.name);
    // A name that reduces to nothing but stopwords ("Credit Card") can never
    // be evidence — not even verbatim, or "your credit card statement" would
    // match it.
    if (nameTokens.length === 0) continue;

    // The full product name present verbatim is the strongest signal there
    // is; treat it as a complete match regardless of token accounting.
    const fullName = normalise(card.name);
    const exact = fullName.length > 0 && haystack.includes(fullName);

    const matchedNameTokens = nameTokens.filter((t) => haystackWords.has(t));

    const issuerTokens = significantTokens(card.issuer_name || '');
    const issuerHit = issuerTokens.length > 0 && issuerTokens.every((t) => haystack.includes(t));

    // Require either the whole product name, or the issuer PLUS a
    // distinguishing product token. An issuer alone is not enough: "HDFC
    // Bank" appears in every HDFC email and would suggest all six HDFC
    // cards at once, which is noise, not discovery.
    const distinguishing = matchedNameTokens.filter((t) => !issuerTokens.includes(t));
    const uniqueProductToken = distinguishing.some((token) => {
      if (productTokenOwners.get(token)?.size !== 1) return false;
      // A merchant name such as "Amazon" must not identify the Amazon Pay
      // card. Product-only evidence must be adjacent to card language or a
      // masked suffix ("MoneyBack+ card" / "MoneyBack+ xx8708").
      const tokenContext = new RegExp(
        `\\b${token}\\b(?:\\s+[a-z0-9]+){0,2}\\s+(?:card|ending\\b|x{2,}\\d{4}\\b)`,
      );
      return tokenContext.test(haystack);
    });
    if (!exact && !(issuerHit && distinguishing.length > 0) && !uniqueProductToken) continue;

    const evidence = exact ? [card.name] : [card.issuer_name, ...distinguishing].filter(Boolean);
    // 1.0 for a verbatim product name; otherwise how much of the
    // distinguishing part of the name we actually saw.
    // 2.0 for a verbatim product name (it stands alone as SMS evidence);
    // otherwise how much of the distinguishing part of the name we saw, in
    // (0.5, 1.0]. Ties are broken by messageCount downstream, not by nudging
    // the score.
    const score = exact
      ? 2
      : 0.5 + 0.5 * (distinguishing.length / Math.max(nameTokens.length - issuerTokens.length, 1));

    results.push({
      cardProductId: card.id,
      name: card.name,
      score,
      evidence,
      cardType: card.card_type || null,
      issuerName: card.issuer_name || null,
    });
  }

  results.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  return results;
}

/**
 * A suffix is not globally unique, but issuer + suffix + instrument type is
 * the best physical-card identity available in an SMS. Once one named
 * catalogue product wins that identity, do not present sibling products for
 * the same card. This is deliberately applied after message-level scoring so
 * an exact product name beats a weaker issuer/product-token hint.
 */
function consolidateNamedPhysicalCards(suggestions, catalogue) {
  const issuerById = new Map((catalogue || []).map((card) => [card.id, card.issuer_name || '']));
  const typeById = new Map((catalogue || []).map((card) => [card.id, card.card_type || '']));
  const winners = new Map();

  const physicalKeys = (suggestion) => {
    if (suggestion.isPlaceholder) return [];
    const issuer = normalise(suggestion.issuerName || issuerById.get(suggestion.cardProductId) || '');
    if (!issuer || !(suggestion.last4 || []).length) return [];
    const type = normalise(suggestion.cardType || typeById.get(suggestion.cardProductId) || 'unknown');
    return suggestion.last4.map((last4) => `${issuer}|${type}|${last4}`);
  };

  const stronger = (candidate, incumbent) =>
    candidate.score > incumbent.score
      || (candidate.score === incumbent.score && candidate.messageCount > incumbent.messageCount)
      || (candidate.score === incumbent.score
        && candidate.messageCount === incumbent.messageCount
        && (candidate.evidence || []).length > (incumbent.evidence || []).length);

  for (const suggestion of suggestions) {
    for (const key of physicalKeys(suggestion)) {
      const incumbent = winners.get(key);
      if (!incumbent || stronger(suggestion, incumbent)) winners.set(key, suggestion);
    }
  }

  return suggestions.flatMap((suggestion) => {
    const keys = physicalKeys(suggestion);
    if (!keys.length) return [suggestion];
    const keptLast4 = (suggestion.last4 || []).filter((last4) =>
      winners.get(`${normalise(suggestion.issuerName || issuerById.get(suggestion.cardProductId) || '')}|${normalise(suggestion.cardType || typeById.get(suggestion.cardProductId) || 'unknown')}|${last4}`)?.cardProductId === suggestion.cardProductId
    );
    return keptLast4.length ? [{ ...suggestion, last4: keptLast4 }] : [];
  });
}

/**
 * Fold many messages into one suggestion list.
 *
 * Seeing the same card across several messages is genuinely stronger
 * evidence than one mention, so `messageCount` is surfaced and used to
 * order ties — but it never manufactures a match that a single message
 * didn't already justify.
 */
function discoverCardsAcrossMessages(messages, catalogue, isSms = false) {
  const byCard = new Map();
  
  const issuers = new Set(
    (catalogue || []).map((c) => c.issuer_name).filter(Boolean)
  );

  // Pre-pass: an issuer + last-4 that appears in an account/debit alert is
  // remembered so a weaker, wordless sibling message cannot manufacture a
  // credit-card placeholder for the same number. Explicit debit-card alerts
  // still produce a debit suggestion below.
  const debitPoisoned = new Set();
  const debitCardPoisoned = new Set();
  if (isSms) {
    for (const message of messages || []) {
      const text = [message?.subject, message?.body].filter(Boolean).join(' ');
      if (looksDebitCardSms(text) && !looksCreditCardSms(text)) {
        const low = normalise(text);
        const l4s = extractLast4(text);
        for (const issuer of issuers) {
          if (!low.includes(normalise(issuer))) continue;
          const ni = normalise(issuer);
          debitCardPoisoned.add(`${ni}|`);
          for (const l of l4s) debitCardPoisoned.add(`${ni}|${l}`);
        }
      }
      const accountOnly = looksDebitAccountSms(text)
        && !looksCreditCardSms(text)
        && !looksDebitCardSms(text);
      if (!accountOnly) continue;
      const low = normalise(text);
      const l4s = extractLast4(text);
      for (const issuer of issuers) {
        if (!low.includes(normalise(issuer))) continue;
        const ni = normalise(issuer);
        debitPoisoned.add(`${ni}|`);
        for (const l of l4s) debitPoisoned.add(`${ni}|${l}`);
      }
    }
  }

  for (const message of messages || []) {
    const text = [message?.subject, message?.body].filter(Boolean).join(' ');

    // SMS discovery only: a card match is believable only when it rides on a
    // real transaction/statement alert, never a marketing blast that names
    // the bank's whole product line. The email path is unaffected — forwarded
    // mail is already sender-verified upstream.
    if (isSms && (looksPromotionalSms(text) || !looksTransactionalSms(text))) {
      continue;
    }

    const last4s = extractLast4(text);
    const creditLimit = extractCreditLimit(text);
    const explicitDebitCard = looksDebitCardSms(text);

    // SMS discovery: a card number in the SAME message is required. A real
    // spend/statement alert always carries "card ending 1234"; a marketing
    // blast that merely spells a card's name ("...Tata Neu Infinity SBI
    // Credit Card. Enjoy rewards!") does not. This is the single strongest
    // signal separating a genuine alert from noise, and the screenshots that
    // motivated this filter were entirely cards with no number.
    if (isSms && last4s.length === 0) continue;

    const hits = discoverCardsInMessage(message, catalogue);

    const confidentHits = isSms ? hits.filter(h => h.score >= 1.0) : hits;

    if (confidentHits.length > 0) {
      const maxScore = confidentHits.reduce((max, h) => (h.score > max ? h.score : max), 0);
      let topHits = confidentHits.filter(h => h.score === maxScore);

      // SMS discovery: a message that names a card *family* without pinning one
      // product ("...Tata Neu Infinity...", matching both the HDFC and the SBI
      // row equally) is ambiguous — surface nothing rather than every sibling.
      // Two rows that are really the same card described twice in the catalogue
      // (same issuer + same distinguishing tokens) are NOT ambiguous.
      if (isSms && topHits.length > 1 && maxScore < 2) {
        const signature = (h) =>
          `${normalise(h.evidence[0] || '')}|${[...h.evidence].slice(1).sort().join(',')}`;
        const distinct = new Set(topHits.map(signature));
        if (distinct.size > 1) continue;
        topHits = [topHits[0]];
      }

      for (const hit of topHits) {
        const existing = byCard.get(hit.cardProductId);
        if (existing) {
          existing.messageCount += 1;
          existing.score = Math.max(existing.score, hit.score);
          for (const e of hit.evidence) if (!existing.evidence.includes(e)) existing.evidence.push(e);
          for (const l of last4s) if (!existing.last4.includes(l)) existing.last4.push(l);
          if (existing.creditLimitInr == null && creditLimit) {
            existing.creditLimitInr = creditLimit.amountInr;
          }
        } else {
          byCard.set(hit.cardProductId, {
            ...hit,
            messageCount: 1,
            last4: [...last4s],
            creditLimitInr: creditLimit?.amountInr ?? null,
          });
        }
      }
    } else if (isSms) {
      // A bank-account/UPI alert has no physical card to rank; don't
      // manufacture a placeholder from the account suffix. An explicit
      // debit-card alert is different: surface a debit-card suggestion so the
      // user can add and track it without mixing it into credit-card rewards.
      if (looksDebitAccountSms(text) && !looksCreditCardSms(text) && !explicitDebitCard) continue;
      const placeholderCardType = explicitDebitCard ? 'debit' : 'credit';
      const placeholderLabel = explicitDebitCard ? 'Debit card' : 'Credit card';

      // Fallback for SMS: generate placeholders if no exact match found
      const haystack = normalise([message?.subject, message?.body].filter(Boolean).join(' '));
      const matchingIssuers = [...issuers].filter((issuer) =>
        haystack.includes(normalise(issuer))
      );

      // Some banks identify a physical credit card only as "your credit card
      // XX9080". There is no safe catalogue product to infer from that text,
      // but the suffix is still useful evidence: surface one generic card
      // placeholder so the user can select the matching catalogue product.
      // This is deliberately used only when no issuer is present, otherwise
      // the issuer-specific placeholder below is more helpful.
      if (matchingIssuers.length === 0 && last4s.length > 0) {
        for (const l4 of last4s) {
          // Keep debit and credit placeholders separate even when their last
          // four digits happen to be identical. A suffix is not globally
          // unique, so sharing this key would merge the two instruments and
          // make the first message's type win by accident.
          const placeholderId = explicitDebitCard
            ? `placeholder_debit_card_${l4}`
            : `placeholder_card_${l4}`;
          const existing = byCard.get(placeholderId);
          if (existing) {
            existing.messageCount += 1;
            if (existing.creditLimitInr == null && creditLimit) {
              existing.creditLimitInr = creditLimit.amountInr;
            }
          } else {
            byCard.set(placeholderId, {
              cardProductId: placeholderId,
              name: `${placeholderLabel} ending in ${l4}`,
              score: 0.1,
              evidence: [`Transaction matched card ending in ${l4}`],
              last4: [l4],
              messageCount: 1,
              isPlaceholder: true,
              cardType: placeholderCardType,
              issuerName: null,
              creditLimitInr: creditLimit?.amountInr ?? null,
            });
          }
        }
      }

      for (const issuer of matchingIssuers) {
        const normIssuer = normalise(issuer);
        const l4sToUse = last4s.length === 0 ? [''] : last4s;
        for (const l4 of l4sToUse) {
          // Skip a card this issuer was seen debiting an account for.
          if (
            !explicitDebitCard
            && (debitPoisoned.has(`${normIssuer}|${l4}`)
              || debitCardPoisoned.has(`${normIssuer}|${l4}`))
          ) continue;
          // The issuer + suffix is also not globally unique across physical
          // card types. Debit and credit suggestions must never coalesce.
          const placeholderId = explicitDebitCard
            ? `placeholder_debit_${normIssuer}_${l4}`
            : `placeholder_${normIssuer}_${l4}`;
          const existing = byCard.get(placeholderId);

          if (existing) {
            existing.messageCount += 1;
            if (existing.creditLimitInr == null && creditLimit) {
              existing.creditLimitInr = creditLimit.amountInr;
            }
          } else {
            const nameSuffix = l4 ? ` ending in ${l4}` : '';
            byCard.set(placeholderId, {
              cardProductId: placeholderId,
              name: `${issuer} Card${nameSuffix}`,
              score: 0.1,
              evidence: [`Transaction matched ${issuer}`],
              last4: l4 ? [l4] : [],
              messageCount: 1,
              isPlaceholder: true,
              cardType: placeholderCardType,
              issuerName: issuer,
              creditLimitInr: creditLimit?.amountInr ?? null,
            });
          }
        }
      }
    }
  }

  // Reconcile placeholders against the real, named cards. If a confident
  // match carries the same issuer + last-4 as a placeholder, the placeholder
  // is that same card discovered a second way — and its "pick from
  // catalogue" prompt would ask the user to identify a card we already
  // identified. Drop it.
  const issuerById = new Map((catalogue || []).map((c) => [c.id, c.issuer_name]));
  const realKeys = new Set();
  for (const s of byCard.values()) {
    if (s.isPlaceholder) continue;
    const iss = normalise(issuerById.get(s.cardProductId) || '');
    for (const l of s.last4 || []) realKeys.add(`${iss}|${l}`);
  }
  for (const [key, s] of [...byCard.entries()]) {
    if (!s.isPlaceholder) continue;
    const iss = normalise(s.issuerName || '');
    if ((s.last4 || []).some((l) => realKeys.has(`${iss}|${l}`))) byCard.delete(key);
  }

  const consolidated = consolidateNamedPhysicalCards([...byCard.values()], catalogue);

  return consolidated.sort(
    (a, b) => b.score - a.score || b.messageCount - a.messageCount || a.name.localeCompare(b.name)
  );
}

module.exports = {
  discoverCardsInMessage,
  discoverCardsAcrossMessages,
  extractLast4,
  normalise,
  significantTokens,
  looksPromotionalSms,
  looksTransactionalSms,
  looksDebitAccountSms,
  looksDebitCardSms,
  looksCreditCardSms,
};
