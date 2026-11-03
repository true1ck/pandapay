-- Disposable fully migrated Postgres. Every synthetic row rolls back.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as p1,gen_random_uuid()::text as p2,gen_random_uuid()::text as admin \gset
insert into profiles(id) values(:'p1'),(:'p2');
insert into admin_users(id,email,role) values(:'admin','template-fixture@example.invalid','owner');
insert into user_consents(profile_id,purpose,policy_version,granted)
 values(:'p1','sms_shared_learning','sms-shared-learning-v2',true),(:'p2','sms_shared_learning','sms-shared-learning-v2',true);
set local role app_user;
select set_config('app.user_id',:'p1',true);
select pandapay.sms_v2_submit_templates(jsonb_build_array(jsonb_build_object('templateHash',repeat('e',64),'senderBrand','TESTBK',
 'redactedBody','<AMT> paid to <PARTY>.','observedAt',now())),true);
do $$ begin
 if (select count(*) from sms_v2_unknown_templates)<>0 then raise exception 'global template rows visible'; end if;
 if (select count(*) from pandapay.sms_v2_template_results(0))<>1 then raise exception 'owner result missing'; end if;
 begin
  perform pandapay.sms_v2_submit_templates(jsonb_build_array(jsonb_build_object('templateHash',repeat('f',64),'senderBrand','TESTBK',
   'redactedBody','Call 9876543210','observedAt',now())),true);
  raise exception 'unredacted template accepted';
 exception when invalid_parameter_value then null; end;
end $$;
select set_config('app.user_id',:'p2',true);
do $$ begin
 if exists(select 1 from pandapay.sms_v2_template_results(0)) then raise exception 'another profile result visible'; end if;
end $$;
reset role;
set local session authorization admin_api_runtime;
set local role pandapay_admin_api;
select set_config('pandapay.admin_actor',:'admin',true);
select set_config('pandapay.admin_permission','learning.read',true);
do $$ begin
 if (select count(*) from sms_v2_unknown_templates)<>1 then raise exception 'private read missing'; end if;
 update sms_v2_unknown_templates set ai_status='ready';
 if exists(select 1 from sms_v2_unknown_templates where ai_status<>'queued') then
   raise exception 'read transaction mutated template';
 end if;
end $$;
reset role;
reset session authorization;
insert into user_consents(profile_id,purpose,policy_version,granted,granted_at)
 values(:'p1','sms_shared_learning','sms-shared-learning-v2',false,clock_timestamp());
do $$ begin
 if exists(select 1 from sms_v2_template_submitters) then raise exception 'revoked submitter retained'; end if;
 if exists(select 1 from sms_v2_unknown_templates) then raise exception 'orphan template retained'; end if;
end $$;
select 'sms_v2_templates ok' as result;
rollback;
