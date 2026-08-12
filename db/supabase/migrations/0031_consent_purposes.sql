-- >>> MIGRATION 0031 — DPDP PURPOSE-SCOPED CONSENTS ==========================
--
-- Plan Phase 3.2. `user_consents` has always supported exactly three purposes
-- — 'terms', 'crowdsource', 'marketing' — recorded only as a comment on the
-- column (0004_user_domain.sql line 32), with no constraint enforcing them.
--
-- Two problems, and the second is the one that matters.
--
-- The small one: an unconstrained free-text purpose means a typo
-- ('crowdsourse') writes a consent row that no query will ever match, so a
-- user could appear to have granted something they didn't, or — worse — a
-- revocation could silently fail to revoke. For a table whose entire job is
-- to be the legal record of what someone agreed to, that is not acceptable
-- slack. The check constraint below closes it.
--
-- The real one: NONE of the three existing purposes covers what plan Phase 2
-- now makes possible. India's DPDP Act requires consent to be specific to a
-- purpose and separately revocable. "You agreed to the Terms" is not consent
-- to have your spending patterns aggregated into a product sold to a bank,
-- and 'crowdsource' — which the app describes to users as "help other users'
-- recommendations" — is consent to improve the product for other cardholders,
-- not consent to a commercial data business. Relying on either would be
-- reading a permission into words that don't contain it.
--
-- So two new purposes, both defaulting to absent (no row = no consent), both
-- independently revocable:
--
--   'aggregate_insights' — this person's data may contribute to aggregated,
--       non-identifying statistics that PandaPay may publish or license
--       (category-level effective-rate benchmarks, merchant acceptance rates).
--   'partner_sharing'    — this person's data may be shared with a named
--       commercial partner in any form.
--
-- WHAT THIS MIGRATION DOES NOT DO, and must not be read as doing: it does not
-- make monetisation lawful. It supplies the mechanism for recording specific
-- consent. Whether the wording shown to the user is adequate, whether these
-- are the right purposes, and whether the pseudonymisation in 0029 is
-- sufficient for the intended use are all questions for counsel under plan
-- Phase 3.3 — which cannot even begin while the Terms and Privacy Policy are
-- still the `[Draft — pending legal review]` placeholder text that
-- `app/lib/features/settings/legal_screen.dart` ships today.
--
-- Consequently NOTHING in the codebase reads these two purposes yet. They are
-- recorded and displayed, and no data pipeline is gated on them, because
-- there is no lawful pipeline to gate until that review happens. Wiring them
-- to a live export before then would be worse than not having them.

alter table user_consents
  drop constraint if exists user_consents_purpose_check;

alter table user_consents
  add constraint user_consents_purpose_check
  check (purpose in (
    'terms',
    'crowdsource',
    'marketing',
    'aggregate_insights',
    'partner_sharing'
  ));

comment on column user_consents.purpose is
  'What was consented to. Constrained (0031) rather than free text: this is '
  'the legal record of agreement, and a typo''d purpose would produce a row '
  'no query matches — including a revocation that then silently fails to '
  'revoke. ''aggregate_insights'' and ''partner_sharing'' are recorded but '
  'NOT yet read by any pipeline; see 0031''s header and plan Phase 3.3.';

-- A user who has never answered has no row at all, and absence means "not
-- granted" everywhere this is read. No backfill, deliberately: inserting
-- granted=false rows would fabricate a consent decision on a date the user
-- was never asked, in an append-only log whose value is that every row
-- corresponds to a real moment someone chose something.
