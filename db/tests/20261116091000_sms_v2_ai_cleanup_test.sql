-- Disposable fully migrated Postgres. Every synthetic row rolls back.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as admin \gset
insert into sms_v2_unknown_templates(template_hash, sender_brand, redacted_body, ai_status, ai_draft, ai_model, admin_decision, admin_reason, decided_by, decided_at)
values
 -- approved long ago and published: draft goes
 (repeat('1', 64), 'TESTBK', 'a <AMT>', 'ready', '{"id":"AI-1"}', 'm', 'approved', null, :'admin', now() - interval '8 days'),
 -- approved recently: the phone may still need the private rule
 (repeat('2', 64), 'TESTBK', 'b <AMT>', 'ready', '{"id":"AI-2"}', 'm', 'approved', null, :'admin', now() - interval '1 day'),
 -- approved long ago but never published: keep
 (repeat('3', 64), 'TESTBK', 'c <AMT>', 'ready', '{"id":"AI-3"}', 'm', 'approved', null, :'admin', now() - interval '30 days'),
 -- rejected long ago with a leftover draft: goes
 (repeat('4', 64), 'TESTBK', 'd <AMT>', 'failed', '{"id":"AI-4"}', 'm', 'rejected', 'wrong_fields', :'admin', now() - interval '10 days'),
 -- undecided: keep
 (repeat('5', 64), 'TESTBK', 'e <AMT>', 'ready', '{"id":"AI-5"}', 'm', null, null, null, null);
insert into sms_v2_rules(rule_id, version, status, family, senders, body, created_by)
values ('AI-' || repeat('1', 64), 1, 'active', 'f', '{TESTBK}', '{}', 'fixture'),
       ('AI-' || repeat('2', 64), 1, 'active', 'f', '{TESTBK}', '{}', 'fixture');
insert into sms_v2_template_attempts(template_hash, job_id, attempt, model, capacity_minute, reserved_tokens, total_tokens, cost_usd, outcome)
values (repeat('1', 64), gen_random_uuid(), 1, 'm', date_trunc('minute', now()), 10, 250, 0.002, 'valid');

-- Not callable by an ordinary login.
set local role app_user;
do $$ begin
  begin perform pandapay.sms_v2_ai_cleanup_decided(); raise exception 'app_user ran the cleanup';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- The AI worker login runs it.
set local session authorization sms_ai_worker;
do $$ begin
  if pandapay.sms_v2_ai_cleanup_decided() <> 2 then raise exception 'wrong number cleaned'; end if;
  if pandapay.sms_v2_ai_cleanup_decided() <> 0 then raise exception 'second run cleaned again'; end if;
end $$;
reset session authorization;

do $$ begin
  if exists (select 1 from sms_v2_unknown_templates where template_hash in (repeat('1', 64), repeat('4', 64)) and ai_draft is not null) then
    raise exception 'old decided drafts kept'; end if;
  if (select count(*) from sms_v2_unknown_templates where template_hash in (repeat('2', 64), repeat('3', 64), repeat('5', 64)) and ai_draft is not null) <> 3 then
    raise exception 'recent, unpublished or undecided drafts removed'; end if;
  -- the decision record survives
  if not exists (select 1 from sms_v2_unknown_templates where template_hash = repeat('1', 64)
                  and admin_decision = 'approved' and ai_status = 'ready' and ai_model = 'm' and decided_at is not null and redacted_body = 'a <AMT>') then
    raise exception 'approval record lost'; end if;
  if not exists (select 1 from sms_v2_unknown_templates where template_hash = repeat('4', 64)
                  and admin_decision = 'rejected' and admin_reason = 'wrong_fields' and redacted_body = 'd <AMT>') then
    raise exception 'rejection record (negative example) lost'; end if;
  -- the counters survive
  if (select cost_usd from sms_v2_template_attempts where template_hash = repeat('1', 64)) <> 0.002 then raise exception 'cost lost'; end if;
end $$;
select 'sms_v2_ai_cleanup ok' as result;
rollback;
