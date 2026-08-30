-- >>> MIGRATION 0042 — card_network 'unknown' ===============================
--
-- ============================================================================
-- THE PROBLEM
-- ============================================================================
-- The CardPipeline import refuses any record whose card_product.network does
-- not resolve to exactly one known network, because card_products.network is
-- `card_network not null` and a bad value would fail the INSERT. Measured
-- against a real 148-record collection, that rejection alone threw away
-- 40 cards — 27% of everything extracted:
--
--     25  "N/A"                            extraction found no network
--     10  "null"                           same
--      1  "American Express / Mastercard"  genuinely issued on both
--      1  "Visa / RuPay"                   genuinely issued on both
--      1  "Visa,Mastercard,RuPay"          genuinely issued on all three
--      1  "multi_network"                  genuinely issued on several
--      1  "multinetwork"                   same
--
-- Refusing to guess is right. Throwing the whole card away for it is not:
-- `network` is DISPLAY METADATA. RecommendationEngine never reads it — the
-- only reference anywhere in the domain package is acquisition_engine.dart
-- passing it through to a card's presentation. A card with an unknown network
-- ranks exactly as well as one without. Blocking on it discards nine correct
-- reward rules to avoid showing one wrong logo.
--
-- ============================================================================
-- THE FIX, AND ITS GUARDRAIL
-- ============================================================================
-- Add 'unknown' to the enum so those cards can land as drafts with their
-- rules intact, and add a CHECK that no card can be PUBLISHED while it is
-- still unknown. Same shape as card_published_needs_verification (0003): the
-- draft stage is allowed to be incomplete, the published stage is not.
--
-- That pairing is the whole point. Without the constraint this would be a
-- silent downgrade that ships "unknown network" cards to devices. With it,
-- the unknown value is explicitly a REVIEW TODO that blocks publication until
-- a human resolves it — which is the same human who already has to set
-- verified_at, looking at the same card, in the same console screen.
--
-- Multi-network cards resolve to 'unknown' too, rather than to the first
-- network listed. "Visa,Mastercard,RuPay" is not a Visa card; picking Visa
-- would render a definite, wrong logo, whereas 'unknown' renders none and
-- says so. The full source string is preserved in
-- extended_data.card_product_source for the reviewer.
--
-- DEVICE SYNC CONTRACT (DB-2.7): additive. No view changes — `network` is
-- already on both export views and keeps its type. Devices can never receive
-- 'unknown' at all, because the CHECK below makes it unpublishable and
-- v_card_catalogue_export only selects published rows.

-- ---------------------------------------------------------------------------
-- Deliberately NOT inside begin/commit.
--
-- ALTER TYPE ... ADD VALUE may run inside a transaction block, but the new
-- label cannot be USED until that transaction commits. The CHECK constraint
-- below compares network::text against a string rather than casting a literal
-- to card_network, so it would in fact be safe either way — but keeping the
-- ADD VALUE as its own auto-committed statement removes the question entirely
-- and matches how psql -f runs this file (db/scripts/migrate.sh).
-- ---------------------------------------------------------------------------
alter type card_network add value if not exists 'unknown';

-- Comparing network::text keeps this constraint independent of the enum's
-- internal ordering and avoids referencing the label added above.
alter table card_products
  drop constraint if exists card_published_needs_known_network;

alter table card_products
  add constraint card_published_needs_known_network
  check (status <> 'published' or network::text <> 'unknown');

comment on constraint card_published_needs_known_network on card_products is
  'A card may sit in draft with network = ''unknown'' (the CardPipeline '
  'extraction did not resolve one, or the product is genuinely issued on '
  'several networks — the raw value is kept in '
  'extended_data.card_product_source.network). It may not be PUBLISHED '
  'that way. Publishing is the human review gate that also sets verified_at; '
  'resolving the network belongs to that same review, and this constraint is '
  'what stops an unresolved one reaching devices.';
