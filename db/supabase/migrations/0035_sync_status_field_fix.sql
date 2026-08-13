-- Code-review fix for 0034_sync_engine.sql: `status` was allowlisted as a
-- directly syncable field on `transactions`, but pandapay.sync_apply_change()
-- applies allowlisted fields as a raw column UPDATE with no side effects.
-- Every other path that changes a transaction's status —
-- POST /transactions/:id/ignore (api/src/index.js) — first calls
-- reverseTransactionState() to undo that transaction's cap/milestone/
-- points-ledger/fee-waiver contribution. Syncing `status` directly let a
-- client flip a transaction to 'ignored' (or back to 'active') over
-- POST /sync/push while leaving all of that derived state untouched —
-- exactly the "silent divergence during sync" failure mode 0005_sync.sql's
-- own header warns about, just via a different table than that migration
-- was guarding.
--
-- Fix is to remove `status` from the syncable allowlist, not to teach
-- sync_apply_change how to reverse/reapply state — that logic already lives
-- in api/src/index.js (loadUserCardForState, applyTransactionState,
-- reverseTransactionState) and duplicating financial arithmetic in SQL would
-- be the "two places to keep in sync" problem 0034's own header explicitly
-- designed around for cap_states/milestone_states/points_ledger. A status
-- change now has to go through the REST route, same as an insert already
-- does (0034's sync_apply_change already refuses inserts for the identical
-- reason — "every entity here is created through a route that enforces real
-- invariants").
--
-- No data migration needed: this only changes what a FUTURE sync push can
-- write, and no client has shipped that pushes `status` yet (grepped
-- app/lib/features/sync/ and app/lib/data/local/sync_queue.dart — neither
-- references 'status').
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','rail','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;
