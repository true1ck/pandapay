/**
 * User-card identity helpers shared by the add/import paths.
 *
 * A catalogue product identifies the issuer, card type and reward terms.
 * The last four digits identify the physical card. A missing last four is
 * intentionally represented as one unlinked identity: it is safe to keep
 * one placeholder, but never safe to create several indistinguishable ones.
 */
function normalizeCardLast4(value) {
  if (value === undefined || value === null) return null;
  const normalized = String(value).trim();
  return normalized === '' ? null : normalized;
}

function cardIdentityKey(cardProductId, last4) {
  return `${cardProductId}|${normalizeCardLast4(last4) || ''}`;
}

/**
 * Decide whether an add should be rejected or should enrich an existing
 * product-only placeholder. `existingCards` is plain data so this rule can
 * be tested without a database.
 */
function findCardAddConflict(existingCards, {
  cardProductId,
  last4,
  issuerId = null,
  cardType = null,
}) {
  const incomingLast4 = normalizeCardLast4(last4);
  const activeCards = existingCards.filter((card) => !card.is_archived);
  const matches = activeCards
    .filter((card) => !card.is_archived && card.card_product_id === cardProductId)
    .sort((a, b) => String(a.created_at || '').localeCompare(String(b.created_at || '')));

  // Catalogue products can change when a user corrects a card name or chooses
  // a more specific variant (for example, Tata Neu -> MoneyBack+), but the
  // physical instrument has not changed. When the issuer, instrument type,
  // and last four are all known, that identity is authoritative across
  // catalogue products. This prevents two reward engines from competing for
  // the same bank card while still allowing cards with the same suffix at a
  // different issuer or on a different instrument type.
  if (incomingLast4 !== null && issuerId && cardType) {
    const samePhysicalCard = activeCards
      .filter((card) => card.issuer_id === issuerId && card.card_type === cardType)
      .find((card) => normalizeCardLast4(card.last4) === incomingLast4);
    if (samePhysicalCard) {
      return { kind: 'already_present', userCard: samePhysicalCard, physicalIdentity: true };
    }
  }

  const exact = matches.find(
    (card) => normalizeCardLast4(card.last4) === incomingLast4,
  );
  if (exact) return { kind: 'already_present', userCard: exact };

  // A manual add without a suffix cannot be safely distinguished from an
  // existing physical card. Keep the first row as the canonical one.
  if (incomingLast4 === null) {
    return matches.length > 0 ? { kind: 'already_present', userCard: matches[0] } : null;
  }

  // Automatic discovery often learns the suffix after a user already added
  // the catalogue card manually. Enrich that one placeholder instead of
  // creating a second row. If multiple placeholders already exist, cleanup
  // has to choose the canonical row, so this path still blocks the add.
  const unlinked = matches.filter((card) => normalizeCardLast4(card.last4) === null);
  if (unlinked.length === 1) {
    return { kind: 'link_existing', userCard: unlinked[0], last4: incomingLast4 };
  }
  if (unlinked.length > 1) {
    return { kind: 'already_present', userCard: unlinked[0] };
  }

  // A different suffix is a different physical card and is allowed.
  return null;
}

module.exports = {
  normalizeCardLast4,
  cardIdentityKey,
  findCardAddConflict,
};
