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

  const results = [];
  for (const card of catalogue || []) {
    const nameTokens = significantTokens(card.name);
    if (nameTokens.length === 0) continue;

    const matchedNameTokens = nameTokens.filter((t) => haystack.includes(t));
    // The full product name present verbatim is the strongest signal there
    // is; treat it as a complete match regardless of token accounting.
    const fullName = normalise(card.name);
    const exact = fullName.length > 0 && haystack.includes(fullName);

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
    const score = exact
      ? 1
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
function discoverCardsAcrossMessages(messages, catalogue) {
  const byCard = new Map();
  for (const message of messages || []) {
    for (const hit of discoverCardsInMessage(message, catalogue)) {
      const existing = byCard.get(hit.cardProductId);
      if (existing) {
        existing.messageCount += 1;
        existing.score = Math.max(existing.score, hit.score);
        for (const e of hit.evidence) if (!existing.evidence.includes(e)) existing.evidence.push(e);
      } else {
        byCard.set(hit.cardProductId, { ...hit, messageCount: 1, last4: [] });
      }
    }
    // Attach any last-4s seen alongside a match, for display only.
    const last4 = extractLast4([message?.subject, message?.body].filter(Boolean).join(' '));
    if (last4.length > 0) {
      for (const hit of discoverCardsInMessage(message, catalogue)) {
        const entry = byCard.get(hit.cardProductId);
        if (!entry) continue;
        for (const l of last4) if (!entry.last4.includes(l)) entry.last4.push(l);
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
};
