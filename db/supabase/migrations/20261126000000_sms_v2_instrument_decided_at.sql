-- When the person last made an explicit choice about an instrument (confirm, not mine, restore,
-- archive), by the phone's server-adjusted clock. The later choice wins when two devices disagree, so
-- undoing a "not mine" is no longer refused just because "rejected" is an explicit status.
-- NULL = no dated choice (an automatic reading, or a choice made by an app that does not send it);
-- those keep today's rule that detection never undoes a decision. Plain nullable column: no table
-- rewrite, no backfill.
ALTER TABLE public.sms_v2_instruments ADD COLUMN IF NOT EXISTS decided_at timestamptz;
