-- Bounded latest-revision/history and unresolved-expense existence reads.
-- Existing accepted financial records, grants and command functions are unchanged.
CREATE INDEX shared_revision_history_page ON shared_expenses.expense_revisions
 (context_id,expense_id,created_at DESC,revision_id DESC);
CREATE INDEX shared_unaccepted_context ON shared_expenses.expenses(context_id,expense_id)
 WHERE accepted_revision_id IS NULL;
