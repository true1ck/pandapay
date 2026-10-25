-- B04/R4: publish only a bounded sanitized statement about a fresh paired-v5
-- restore. Legacy backup_runs/restore_drills (including old stub successes)
-- are deliberately not a source. No credentials, paths, object names, raw
-- errors or manifest metadata enter this projection.
do $$
declare v_role text;
begin
  foreach v_role in array array['backup_status_owner','backup_status_writer','backup_status_reader'] loop
    if not exists (select 1 from pg_roles where rolname=v_role) then
      execute format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls',v_role);
    end if;
    if exists (select 1 from pg_roles where rolname=v_role and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls or rolinherit)) then
      raise exception 'Backup status capability roles must remain non-login and unprivileged';
    end if;
    if exists (select 1 from pg_auth_members where member=v_role::regrole) then
      raise exception 'Backup status capability roles must not inherit other roles';
    end if;
  end loop;
end $$;

-- Managed PostgreSQL 16+ CREATEROLE administrators may have ADMIN but not
-- SET on a new role. Add a separate, explicitly attributed temporary SET
-- grant and restore exactly its prior options below. Preserve the managed
-- bootstrap grantor's ADMIN membership throughout.
do $$
declare v_prior jsonb;
begin
  select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option)
    into v_prior from pg_catalog.pg_auth_members m
    where m.roleid='backup_status_owner'::regrole
      and m.member=current_user::regrole and m.grantor=current_user::regrole;
  perform pg_catalog.set_config('pandapay.backup_status_owner_prior_grant',coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.backup_status_migration_role',current_user,true);
  execute pg_catalog.format('grant backup_status_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant backup_status_owner to %I with set true granted by %I',current_user,current_user);
end $$;

create schema if not exists backup_status;
revoke all on schema backup_status from public;
grant usage, create on schema backup_status to backup_status_owner;
grant usage on schema public, pandapay to backup_status_owner;
grant select (id) on public.profiles to backup_status_owner;
grant execute on function pandapay.uid() to backup_status_owner;

set local role backup_status_owner;

create table if not exists backup_status.attestations (
  set_id text primary key check (set_id ~ '^[0-9a-f]{32}$'),
  manifest_sha256 text not null check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  completed_at timestamptz not null,
  size_bytes bigint not null check (size_bytes between 1 and 137438953472),
  storage text not null check (storage in ('local','offhost')),
  verified_at timestamptz not null,
  application_check text not null check (application_check in ('passed','not_run')),
  upgrade_check text not null check (upgrade_check in ('passed','not_run')),
  published_at timestamptz not null default clock_timestamp()
);
alter table backup_status.attestations enable row level security;
alter table backup_status.attestations force row level security;
drop policy if exists backup_status_owner_only on backup_status.attestations;
create policy backup_status_owner_only on backup_status.attestations
  for all to backup_status_owner using (true) with check (true);
revoke all on backup_status.attestations from public;

create or replace function backup_status.publish_verified_status(
  p_set_id text, p_manifest_sha256 text, p_completed_at timestamptz,
  p_size_bytes bigint, p_storage text, p_verified_at timestamptz,
  p_application_check text, p_upgrade_check text
) returns boolean
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_previous backup_status.attestations%rowtype;
begin
  -- This function trusts only a separately provisioned recovery publisher.
  -- It cannot verify a filesystem proof itself; the source publisher binds
  -- all three ciphertext digests to a newly generated restore proof first.
  if p_set_id is null or p_set_id !~ '^[0-9a-f]{32}$' or
     p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' or
     p_completed_at is null or not isfinite(p_completed_at) or
     p_verified_at is null or not isfinite(p_verified_at) or
     p_size_bytes is null or p_size_bytes not between 1 and 137438953472 or
     p_storage is null or p_storage not in ('local','offhost') or
     p_application_check is null or p_application_check not in ('passed','not_run') or
     p_upgrade_check is null or p_upgrade_check not in ('passed','not_run') or
     p_completed_at < v_now - interval '48 hours' or p_completed_at > v_now + interval '5 minutes' or
     p_verified_at < v_now - interval '48 hours' or p_verified_at > v_now + interval '5 minutes' or
     p_verified_at < p_completed_at - interval '1 second' then
    raise exception using errcode='22023', message='Backup status evidence rejected';
  end if;
  -- Serialize the small retention operation: concurrent publishers cannot
  -- exceed the cap or race a same-set digest replacement.
  perform pg_advisory_xact_lock(1112755796,1398030676);
  select * into v_previous from backup_status.attestations where set_id=p_set_id for update;
  if found and (v_previous.manifest_sha256 <> p_manifest_sha256 or
      v_previous.completed_at <> p_completed_at or v_previous.size_bytes <> p_size_bytes or
      v_previous.storage <> p_storage or v_previous.verified_at > p_verified_at or
      (v_previous.application_check='passed' and p_application_check<>'passed') or
      (v_previous.upgrade_check='passed' and p_upgrade_check<>'passed')) then
    raise exception using errcode='22023', message='Backup status evidence rejected';
  end if;
  insert into backup_status.attestations
    (set_id,manifest_sha256,completed_at,size_bytes,storage,verified_at,application_check,upgrade_check,published_at)
  values (p_set_id,p_manifest_sha256,p_completed_at,p_size_bytes,p_storage,p_verified_at,
          p_application_check,p_upgrade_check,v_now)
  on conflict (set_id) do update set verified_at=excluded.verified_at,
    application_check=excluded.application_check,upgrade_check=excluded.upgrade_check,published_at=v_now;
  delete from backup_status.attestations where set_id in (
    select set_id from backup_status.attestations
    order by completed_at desc, verified_at desc, set_id desc offset 32
  );
  return true;
end $$;

create or replace function backup_status.read_status(p_profile_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog
as $$
declare
  v_status backup_status.attestations%rowtype;
  v_stale boolean;
begin
  -- PandaPay uses its own verified JWT session, not Supabase auth.uid().
  -- The API sets this value transaction-locally after session verification.
  -- Also bind the requested profile and prove it exists under profile RLS.
  if p_profile_id is null or pandapay.uid() is null or p_profile_id <> pandapay.uid() or
      not exists (select 1 from public.profiles where id=p_profile_id) then
    raise exception using errcode='42501', message='Backup status identity required';
  end if;
  select * into v_status from backup_status.attestations
    order by completed_at desc, verified_at desc, set_id desc limit 1;
  if not found then
    return jsonb_build_object('latestBackup',null,'latestRestoreDrill',null,
      'backupAvailability','unavailable','backupStatusReason','verified_status_not_published','backupVerification',null);
  end if;
  v_stale := v_status.completed_at < now() - interval '48 hours' or
             v_status.verified_at < now() - interval '48 hours';
  return jsonb_build_object(
    'latestBackup',jsonb_build_object('ran_at',v_status.completed_at,
      'status',case when v_stale then 'stale' else 'success' end,'size_bytes',v_status.size_bytes),
    'latestRestoreDrill',jsonb_build_object('ran_at',v_status.verified_at,'restored_ok',true),
    'backupAvailability',case when v_stale then 'stale' else 'available' end,
    'backupStatusReason',case when v_stale then 'verified_status_stale' else null end,
    'backupVerification',jsonb_build_object('protocol','paired_v5','databaseRestoreVerified',true,
      'applicationCheck',v_status.application_check,'upgradeCheck',v_status.upgrade_check,
      'storage',v_status.storage,'publishedAt',v_status.published_at)
  );
end $$;

revoke all on function backup_status.read_status(uuid) from public;
revoke all on function backup_status.publish_verified_status(text,text,timestamptz,bigint,text,timestamptz,text,text) from public;
grant execute on function backup_status.read_status(uuid) to backup_status_reader;
grant execute on function backup_status.publish_verified_status(text,text,timestamptz,bigint,text,timestamptz,text,text)
  to backup_status_writer;
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.backup_status_migration_role'),true);
revoke create on schema backup_status from backup_status_owner;

grant usage on schema backup_status to backup_status_writer,backup_status_reader;
-- This role is a NOLOGIN capability only. The reviewed deployment bootstrap
-- may grant it to one dedicated publisher login; never to app_user.
do $$ begin
  if exists (select 1 from pg_roles where rolname='app_user') then
    grant backup_status_reader to app_user;
  end if;
end $$;

do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.backup_status_owner_prior_grant')::jsonb;
begin
  if v_prior='null'::jsonb then
    execute pg_catalog.format('revoke backup_status_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant backup_status_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant backup_status_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
