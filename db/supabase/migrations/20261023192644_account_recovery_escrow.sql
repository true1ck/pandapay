-- Private account recovery capability; no public or app_user execution rights.
do $$
declare v_role text;
begin
  foreach v_role in array array['account_recovery_owner'] loop
    if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
      execute pg_catalog.format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls', v_role);
    elsif exists (select 1 from pg_catalog.pg_roles where rolname = v_role and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
      raise exception 'Unsafe existing account recovery role';
    end if;
    if exists (select 1 from pg_catalog.pg_auth_members where member = v_role::regrole) then
      raise exception 'account recovery roles must not inherit or SET other roles';
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
    where m.roleid = 'account_recovery_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.recovery_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.recovery_migration_role',current_user,true);
  execute pg_catalog.format('grant account_recovery_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant account_recovery_owner to %I with set true granted by %I',current_user,current_user);
end $$;

-- Opt-in account recovery. Opaque encrypted device payloads and wrapped keys
-- travel with normal paired PostgreSQL dumps; the original server wrapping key
-- must be retained separately. Existing phone-only data is never uploaded here.
create schema account_recovery;
revoke all on schema account_recovery from public;
grant usage,create on schema account_recovery to account_recovery_owner;
grant usage on schema public,pandapay,account_lifecycle to account_recovery_owner;
grant execute on function pandapay.uid() to account_recovery_owner;
do $$begin execute pg_catalog.format('grant connect on database %I to account_recovery_owner',pg_catalog.current_database());end $$;
grant select(profile_id) on account_lifecycle.tombstones to account_recovery_owner;
create policy lifecycle_recovery_read on account_lifecycle.tombstones for select to account_recovery_owner using(true);
create table account_recovery.control(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into account_recovery.control(singleton) values(true);
create table account_recovery.snapshots(
 snapshot_id uuid primary key,profile_id uuid not null,
 wrapped_key bytea not null check(pg_catalog.octet_length(wrapped_key)=60),
 wrapping_key_id text not null check(wrapping_key_id~'^[a-zA-Z0-9_-]{1,64}$'),
 encrypted_archive bytea not null check(pg_catalog.octet_length(encrypted_archive) between 46 and 5242880),
 archive_sha256 text not null check(archive_sha256~'^[0-9a-f]{64}$'),
 include_receipts boolean not null,include_unsynced boolean not null,
 consent_version text not null check(consent_version='account-recovery-v1'),
 created_at timestamptz not null default pg_catalog.now()
);
create index account_recovery_profile on account_recovery.snapshots(profile_id,created_at desc,snapshot_id);
do $$ declare t text;begin foreach t in array array['control','snapshots'] loop
 execute pg_catalog.format('revoke all on account_recovery.%I from public',t);
 execute pg_catalog.format('alter table account_recovery.%I enable row level security',t);
 execute pg_catalog.format('alter table account_recovery.%I force row level security',t);
 execute pg_catalog.format('grant select,insert,delete on account_recovery.%I to account_recovery_owner',t);
 execute pg_catalog.format('create policy recovery_owner on account_recovery.%I for all to account_recovery_owner using(true) with check(true)',t);
 execute pg_catalog.format('create policy recovery_operator on account_recovery.%I for all to %I using(true) with check(true)',t,current_user);
end loop;end $$;
set local role account_recovery_owner;
create function account_recovery.assert_account(p_profile uuid) returns void
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$begin
 if p_profile is null or p_profile is distinct from pandapay.uid() then raise exception 'Recovery access denied' using errcode='42501';end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(p_profile::text,73612));
 if exists(select 1 from account_lifecycle.tombstones where profile_id=p_profile) then raise exception 'Recovery access denied' using errcode='42501';end if;
 if not exists(select 1 from account_recovery.control where singleton and enabled) then raise exception 'Account recovery disabled' using errcode='55000';end if;
end $$;
create function account_recovery.put_snapshot(p_profile uuid,p_snapshot uuid,p_key bytea,p_key_id text,p_archive bytea,p_hash text,p_receipts boolean,p_unsynced boolean,p_consent text) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare existing account_recovery.snapshots%rowtype;used bigint;replaced bigint;begin
 perform account_recovery.assert_account(p_profile);
 if p_snapshot is null or p_key is null or pg_catalog.octet_length(p_key)<>60 or p_key_id is null or p_key_id!~'^[a-zA-Z0-9_-]{1,64}$'
 or p_archive is null or pg_catalog.octet_length(p_archive) not between 46 and 5242880 or p_hash is null
 or p_hash<>pg_catalog.encode(pg_catalog.sha256(p_archive),'hex') or p_receipts is null or p_unsynced is null or p_consent is distinct from 'account-recovery-v1'
 then raise exception 'Invalid account recovery snapshot' using errcode='22023';end if;
 -- Global serialized quota includes every account and cannot evict another account.
 perform pg_catalog.pg_advisory_xact_lock(73614,1);
 select * into existing from account_recovery.snapshots where snapshot_id=p_snapshot;
 if found then
  if existing.profile_id<>p_profile then raise exception 'Recovery access denied' using errcode='42501';end if;
  if existing.archive_sha256<>p_hash or existing.include_receipts<>p_receipts or existing.include_unsynced<>p_unsynced then raise exception 'Snapshot id conflict' using errcode='23514';end if;
  return false;
 end if;
 if exists(select 1 from account_recovery.snapshots where profile_id=p_profile and created_at>pg_catalog.clock_timestamp()-interval '15 minutes') then
  raise exception 'Account recovery upload cooldown' using errcode='P0001';
 end if;
 -- Leave conservative physical headroom on the current free PostgreSQL host;
 -- TOAST/dead tuples count too. Ordinary product writes are not changed.
 if pg_catalog.pg_database_size(pg_catalog.current_database())>367001600 then raise exception 'Account recovery storage quota reached' using errcode='54000';end if;
 select coalesce(sum(pg_catalog.octet_length(encrypted_archive)+pg_catalog.octet_length(wrapped_key)),0) into used from account_recovery.snapshots;
 select coalesce(sum(n.bytes),0) into replaced from(select pg_catalog.octet_length(encrypted_archive)+pg_catalog.octet_length(wrapped_key) as bytes
 from account_recovery.snapshots where profile_id=p_profile order by created_at desc,snapshot_id desc offset 1)n;
 if used-replaced+pg_catalog.octet_length(p_archive)+pg_catalog.octet_length(p_key)>52428800 then raise exception 'Account recovery storage quota reached' using errcode='54000';end if;
 insert into account_recovery.snapshots values(p_snapshot,p_profile,p_key,p_key_id,p_archive,p_hash,p_receipts,p_unsynced,p_consent,pg_catalog.clock_timestamp());
 -- Retain the new verified ciphertext plus the previous snapshot, atomically.
 delete from account_recovery.snapshots where snapshot_id in(select snapshot_id from account_recovery.snapshots where profile_id=p_profile order by created_at desc,snapshot_id desc offset 2);
 return true;
end $$;
create function account_recovery.read_snapshot(p_profile uuid,p_snapshot uuid)
returns setof account_recovery.snapshots language plpgsql security definer set search_path='' set statement_timeout='5s' as $$begin
 perform account_recovery.assert_account(p_profile);
 return query select * from account_recovery.snapshots where profile_id=p_profile and snapshot_id=p_snapshot;
end $$;
create function account_recovery.list_snapshots(p_profile uuid)
returns table(snapshot_id uuid,created_at timestamptz,encrypted_bytes integer,archive_sha256 text,include_receipts boolean,include_unsynced boolean)
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$begin
 perform account_recovery.assert_account(p_profile);
 return query select s.snapshot_id,s.created_at,pg_catalog.octet_length(s.encrypted_archive),s.archive_sha256,s.include_receipts,s.include_unsynced from account_recovery.snapshots s where s.profile_id=p_profile order by s.created_at desc,s.snapshot_id desc limit 2;
end $$;
create function account_recovery.remove_snapshots(p_profile uuid) returns integer
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$declare n integer;begin
 perform account_recovery.assert_account(p_profile);perform pg_catalog.pg_advisory_xact_lock(73614,1);
 delete from account_recovery.snapshots where profile_id=p_profile;get diagnostics n=row_count;return n;
end $$;
revoke all on all functions in schema account_recovery from public;
do $$begin if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
 grant execute on function account_recovery.put_snapshot(uuid,uuid,bytea,text,bytea,text,boolean,boolean,text),account_recovery.read_snapshot(uuid,uuid),account_recovery.list_snapshots(uuid),account_recovery.remove_snapshots(uuid) to app_user;
end if;end $$;
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.recovery_migration_role'),true);
revoke create on schema account_recovery from account_recovery_owner;
do $$begin if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then grant usage on schema account_recovery to app_user;end if;end $$;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.recovery_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke account_recovery_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant account_recovery_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant account_recovery_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
