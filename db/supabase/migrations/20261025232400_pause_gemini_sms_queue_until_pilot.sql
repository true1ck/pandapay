-- Keep Gemini submission paused until the explicit provider/privacy pilot gate.
-- The earlier rollout migration is retained as history; this forward migration
-- restores the intended default without deleting accepted jobs or SMS data.
begin;

insert into public.feature_flags (key, is_enabled, rollout_percent, description)
values (
  'sms_ai_queue_enabled',
  false,
  0,
  'Gemini SMS pilot paused pending explicit provider and privacy acceptance'
)
on conflict (key) do update set
  is_enabled = false,
  rollout_percent = 0,
  description = excluded.description,
  updated_at = now();

commit;
