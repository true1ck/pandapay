-- Enable Gemini SMS classification queue and master pipeline
begin;

insert into public.feature_flags (key, is_enabled, rollout_percent, description)
values ('sms_ai_queue_enabled', true, 100, 'Gemini SMS classification queue')
on conflict (key) do update set
  is_enabled = true,
  rollout_percent = 100,
  updated_at = now();

insert into public.feature_flags (key, is_enabled, rollout_percent, description)
values ('sms_facts_pipeline_enabled', true, 100, 'Master SMS facts pipeline')
on conflict (key) do update set
  is_enabled = true,
  rollout_percent = 100,
  updated_at = now();

commit;
