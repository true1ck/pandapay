-- Private account lifecycle capability; no public or app_user execution rights.
do $$
declare v_role text;
begin
  foreach v_role in array array['auth_lifecycle_owner', 'pandapay_auth_lifecycle'] loop
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
    where m.roleid = 'auth_lifecycle_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.auth_lifecycle_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.auth_lifecycle_migration_role',current_user,true);
  execute pg_catalog.format('grant auth_lifecycle_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant auth_lifecycle_owner to %I with set true granted by %I',current_user,current_user);
end $$;

-- Immutable identity tombstones survive contact reuse and snapshot restoration.
-- This migration preserves all users, contacts, devices, tokens and history.
create schema if not exists auth_private;
revoke all on schema auth_private from public;
grant usage,create on schema auth_private to auth_lifecycle_owner;
grant usage on schema public to auth_lifecycle_owner;
create table auth_private.account_deletion_tombstones (
  request_id uuid primary key,
  user_id uuid not null unique,
  generation bigint not null check(generation>0),
  applied_at timestamptz not null default pg_catalog.now()
);
revoke all on auth_private.account_deletion_tombstones from public;
alter table auth_private.account_deletion_tombstones enable row level security;
alter table auth_private.account_deletion_tombstones force row level security;
grant select,insert on auth_private.account_deletion_tombstones to auth_lifecycle_owner;
create policy lifecycle_owner on auth_private.account_deletion_tombstones for all to auth_lifecycle_owner using(true) with check(true);
create policy lifecycle_operator on auth_private.account_deletion_tombstones for all to current_user using(true) with check(true);
grant select(id,is_active,deleted,token_version),update(is_active,deleted,token_version,updated_at) on public.users to auth_lifecycle_owner;
grant select(user_id,is_active),update(is_active) on public.user_devices to auth_lifecycle_owner;
grant select(user_id,revoked_at),update(revoked_at) on public.refresh_tokens to auth_lifecycle_owner;
grant trigger on public.users to auth_lifecycle_owner;

set local role auth_lifecycle_owner;
create function auth_private.apply_account_deletion(p_request uuid,p_user uuid,p_generation bigint) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare t auth_private.account_deletion_tombstones%rowtype; fresh boolean:=false;
begin
  if p_request is null or p_user is null or p_generation is null or p_generation<1 then
    raise exception 'Invalid deletion tombstone' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text,73613));
  perform 1 from public.users where id=p_user for update;
  select * into t from auth_private.account_deletion_tombstones where request_id=p_request or user_id=p_user;
  if found then
    if t.request_id<>p_request or t.user_id<>p_user or t.generation<>p_generation then
      raise exception 'Deletion tombstone conflicts with retained history' using errcode='23514';
    end if;
  else
    insert into auth_private.account_deletion_tombstones(request_id,user_id,generation) values(p_request,p_user,p_generation);
    fresh:=true;
  end if;
  update public.users set is_active=false,deleted=true,token_version=case when coalesce(token_version,1)<2147483647 then coalesce(token_version,1)+1 else token_version end,updated_at=pg_catalog.now()
    where id=p_user and (is_active or not deleted);
  update public.user_devices set is_active=false where user_id=p_user and is_active;
  update public.refresh_tokens set revoked_at=pg_catalog.now() where user_id=p_user and revoked_at is null;
  return fresh;
end $$;

create function auth_private.fence_deleted_identity() returns trigger
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$
begin
  -- BEFORE UPDATE can already hold a users-row lock. Do not wait for a
  -- deletion's exclusive fence while it waits for that row; retry instead.
  if not pg_catalog.pg_try_advisory_xact_lock_shared(pg_catalog.hashtextextended(new.id::text,73613)) then
    raise exception 'Identity lifecycle update must retry' using errcode='40001';
  end if;
  if exists(select 1 from auth_private.account_deletion_tombstones where user_id=new.id) then
    new.is_active:=false; new.deleted:=true;
    if tg_op='UPDATE' then new.token_version:=greatest(new.token_version,old.token_version); end if;
  end if;
  return new;
end $$;

create function auth_private.list_deletion_tombstones(p_after uuid,p_limit integer)
returns table(request_id uuid,user_id uuid,generation bigint)
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$
begin
  if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid replay batch size' using errcode='22023'; end if;
  return query select t.request_id,t.user_id,t.generation from auth_private.account_deletion_tombstones t
    where p_after is null or t.user_id>p_after order by t.user_id limit p_limit;
end $$;
revoke all on function auth_private.apply_account_deletion(uuid,uuid,bigint),auth_private.fence_deleted_identity(),auth_private.list_deletion_tombstones(uuid,integer) from public;
grant execute on function auth_private.apply_account_deletion(uuid,uuid,bigint),auth_private.list_deletion_tombstones(uuid,integer) to pandapay_auth_lifecycle;
create trigger users_account_deletion_fence before insert or update on public.users
  for each row execute function auth_private.fence_deleted_identity();
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.auth_lifecycle_migration_role'),true);
revoke trigger on public.users from auth_lifecycle_owner;
revoke create on schema auth_private from auth_lifecycle_owner;
grant usage on schema auth_private to pandapay_auth_lifecycle;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.auth_lifecycle_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke auth_lifecycle_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant auth_lifecycle_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant auth_lifecycle_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
