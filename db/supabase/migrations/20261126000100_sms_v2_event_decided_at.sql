-- When the person last decided about an event (a correction or a confirmed receipt), by the phone's
-- server-adjusted clock. When two devices both confirmed the same event differently, the later
-- decision wins instead of whichever upload arrives last. NULL = no dated decision (automatic
-- reading, or an app that does not send it); those keep today's rule. Plain nullable column: no
-- table rewrite, no backfill.
ALTER TABLE public.sms_v2_events ADD COLUMN IF NOT EXISTS decided_at timestamptz;
