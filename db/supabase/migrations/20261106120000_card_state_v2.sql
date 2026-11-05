-- Card Rewards Phase 1, WP8 — server recording v2 (plan C3.6, C3.7; C8 D15f).
--
-- Additive only (plan H3): every new column is nullable or has a constant
-- default, so the previous server version keeps working against this schema
-- during rollout and nothing is rewritten.
--
-- cap_states.cap_kind
--   v2-shaped cards record `consumed` in the cap's NATIVE unit: points for
--   *_points, rupees for *_cashback and eligible_spend, a count for
--   txn_count. cap_kind says which, so a reader never mistakes points for
--   rupees (C8 D15f). NULL means the row was written by the v1 path and
--   `consumed` is in the v1 cap measure (reward value / spend / count).
-- cap_states.cap_amount
--   The native cap amount when the row was written (cap_value_snapshot keeps
--   its v1 meaning).
-- cap_states.approximate_window / milestone_states.approximate_window
--   The window was measured from an approximate anchor (the date the card
--   was added, C3.7), or is a statement cycle with no known statement day.
-- transactions.card_state_v2
--   What this transaction added to v2 card state: one entry per cap,
--   milestone and fee-waiver row (rule id, period, delta). Reversal subtracts
--   exactly these entries, so an edit or ignore mirrors the original apply
--   even when several caps and parent caps moved.

alter table cap_states
  add column if not exists cap_kind           text,
  add column if not exists cap_amount         numeric(14,2),
  add column if not exists approximate_window boolean not null default false;

alter table cap_states drop constraint if exists cap_states_cap_kind_known;
alter table cap_states
  add constraint cap_states_cap_kind_known
    check (cap_kind is null or cap_kind in
      ('bonus_points','total_points','bonus_cashback','total_cashback','eligible_spend','txn_count'));

alter table milestone_states
  add column if not exists approximate_window boolean not null default false;

alter table transactions
  add column if not exists card_state_v2 jsonb;
