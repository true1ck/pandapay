-- Providers whose draft for this layout was rejected during the current retry cycle. The next retry of the
-- same layout skips them (X-AI-Skip-Providers); the worker clears the list when the cycle restarts, and when
-- the layout becomes ready, failed or covered. Written only by the AI drafts worker.
ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN ai_excluded_providers text[] NOT NULL DEFAULT '{}';

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT UPDATE (ai_excluded_providers) ON public.sms_v2_unknown_templates TO sms_ai_worker;
  END IF;
END $$;
