-- Private account lifecycle capability; no public or app_user execution rights.
do $$
declare v_role text;
begin
  foreach v_role in array array['account_lifecycle_owner', 'pandapay_account_lifecycle'] loop
    if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
      execute pg_catalog.format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls', v_role);
    elsif exists (select 1 from pg_catalog.pg_roles where rolname = v_role and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
      raise exception 'Unsafe existing account lifecycle role';
    end if;
    if exists (select 1 from pg_catalog.pg_auth_members where member = v_role::regrole) then
      raise exception 'account lifecycle roles must not inherit or SET other roles';
    end if;
  end loop;
end $$;

-- PostgreSQL 16+ managed CREATEROLE users receive ADMIN on roles they create,
-- but not necessarily SET. Temporarily allow only this migration role to SET
-- the definer owner. Save its own grant and restore it below; the bootstrap
-- grantor's ADMIN membership is never revoked or changed. This makes both a
-- first install and a reviewed SQL replay work without SUPERUSER.
do $$
declare v_prior jsonb;
begin
  select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option)
    into v_prior from pg_catalog.pg_auth_members m
    where m.roleid = 'account_lifecycle_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.lifecycle_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.lifecycle_migration_role',current_user,true);
  execute pg_catalog.format('grant account_lifecycle_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant account_lifecycle_owner to %I with set true granted by %I',current_user,current_user);
end $$;

-- Additive deletion ledger. No financial, receipt, profile, or contact rows are
-- physically deleted. Retention/purge policy and operator enablement are separate.
create schema if not exists account_lifecycle;
revoke all on schema account_lifecycle from public;
grant usage,create on schema account_lifecycle to account_lifecycle_owner;
grant usage on schema public,pandapay to account_lifecycle_owner;
grant execute on function pandapay.uid() to account_lifecycle_owner;

create table account_lifecycle.control (
  singleton boolean primary key default true check(singleton),
  worker_enabled boolean not null default false
);
insert into account_lifecycle.control(singleton) values(true);
create table account_lifecycle.requests (
  request_id uuid primary key default pg_catalog.gen_random_uuid(),
  profile_id uuid not null,
  generation bigint not null check(generation>0),
  requested_at timestamptz not null,
  due_at timestamptz not null check(due_at>=requested_at),
  status text not null check(status in ('pending','cancelled','processing','completed','blocked')),
  attempts integer not null default 0 check(attempts between 0 and 10),
  lease_token uuid,
  leased_until timestamptz,
  retry_after timestamptz not null default pg_catalog.now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  last_error_code text check(last_error_code is null or last_error_code='auth_unavailable'),
  unique(profile_id,generation)
);
create unique index account_lifecycle_one_active on account_lifecycle.requests(profile_id)
  where status<>'cancelled';
create index account_lifecycle_due on account_lifecycle.requests(retry_after,due_at)
  where status in ('pending','processing');
create table account_lifecycle.tombstones (
  profile_id uuid primary key,
  request_id uuid not null unique references account_lifecycle.requests(request_id),
  generation bigint not null check(generation>0),
  deleted_at timestamptz not null default pg_catalog.now()
);
-- Preserve existing pending requests, their grace periods and original UUIDs.
insert into account_lifecycle.requests(profile_id,generation,requested_at,due_at,status)
  select id,1,deletion_requested_at,deletion_due_at,'pending' from public.profiles
  where deletion_requested_at is not null and deletion_due_at>=deletion_requested_at;

do $$ declare t text; begin
  foreach t in array array['control','requests','tombstones'] loop
    execute pg_catalog.format('revoke all on account_lifecycle.%I from public',t);
    execute pg_catalog.format('alter table account_lifecycle.%I enable row level security',t);
    execute pg_catalog.format('alter table account_lifecycle.%I force row level security',t);
    execute pg_catalog.format('grant select,insert,update on account_lifecycle.%I to account_lifecycle_owner',t);
    execute pg_catalog.format('create policy lifecycle_owner on account_lifecycle.%I for all to account_lifecycle_owner using(true) with check(true)',t);
    execute pg_catalog.format('create policy lifecycle_operator on account_lifecycle.%I for all to %I using(true) with check(true)',t,current_user);
  end loop;
end $$;
grant select(id,deletion_requested_at,deletion_due_at),update(deletion_requested_at,deletion_due_at)
  on public.profiles to account_lifecycle_owner;
create policy profiles_lifecycle_read on public.profiles for select to account_lifecycle_owner using(true);
create policy profiles_lifecycle_update on public.profiles for update to account_lifecycle_owner using(true) with check(true);
grant trigger on public.profiles to account_lifecycle_owner;

set local role account_lifecycle_owner;
create function account_lifecycle.assert_access(p_profile uuid) returns void
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
begin
  if p_profile is null or p_profile is distinct from pandapay.uid() then
    raise exception 'Account access denied' using errcode='42501';
  end if;
  -- Hold the shared per-account fence until this user transaction commits.
  -- A due claim must not commit a tombstone ahead of an older sync write.
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(p_profile::text,73612));
  if exists(select 1 from account_lifecycle.tombstones where profile_id=p_profile) then
    raise exception 'Account access denied' using errcode='42501';
  end if;
end $$;

create function account_lifecycle.request_deletion(p_profile uuid)
returns table(deletion_requested_at timestamptz,deletion_due_at timestamptz)
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare r account_lifecycle.requests%rowtype; n bigint;
begin
  perform account_lifecycle.assert_access(p_profile);
  perform 1 from public.profiles where id=p_profile for update;
  if not found then return; end if;
  select * into r from account_lifecycle.requests where profile_id=p_profile and status<>'cancelled' for update;
  if not found then
    select coalesce(max(generation),0)+1 into n from account_lifecycle.requests where profile_id=p_profile;
    insert into account_lifecycle.requests(profile_id,generation,requested_at,due_at,status)
      values(p_profile,n,pg_catalog.now(),pg_catalog.now()+interval '30 days','pending') returning * into r;
  end if;
  if r.status<>'pending' then raise exception 'Account deletion is already processing' using errcode='55000'; end if;
  update public.profiles set deletion_requested_at=r.requested_at,deletion_due_at=r.due_at where id=p_profile;
  deletion_requested_at:=r.requested_at; deletion_due_at:=r.due_at; return next;
end $$;

create function account_lifecycle.cancel_deletion(p_profile uuid)
returns table(deletion_requested_at timestamptz,deletion_due_at timestamptz)
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare r account_lifecycle.requests%rowtype;
begin
  perform account_lifecycle.assert_access(p_profile);
  perform 1 from public.profiles where id=p_profile for update;
  if not found then return; end if;
  select * into r from account_lifecycle.requests where profile_id=p_profile and status<>'cancelled' for update;
  if found then
    if r.status<>'pending' or r.due_at<=pg_catalog.now() then
      raise exception 'Account deletion grace period has ended' using errcode='55000';
    end if;
    update account_lifecycle.requests set status='cancelled',cancelled_at=pg_catalog.now() where request_id=r.request_id;
  end if;
  update public.profiles set deletion_requested_at=null,deletion_due_at=null where id=p_profile;
  deletion_requested_at:=null; deletion_due_at:=null; return next;
end $$;

create function account_lifecycle.claim_due(p_limit integer)
returns table(request_id uuid,profile_id uuid,generation bigint,lease_token uuid)
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare r account_lifecycle.requests%rowtype; token uuid;
begin
  if p_limit is null or p_limit not between 1 and 25 then raise exception 'Invalid lifecycle batch size' using errcode='22023'; end if;
  if not exists(select 1 from account_lifecycle.control where singleton and worker_enabled) then return; end if;
  for r in select q.* from account_lifecycle.requests q
    where q.status in ('pending','processing') and q.due_at<=pg_catalog.now()
      and q.retry_after<=pg_catalog.now() and q.attempts<10
      and exists(select 1 from public.profiles p where p.id=q.profile_id and p.deletion_requested_at=q.requested_at and p.deletion_due_at=q.due_at)
      and (q.leased_until is null or q.leased_until<=pg_catalog.now())
    order by q.due_at,q.request_id for update skip locked limit p_limit
  loop
    -- Never wait here: request/cancel may hold the shared fence while waiting
    -- for this request row. A blocking exclusive acquisition would deadlock.
    if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended(r.profile_id::text,73612)) then
      continue;
    end if;
    token:=pg_catalog.gen_random_uuid();
    update account_lifecycle.requests q set status='processing',attempts=q.attempts+1,
      lease_token=token,leased_until=pg_catalog.now()+interval '60 seconds' where q.request_id=r.request_id;
    insert into account_lifecycle.tombstones(profile_id,request_id,generation)
      values(r.profile_id,r.request_id,r.generation) on conflict do nothing;
    request_id:=r.request_id; profile_id:=r.profile_id; generation:=r.generation; lease_token:=token; return next;
  end loop;
  -- A crash after the final allowed attempt must not leave an immortal lease.
  update account_lifecycle.requests q set status='blocked',lease_token=null,leased_until=null,
    last_error_code='auth_unavailable' where q.status='processing' and q.attempts>=10
    and q.leased_until<=pg_catalog.now();
end $$;

create function account_lifecycle.finish(p_request uuid,p_lease uuid,p_success boolean) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
begin
  if p_request is null or p_lease is null or p_success is null then raise exception 'Invalid lifecycle acknowledgement' using errcode='22023'; end if;
  update account_lifecycle.requests q set status=case when p_success then 'completed' when q.attempts>=10 then 'blocked' else 'processing' end,
    completed_at=case when p_success then pg_catalog.now() else null end,
    lease_token=null,leased_until=null,last_error_code=case when p_success then null else 'auth_unavailable' end,
    retry_after=pg_catalog.now()+pg_catalog.make_interval(secs=>least(3600,5*power(2,q.attempts)::integer))
    where q.request_id=p_request and q.lease_token=p_lease and q.status='processing' and q.leased_until>pg_catalog.now();
  return found;
end $$;

create function account_lifecycle.list_tombstones(p_after uuid,p_limit integer)
returns table(request_id uuid,profile_id uuid,generation bigint)
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$
begin
  if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid replay batch size' using errcode='22023'; end if;
  return query select t.request_id,t.profile_id,t.generation from account_lifecycle.tombstones t
    where p_after is null or t.profile_id>p_after order by t.profile_id limit p_limit;
end $$;

create function account_lifecycle.replay_tombstone(p_request uuid,p_profile uuid,p_generation bigint) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare r account_lifecycle.requests%rowtype;
begin
  if p_request is null or p_profile is null or p_generation is null or p_generation<1 then
    raise exception 'Invalid deletion tombstone' using errcode='22023';
  end if;
  if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended(p_profile::text,73612)) then
    raise exception 'Account lifecycle replay requires quiesced services' using errcode='55000';
  end if;
  if exists(select 1 from account_lifecycle.tombstones where profile_id=p_profile) then
    if not exists(select 1 from account_lifecycle.tombstones where profile_id=p_profile and request_id=p_request and generation=p_generation) then
      raise exception 'Deletion tombstone conflicts with retained history' using errcode='23514';
    end if;
    return false;
  end if;
  select * into r from account_lifecycle.requests where request_id=p_request for update;
  if found then
    if r.profile_id<>p_profile or r.generation<>p_generation or r.status='cancelled' then
      raise exception 'Deletion tombstone conflicts with retained history' using errcode='23514';
    end if;
    update account_lifecycle.requests set status='completed',completed_at=pg_catalog.now(),lease_token=null,leased_until=null where request_id=p_request;
  else
    insert into account_lifecycle.requests(request_id,profile_id,generation,requested_at,due_at,status,completed_at)
      values(p_request,p_profile,p_generation,pg_catalog.now(),pg_catalog.now(),'completed',pg_catalog.now());
  end if;
  insert into account_lifecycle.tombstones(profile_id,request_id,generation) values(p_profile,p_request,p_generation);
  return true;
end $$;

-- Keep legacy clients and disabled source flags consistent with the durable
-- ledger. The old routes retain their previous grace reset/cancel behavior until
-- a worker claims the account. New RPCs keep their stricter idempotent contract.
create function account_lifecycle.mirror_profile_schedule() returns trigger
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare r account_lifecycle.requests%rowtype;n bigint;begin
 if not pg_catalog.pg_try_advisory_xact_lock_shared(pg_catalog.hashtextextended(new.id::text,73612)) then
  raise exception 'Account lifecycle schedule must retry' using errcode='40001';
 end if;
 if exists(select 1 from account_lifecycle.tombstones where profile_id=new.id) then
  raise exception 'Account access denied' using errcode='42501';
 end if;
 select * into r from account_lifecycle.requests where profile_id=new.id and status<>'cancelled' for update;
 if new.deletion_requested_at is null and new.deletion_due_at is null then
  if found then
   if r.status<>'pending' then raise exception 'Account deletion is already processing' using errcode='55000';end if;
   update account_lifecycle.requests set status='cancelled',cancelled_at=pg_catalog.now() where request_id=r.request_id;
  end if;
  return new;
 end if;
 if new.deletion_requested_at is null or new.deletion_due_at is null or new.deletion_due_at<new.deletion_requested_at then
  raise exception 'Invalid deletion schedule' using errcode='22023';
 end if;
 if found then
  if r.status<>'pending' then raise exception 'Account deletion is already processing' using errcode='55000';end if;
  update account_lifecycle.requests set requested_at=new.deletion_requested_at,due_at=new.deletion_due_at where request_id=r.request_id;
 else
  select coalesce(max(generation),0)+1 into n from account_lifecycle.requests where profile_id=new.id;
  insert into account_lifecycle.requests(profile_id,generation,requested_at,due_at,status)
   values(new.id,n,new.deletion_requested_at,new.deletion_due_at,'pending');
 end if;
 return new;
end $$;
create trigger profiles_account_lifecycle_schedule before insert or update of deletion_requested_at,deletion_due_at on public.profiles
 for each row execute function account_lifecycle.mirror_profile_schedule();
revoke all on all functions in schema account_lifecycle from public;
grant execute on function account_lifecycle.claim_due(integer),account_lifecycle.finish(uuid,uuid,boolean),
  account_lifecycle.list_tombstones(uuid,integer),account_lifecycle.replay_tombstone(uuid,uuid,bigint) to pandapay_account_lifecycle;
do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    grant execute on function account_lifecycle.assert_access(uuid),account_lifecycle.request_deletion(uuid),account_lifecycle.cancel_deletion(uuid) to app_user;
  end if;
end $$;
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.lifecycle_migration_role'),true);
do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    grant usage on schema account_lifecycle to app_user;
  end if;
end $$;

revoke create on schema account_lifecycle from account_lifecycle_owner;
revoke trigger on public.profiles from account_lifecycle_owner;
grant usage on schema account_lifecycle to pandapay_account_lifecycle;
-- Disable the historical hard-delete entry point, including its old cron.
-- A dedicated opt-in worker replaces it; no retention/purge policy is assumed.
create or replace function pandapay.execute_account_deletion(p_profile uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
  raise warning 'Legacy hard deletion is disabled; use the durable lifecycle worker';
end $$;
revoke all on function pandapay.execute_account_deletion(uuid) from public;
do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    revoke all on function pandapay.execute_account_deletion(uuid) from app_user;
  end if;
end $$;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.lifecycle_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke account_lifecycle_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant account_lifecycle_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant account_lifecycle_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
