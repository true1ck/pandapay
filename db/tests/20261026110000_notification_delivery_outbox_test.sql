-- Disposable fully-migrated local PG fixture. Uses synthetic account data and
-- rolls back every row; never calls an external provider.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as profile_id, gen_random_uuid()::text as notification_id \gset
select set_config('test.notification_profile_id', :'profile_id', true),
       set_config('test.notification_id', :'notification_id', true);
insert into public.profiles(id) values(:'profile_id'::uuid);
insert into public.notification_preferences(profile_id) values(:'profile_id'::uuid);
insert into public.notifications(id,profile_id,category,severity,title,body,deep_link,dedupe_key)
values(:'notification_id'::uuid,:'profile_id'::uuid,'caps','info','Original','Original body','/cards','fixture');

set local role app_user;
select set_config('app.user_id', :'profile_id', true);
select notification_delivery.enqueue(:'notification_id'::uuid);
do $$ begin
  if has_table_privilege('app_user','notification_delivery.outbox','select')
     or has_table_privilege('app_user','notification_delivery.outbox','insert')
     or has_table_privilege('app_user','notification_delivery.revisions','select')
     or has_table_privilege('app_user','notification_delivery.profile_queue_counts','select') then
    raise exception 'app_user must not directly access outbox internals'; end if;
  if pg_has_role('app_user','notification_worker','member') then raise exception 'app_user may not assume worker'; end if;
  if not has_function_privilege('app_user','notification_delivery.enqueue(uuid)','execute') then raise exception 'user enqueue capability missing'; end if;
end $$;
reset role;

-- A dedupe upsert updates the live inbox copy but creates a new delivery
-- revision; already queued intent still points at the original body.
update public.notifications set title='Later title',body='Later body'
 where id=:'notification_id'::uuid;
set local role app_user;
select notification_delivery.enqueue(:'notification_id'::uuid);
reset role;
do $$ declare n integer; original_title text; nid uuid:=current_setting('test.notification_id')::uuid; begin
  select count(*) into n from notification_delivery.revisions where notification_id=nid;
  if n<>2 then raise exception 'expected two immutable delivery revisions, got %',n; end if;
  select r.title into original_title from notification_delivery.outbox o join notification_delivery.revisions r on r.id=o.revision_id
   where o.notification_id=nid and r.title='Original' limit 1;
  if original_title<>'Original' then raise exception 'earlier accepted delivery intent was substituted'; end if;
  if (select pending from notification_delivery.profile_queue_counts where profile_id=current_setting('test.notification_profile_id')::uuid)<>2
     or (select pending from notification_delivery.global_queue_count where singleton)<>2 then
    raise exception 'queue counters are not coherent with two pending revisions'; end if;
end $$;

set local role notification_worker;
do $$ declare c record; result jsonb; begin
  if has_table_privilege('notification_worker','notification_delivery.outbox','select')
     or has_table_privilege('notification_worker','notification_delivery.outbox','update')
     or has_table_privilege('notification_worker','notification_delivery.revisions','select')
     or has_table_privilege('notification_worker','notification_delivery.global_queue_count','select') then raise exception 'worker has direct table access'; end if;
  select * into c from notification_delivery.claim('fixture-worker',10,90) limit 1;
  if c.id is null or c.attempts<>1 then raise exception 'bounded claim failed'; end if;
  result:=notification_delivery.finish(c.id,c.lease_token,false,'synthetic_failure',false);
  if result->>'state'<>'pending' then raise exception 'retry scheduling failed: %',result; end if;
  result:=notification_delivery.finish(c.id,gen_random_uuid(),true,null,false);
  if result->>'state'<>'lease_lost' then raise exception 'stale lease token was accepted'; end if;
end $$;
reset role;

-- Refusal at the storage cap cannot leave a payload copy without its intent.
update notification_delivery.global_queue_count set retained=10000 where singleton;
update public.notifications set title='Capacity test' where id=:'notification_id'::uuid;
set local role app_user;
do $$ begin
  begin
    perform notification_delivery.enqueue(current_setting('test.notification_id')::uuid);
    raise exception 'retained-row ceiling not enforced';
  exception when program_limit_exceeded then null; end;
end $$;
reset role;
do $$ begin
  if (select count(*) from notification_delivery.revisions
       where notification_id=current_setting('test.notification_id')::uuid)<>2 then
    raise exception 'failed admission left an orphaned content revision'; end if;
end $$;
update notification_delivery.global_queue_count
 set retained=(select count(*) from notification_delivery.outbox) where singleton;
update notification_delivery.profile_queue_counts set pending=500
 where profile_id=:'profile_id'::uuid;
set local role app_user;
do $$ begin
  begin
    perform notification_delivery.enqueue(current_setting('test.notification_id')::uuid);
    raise exception 'per-profile ceiling not enforced';
  exception when program_limit_exceeded then null; end;
end $$;
reset role;
update notification_delivery.profile_queue_counts c set pending=(
 select count(*) from notification_delivery.outbox o where o.profile_id=c.profile_id and o.state in ('pending','leased'));

-- The final attempt releases pending capacity, retaining terminal evidence.
update notification_delivery.outbox set attempts=7,available_at=now()-interval '1 hour',
 state='pending',lease_until=null,lease_token=null,lease_owner=null;
set local role notification_worker;
do $$ declare c record; r jsonb; begin
  select * into c from notification_delivery.claim('final-attempt',1,90);
  if c.attempts<>8 then raise exception 'last retry was not bounded'; end if;
  r:=notification_delivery.finish(c.id,c.lease_token,false,'provider_unavailable',false);
  if r->>'state'<>'dead' then raise exception 'exhausted job not terminal'; end if;
end $$;
reset role;
do $$ begin
  if (select pending from notification_delivery.global_queue_count where singleton)<>1
     or (select retained from notification_delivery.global_queue_count where singleton)<>2 then
    raise exception 'terminal state did not preserve exact capacity counters'; end if;
end $$;
rollback;
