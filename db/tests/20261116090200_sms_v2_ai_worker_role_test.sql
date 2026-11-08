-- Disposable fully migrated Postgres, with SMS_AI_WORKER_DB_PASSWORD set when
-- db/setup_app_role.sql ran. Every synthetic row rolls back.
-- Proves what the production AI drafts worker login (sms_ai_worker) can and
-- cannot do.
\set ON_ERROR_STOP on
begin;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'sms_ai_worker') then
    raise exception 'sms_ai_worker was not created; run with SMS_AI_WORKER_DB_PASSWORD set';
  end if;
  if exists (select 1 from pg_roles where rolname = 'sms_ai_worker'
              and (rolsuper or rolbypassrls or rolcreaterole or rolcreatedb or rolreplication or rolinherit)) then
    raise exception 'sms_ai_worker has more than a plain login';
  end if;
end $$;

select gen_random_uuid()::text as p1, gen_random_uuid()::text as p2 \gset
insert into profiles(id) values (:'p1'), (:'p2');
-- p1 consents to shared learning, p2 does not.
insert into user_consents(profile_id, purpose, policy_version, granted)
  values (:'p1', 'sms_shared_learning', 'sms-shared-learning-v3', true);
insert into sms_v2_unknown_templates(template_hash, sender_brand, redacted_body, ai_status)
  values (repeat('a', 64), 'TESTBK', '<AMT> paid to <PARTY>.', 'queued'),
         (repeat('b', 64), 'TESTBK', '<AMT> credited.', 'queued'),
         (repeat('c', 64), 'TESTBK', 'held layout <AMT>.', 'held'),
         (repeat('d', 64), 'TESTBK', 'blocked layout <AMT>.', 'blocked');
insert into sms_v2_template_submitters(template_hash, profile_id, eligible)
  values (repeat('a', 64), :'p1', true), (repeat('a', 64), :'p2', true), (repeat('b', 64), :'p2', true);
insert into sms_v2_rules(rule_id, version, status, family, senders, body, created_by)
  values ('R-ACTIVE', 1, 'active', 'f', '{TESTBK}', '{"id":"R-ACTIVE"}', 'fixture'),
         ('R-DRAFT', 1, 'draft', 'f', '{TESTBK}', '{"id":"R-DRAFT"}', 'fixture');

set local session authorization sms_ai_worker;

-- Reads it needs.
do $$ declare n integer; begin
  select count(*) into n from sms_v2_unknown_templates;
  if n <> 4 then raise exception 'queue not readable (%)', n; end if;
  select count(*) into n from sms_v2_rules;
  if n <> 1 then raise exception 'worker must see only the ACTIVE rule (saw %)', n; end if;
  -- only people with current consent count; p2 never consented
  if pandapay.sms_v2_ai_consent_people(repeat('a', 64)) <> 1 then raise exception 'consent count wrong'; end if;
  if pandapay.sms_v2_ai_consent_people(repeat('b', 64)) <> 0 then raise exception 'unconsented layout counted'; end if;
  perform * from pandapay.sms_v2_ai_report_counts(repeat('a', 64));
  perform key from sms_v2_settings;
end $$;

-- Customer and consent data stay out of reach.
do $$ declare t text; begin
  foreach t in array array['profiles', 'user_consents', 'sms_v2_template_submitters', 'sms_v2_correction_cases'] loop
    begin
      execute format('select count(*) from %I', t);
      raise exception 'worker could read %', t;
    exception when insufficient_privilege then null; end;
  end loop;
end $$;

-- Writes: only the worker-owned columns, only on queued or working rows.
do $$ declare n integer; begin
  update sms_v2_unknown_templates
     set ai_status = 'working', lease_id = gen_random_uuid(), lease_expires_at = now() + interval '3 minutes'
   where template_hash = repeat('a', 64);
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'claim failed'; end if;
  update sms_v2_unknown_templates set ai_status = 'ready', ai_draft = '{"id":"AI-x"}', ai_model = 'm'
   where template_hash = repeat('a', 64);
  -- a finished row is out of the worker's hands
  update sms_v2_unknown_templates set ai_status = 'failed' where template_hash = repeat('a', 64);
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'worker changed a finished row'; end if;
  -- held and blocked layouts are never touched
  update sms_v2_unknown_templates set ai_status = 'queued' where template_hash in (repeat('c', 64), repeat('d', 64));
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'worker changed a held or blocked row'; end if;
  begin
    update sms_v2_unknown_templates set redacted_body = 'x' where template_hash = repeat('b', 64);
    raise exception 'worker rewrote a layout';
  exception when insufficient_privilege then null; end;
  begin
    update sms_v2_unknown_templates set admin_decision = 'approved' where template_hash = repeat('b', 64);
    raise exception 'worker decided a layout';
  exception when insufficient_privilege then null; end;
  begin
    delete from sms_v2_unknown_templates;
    raise exception 'worker deleted layouts';
  exception when insufficient_privilege then null; end;
  begin
    update sms_v2_unknown_templates set ai_status = 'blocked' where template_hash = repeat('b', 64);
    raise exception 'worker set a status outside its range';
  exception when insufficient_privilege then null; end;
end $$;

-- Capacity and attempts.
do $$ declare m timestamptz := date_trunc('minute', clock_timestamp()); begin
  insert into sms_v2_ai_capacity(minute) values (m) on conflict do nothing;
  update sms_v2_ai_capacity set requests = requests + 1, reserved_tokens = reserved_tokens + 10 where minute = m;
  insert into sms_v2_template_attempts(template_hash, job_id, attempt, model, capacity_minute, reserved_tokens)
    values (repeat('a', 64), gen_random_uuid(), 1, 'm', m, 10);
  update sms_v2_template_attempts set cost_usd = 0.001, outcome = 'ok';
  perform nextval('sms_v2_template_revision');
end $$;

-- It can never publish: no rule writes, and no admin permission checks pass.
do $$ begin
  begin
    insert into sms_v2_rules(rule_id, version, status, family, senders, body, created_by)
      values ('R-NEW', 1, 'active', 'f', '{TESTBK}', '{}', 'worker');
    raise exception 'worker wrote a rule';
  exception when insufficient_privilege then null; end;
  begin
    update sms_v2_rules set status = 'retired';
    raise exception 'worker changed a rule';
  exception when insufficient_privilege then null; end;
end $$;

reset session authorization;

-- Another login cannot use the aggregate functions to probe consent.
set local role app_user;
do $$ begin
  begin
    perform pandapay.sms_v2_ai_consent_people(repeat('a', 64));
    raise exception 'app_user called the consent count';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select 'sms_v2_ai_worker_role ok' as result;
rollback;
