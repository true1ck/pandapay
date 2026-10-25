-- Explicit per-device automatic recovery consent. No existing device is enrolled.
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

grant create on schema account_recovery to account_recovery_owner;
grant references(id) on public.profiles to account_recovery_owner;
grant trigger on account_lifecycle.tombstones to account_recovery_owner;
set local role account_recovery_owner;
create table account_recovery.automatic_devices(
 profile_id uuid not null references public.profiles(id) on delete cascade,
 device_hash text not null check(device_hash ~ '^[0-9a-f]{64}$'),
 include_receipts boolean not null,
 consent_id uuid not null default pg_catalog.gen_random_uuid(),
 consent_version text not null check(consent_version='automatic-account-recovery-v1'),
 enrolled_at timestamptz not null default pg_catalog.clock_timestamp(),
 primary key(profile_id,device_hash)
);
alter table account_recovery.automatic_devices enable row level security;
alter table account_recovery.automatic_devices force row level security;
create policy automatic_owner on account_recovery.automatic_devices to account_recovery_owner using(true) with check(true);
revoke all on account_recovery.automatic_devices from public;

-- The API derives p_device from a signature-verified, current active device
-- session. Only enabling requires recent OTP; disabling remains available to
-- the same active device without another factor. No key retrieval permission
-- is conferred by this consent.
create function account_recovery.set_automatic(p_profile uuid,p_device text,p_enabled boolean,p_receipts boolean)
returns boolean language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$begin
 perform account_recovery.assert_account(p_profile);
 if p_device is null or p_device !~ '^[0-9a-f]{64}$' or p_enabled is null or p_receipts is null then
  raise exception 'Invalid automatic recovery consent' using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(73614,1);
 if not p_enabled then
  delete from account_recovery.automatic_devices where profile_id=p_profile and device_hash=p_device;
  return false;
 end if;
 if not exists(select 1 from account_recovery.automatic_devices where profile_id=p_profile and device_hash=p_device)
  and (select count(*) from account_recovery.automatic_devices where profile_id=p_profile)>=8 then
  delete from account_recovery.automatic_devices where (profile_id,device_hash) in
   (select profile_id,device_hash from account_recovery.automatic_devices where profile_id=p_profile
    order by enrolled_at,device_hash limit 1);end if;
 insert into account_recovery.automatic_devices(profile_id,device_hash,include_receipts,consent_version)
 values(p_profile,p_device,p_receipts,'automatic-account-recovery-v1')
 on conflict(profile_id,device_hash) do update set include_receipts=excluded.include_receipts,consent_id=pg_catalog.gen_random_uuid(),enrolled_at=pg_catalog.clock_timestamp();
 return true;
end $$;
create function account_recovery.get_automatic(p_profile uuid,p_device text)
returns table(include_receipts boolean,consent_id uuid) language plpgsql security definer set search_path='' set statement_timeout='5s' as $$begin
 perform account_recovery.assert_account(p_profile);
 return query select d.include_receipts,d.consent_id from account_recovery.automatic_devices d where d.profile_id=p_profile and d.device_hash=p_device;
end $$;
create function account_recovery.put_automatic_snapshot(p_profile uuid,p_device text,p_consent_id uuid,p_snapshot uuid,p_key bytea,p_key_id text,p_archive bytea,p_hash text,p_receipts boolean,p_unsynced boolean,p_consent text)
returns boolean language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$begin
 perform account_recovery.assert_account(p_profile);
 -- Same lock as consent revocation and snapshot rotation: no guard/write race.
 perform pg_catalog.pg_advisory_xact_lock(73614,1);
 if p_unsynced is distinct from true or not exists(select 1 from account_recovery.automatic_devices
  where profile_id=p_profile and device_hash=p_device and include_receipts=p_receipts and consent_id=p_consent_id) then
  raise exception 'Automatic recovery not authorized' using errcode='42501';end if;
 return account_recovery.put_snapshot(p_profile,p_snapshot,p_key,p_key_id,p_archive,p_hash,p_receipts,p_unsynced,p_consent);
end $$;
create function account_recovery.read_automatic_ciphertext(p_profile uuid,p_device text,p_snapshot uuid)
returns table(snapshot_id uuid,encrypted_archive bytea,archive_sha256 text)
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$begin
 perform account_recovery.assert_account(p_profile);
 if not exists(select 1 from account_recovery.automatic_devices where profile_id=p_profile and device_hash=p_device) then
  raise exception 'Automatic recovery not authorized' using errcode='42501';end if;
 return query select s.snapshot_id,s.encrypted_archive,s.archive_sha256 from account_recovery.snapshots s
  where s.profile_id=p_profile and s.snapshot_id=p_snapshot;
end $$;
-- Discarding all copies also revokes every automatic writer, so another
-- device cannot immediately recreate data the account explicitly discarded.
create or replace function account_recovery.remove_snapshots(p_profile uuid) returns integer
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$declare n integer;begin
 perform account_recovery.assert_account(p_profile);perform pg_catalog.pg_advisory_xact_lock(73614,1);
 delete from account_recovery.automatic_devices where profile_id=p_profile;
 delete from account_recovery.snapshots where profile_id=p_profile;get diagnostics n=row_count;return n;
end $$;
create function account_recovery.clear_deleted_automatic_consent() returns trigger
language plpgsql security definer set search_path='' as $$begin
 perform pg_catalog.pg_advisory_xact_lock(73614,1);
 delete from account_recovery.automatic_devices where profile_id=new.profile_id;
 return new;
end $$;
create trigger clear_deleted_automatic_consent after insert on account_lifecycle.tombstones
 for each row execute function account_recovery.clear_deleted_automatic_consent();
revoke all on function account_recovery.clear_deleted_automatic_consent() from public;
revoke all on function account_recovery.set_automatic(uuid,text,boolean,boolean),account_recovery.get_automatic(uuid,text),
 account_recovery.put_automatic_snapshot(uuid,text,uuid,uuid,bytea,text,bytea,text,boolean,boolean,text),account_recovery.read_automatic_ciphertext(uuid,text,uuid) from public;
do $$begin if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
 grant execute on function account_recovery.set_automatic(uuid,text,boolean,boolean),account_recovery.get_automatic(uuid,text),
 account_recovery.put_automatic_snapshot(uuid,text,uuid,uuid,bytea,text,bytea,text,boolean,boolean,text),account_recovery.read_automatic_ciphertext(uuid,text,uuid) to app_user;
end if;end $$;
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.recovery_migration_role'),true);
revoke create on schema account_recovery from account_recovery_owner;
revoke trigger on account_lifecycle.tombstones from account_recovery_owner;
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
