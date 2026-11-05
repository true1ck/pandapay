-- Learning loop B1: every AI attempt records the prompt version, and a layout
-- an active rule already reads ends as 'covered' without calling the provider.
ALTER TABLE public.sms_v2_template_attempts ADD COLUMN prompt_version text;
ALTER TABLE public.sms_v2_unknown_templates ADD COLUMN covered_by text;
ALTER TABLE public.sms_v2_unknown_templates DROP CONSTRAINT sms_v2_unknown_templates_ai_status_check;
ALTER TABLE public.sms_v2_unknown_templates ADD CONSTRAINT sms_v2_unknown_templates_ai_status_check
  CHECK (ai_status IN ('held', 'queued', 'working', 'ready', 'failed', 'covered'));
