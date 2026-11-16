-- Disposable fully migrated Postgres. Every synthetic row rolls back.
-- Draft feedback: delivery, rejection, quarantine, privacy of the new tables.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as p1, gen_random_uuid()::text as p2 \gset
insert into profiles(id) values (:'p1'), (:'p2');
insert into user_consents(profile_id, purpose, policy_version, granted)
  values (:'p1', 'sms_shared_learning', 'sms-shared-learning-v3', true),
         (:'p2', 'sms_shared_learning', 'sms-shared-learning-v3', true);
insert into sms_v2_unknown_templates(template_hash, sender_brand, redacted_body, ai_status)
  values (repeat('e', 64), 'TESTBK', '<AMT> paid to <PARTY>.', 'queued');
insert into sms_v2_template_submitters(template_hash, profile_id, eligible)
  values (repeat('e', 64), :'p1', true);
update sms_v2_unknown_templates set ai_status = 'ready', ai_draft = '{"id":"AI-X","version":1}'
 where template_hash = repeat('e', 64);
do $$ begin
  if (select ai_draft_revision from sms_v2_unknown_templates) <> 1 then raise exception 'draft revision not bumped'; end if;
end $$;

set local role app_user;
select set_config('app.user_id', :'p1', true);
-- The tables are closed to the phone login; only the functions reach them.
do $$ begin
  if (select count(*) from sms_v2_draft_deliveries) <> 0 or (select count(*) from sms_v2_draft_rejections) <> 0 then
    raise exception 'phone login can read draft feedback tables';
  end if;
end $$;
select set_config('t.d1', (select draft_id::text from pandapay.sms_v2_template_results(0) where draft_id is not null), true);
do $$ begin
  if (select count(*) from pandapay.sms_v2_template_results(0) where draft_id is not null) <> 1 then
    raise exception 'delivery missing';
  end if;
end $$;
select set_config('app.user_id', :'p2', true);
do $$ begin
  begin
    perform pandapay.sms_v2_report_draft_rejection(current_setting('t.d1')::uuid, 'no_match');
    raise exception 'a draft delivered to someone else was accepted';
  exception when sqlstate 'P0404' then null; end;
end $$;
select set_config('app.user_id', :'p1', true);
do $$ begin
  if pandapay.sms_v2_report_draft_rejection(current_setting('t.d1')::uuid, 'no_match') <> 'recorded' then raise exception 'not recorded'; end if;
  if pandapay.sms_v2_report_draft_rejection(current_setting('t.d1')::uuid, 'no_match') <> 'already_recorded' then raise exception 'not idempotent'; end if;
end $$;
reset role;
do $$ begin
  -- One person saw the layout, so one rejection replaces the draft.
  if not exists (select 1 from sms_v2_unknown_templates where ai_status = 'queued' and ai_user_replacements = 1 and ai_draft is null) then
    raise exception 'layout not requeued';
  end if;
end $$;
rollback;
select 'sms_v2_draft_feedback ok' as result;
