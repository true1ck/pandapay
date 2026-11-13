-- Money coming back from an investment (a redemption, a sale, a broker payout)
-- is its own kind. It is not a transfer between the user's own accounts and it
-- is not earned income, so it must not be folded into either. It counts in
-- Money in, never in earned income and never in spending.
--
-- Additive only: existing rows keep their kind, and the spend queries filter
-- on entry_kind = 'spend', so they are unaffected. Deploy this migration
-- before the API that can write the value.
alter type txn_entry_kind add value if not exists 'investment_return';
