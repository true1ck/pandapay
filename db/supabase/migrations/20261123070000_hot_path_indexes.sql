-- Hot-path indexes found by a sequential-scan sweep of a realistic multi-user burst (db stats after the burst):
--  * points_ledger: GET /user-cards sums delta_points per card (WHERE user_card_id = $1). No index led with
--    user_card_id or profile_id, so every card read scanned the whole ledger (8.4M tuples read by 300 scans of a
--    27,900-row table in one 100-user burst; it grows without bound in production). INCLUDE makes it an index-only scan.
--  * transaction_splits: lookups by transaction_id (split totals on amount edits, transaction detail) had only the
--    primary key.
--  * user_cards: the existing per-profile indexes are partial (active cards only); listing archived cards too had none.
-- Plain CREATE INDEX (the migration runner wraps a file in a transaction, which rules out CONCURRENTLY).
CREATE INDEX IF NOT EXISTS idx_points_ledger_card ON public.points_ledger (user_card_id) INCLUDE (delta_points, reason);
CREATE INDEX IF NOT EXISTS idx_transaction_splits_transaction ON public.transaction_splits (transaction_id);
CREATE INDEX IF NOT EXISTS idx_user_cards_profile_order ON public.user_cards (profile_id, sort_order, created_at);
