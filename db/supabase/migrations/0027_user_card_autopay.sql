-- >>> MIGRATION 0027 — USER CARD AUTOPAY ====================================
--
-- Design 02 Wallet nudges "Autopay is off — never lose ₹500 to a late fee
-- again", and design 13 Payments due labels every upcoming statement with
-- its autopay state ("Autopay off" / "Autopay on · full amount"). Neither
-- could be built: the word "autopay" appeared nowhere in the schema, the
-- API or the app.
--
-- A three-state text column, not a boolean. The deck's own copy
-- distinguishes "on · full amount" from plain "on", and the distinction is
-- the whole point of the nudge: autopay set to the MINIMUM due still
-- protects the credit score from a late-payment mark but leaves the
-- remaining balance revolving at ~42% p.a., which is a materially different
-- situation from autopay set to the full statement amount. Collapsing both
-- into `autopay_enabled = true` would let the app tell a user they were
-- covered when they were about to be charged interest.
--
-- 'off' is the default and, importantly, is also what an untouched row
-- means. This is user-declared state — PandaPay is read-only by design and
-- has no issuer integration that could observe the real autopay mandate —
-- so 'off' means "not told us otherwise", not "verified off". The UI must
-- phrase the nudge as a question the user answers, never as a fact about
-- their bank account.
--
-- No `autopay_verified_at`. Same reasoning as migration 0025's missing
-- `phone_verified`: there is no code path that could set it honestly, and a
-- structurally-always-null column invites a future reader to treat it as a
-- real signal.

alter table user_cards
  add column if not exists autopay_mode text not null default 'off';

-- Added separately from the column so re-running against a database that
-- already has the column (but not the constraint) still lands the check.
alter table user_cards
  drop constraint if exists user_cards_autopay_mode_check;

alter table user_cards
  add constraint user_cards_autopay_mode_check
  check (autopay_mode in ('off', 'minimum', 'full'));

comment on column user_cards.autopay_mode is
  'User-declared autopay setting for this card: off | minimum | full. NOT '
  'observed from the issuer — PandaPay has no such integration — so ''off'' '
  'means "user has not said otherwise", never "verified off". ''minimum'' '
  'avoids a late-payment mark but leaves the balance revolving at interest, '
  'which is why this is not a boolean.';
