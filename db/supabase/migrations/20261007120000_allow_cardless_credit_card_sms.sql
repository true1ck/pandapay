-- Imported card alerts can be genuine credit-card spending even when the
-- user has not added that card or its last four digits yet. The ingest code
-- deliberately retains instrument='credit_card' and user_card_id=NULL so
-- Spending does not lose payment-method evidence or drop the transaction.
-- Migration 0040 contradicted that behavior and caused those SMS imports to
-- fail at the database CHECK constraint.
--
-- Card state is still updated only when the API has a concrete user_card_id.
-- Non-card instruments remain cardless by invariant; both physical-card
-- instruments may be linked when the user has added that card.
alter table transactions drop constraint if exists transactions_card_matches_instrument;
alter table transactions add constraint transactions_card_matches_instrument check (
  instrument in ('credit_card', 'debit_card') or user_card_id is null
);
