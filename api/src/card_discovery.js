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
 * Last-4 digits mentioned in the text, e.g. "ending 4568", "XX4568",
 * "****4568", "a/c ...4568". Returned for display as evidence only — this
 * module never uses them to *identify* a product (a last-4 says nothing
 * about which product it is) and the app never stores them.
 */
function extractLast4(text) {
  const hits = new Set();
  const re = /(?:ending|ending\s+with|xx+|\*{2,}|\.{3,})\s*(\d{4})\b/gi;
  let m;
  while ((m = re.exec(String(text || ''))) !== null) hits.add(m[1]);
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
];

/** True when the text carries a real transaction/statement signal. */
function looksTransactionalSms(text) {
  const lower = String(text || '').toLowerCase();
  return TXN_MARKERS.some((m) => lower.includes(m));
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

  const results = [];
  for (const card of catalogue || []) {
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
    if (!exact && !(issuerHit && distinguishing.length > 0)) continue;

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

    results.push({ cardProductId: card.id, name: card.name, score, evidence });
  }

  results.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  return results;
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
        } else {
          byCard.set(hit.cardProductId, { ...hit, messageCount: 1, last4: [...last4s] });
        }
      }
    } else if (isSms) {
      // Fallback for SMS: generate placeholders if no exact match found
      const haystack = normalise([message?.subject, message?.body].filter(Boolean).join(' '));
      for (const issuer of issuers) {
        const normIssuer = normalise(issuer);
        if (haystack.includes(normIssuer)) {
          const l4sToUse = last4s.length === 0 ? [''] : last4s;
          for (const l4 of l4sToUse) {
            const placeholderId = `placeholder_${normIssuer}_${l4}`;
            const existing = byCard.get(placeholderId);
            
            if (existing) {
              existing.messageCount += 1;
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
                issuerName: issuer
              });
            }
          }
        }
      }
    }
  }

  return [...byCard.values()].sort(
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
};
