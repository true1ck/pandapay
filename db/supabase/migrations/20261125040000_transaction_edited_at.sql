-- When the person last edited a transaction, by the phone's server-adjusted clock (not when the server
-- received the edit). A late or repeated delivery of an older edit, and an older server copy that a slow
-- refresh brings back, can then be told apart from the person's latest change by this value alone.
-- NULL = never edited by the person. Plain nullable column: no table rewrite, and an app that does not
-- send an edit time keeps today's behaviour (its edit is stamped with the server's now()).
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS edited_at timestamptz;
