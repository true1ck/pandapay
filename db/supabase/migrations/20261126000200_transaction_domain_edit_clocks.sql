-- When the person last changed each independent thing about a transaction, by the phone's
-- server-adjusted clock. transactions.edited_at is one clock for the edit form (amount, date, category,
-- merchant, card, payment method ...). Writing a note, ignoring/restoring, or leaving a purchase out of
-- spending are separate actions that must not make a queued edit-form change look stale (or the other way
-- round), so each has its own clock and is only compared with itself:
--   note_edited_at       PATCH /transactions/:id/note
--   exclusion_edited_at  PUT   /transactions/:id/spend-exclusion
--   state_edited_at      POST  /transactions/:id/ignore and /restore (delete / bring back)
-- NULL = never changed by a person, or changed by an app that does not send a time (those keep today's
-- behaviour: the change applies and is stamped with the server's now()). Plain nullable columns: no table
-- rewrite, no backfill.
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS note_edited_at      timestamptz,
  ADD COLUMN IF NOT EXISTS exclusion_edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS state_edited_at     timestamptz;
