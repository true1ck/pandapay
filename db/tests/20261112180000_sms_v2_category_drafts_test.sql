\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as admin,gen_random_uuid()::text as draft \gset
insert into admin_users(id,email,role) values(:'admin','category-fixture@example.invalid','owner');
insert into sms_v2_category_drafts(draft_id,revision,status,body,created_by) values(:'draft',1,'draft','{"source":"shared"}',:'admin');
set local role app_user;
select set_config('pandapay.admin_actor',:'admin',true),set_config('pandapay.admin_permission','learning.publish',true);
do $$ begin
 if exists(select 1 from sms_v2_category_drafts) then raise exception 'public category drafts readable'; end if;
 begin insert into sms_v2_category_drafts(draft_id,revision,status,body) values(gen_random_uuid(),1,'draft','{}');raise exception 'public category draft write';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
set local session authorization admin_api_runtime;
set local role pandapay_admin_api;
select set_config('pandapay.admin_actor',:'admin',true),set_config('pandapay.admin_permission','learning.read',true);
do $$ begin
 if (select count(*) from sms_v2_category_drafts)<>1 then raise exception 'private draft read missing'; end if;
 update sms_v2_category_drafts set status='published';
 if exists(select 1 from sms_v2_category_drafts where status<>'draft') then raise exception 'read capability wrote draft'; end if;
end $$;
select set_config('pandapay.admin_permission','learning.publish',true);
update sms_v2_category_drafts set status='published' where draft_id=:'draft';
do $$ begin
 if not exists(select 1 from sms_v2_category_drafts where status='published') then raise exception 'private publish missing'; end if;
end $$;
reset role;
reset session authorization;
select 'sms_v2_category_drafts ok' as result;
rollback;
