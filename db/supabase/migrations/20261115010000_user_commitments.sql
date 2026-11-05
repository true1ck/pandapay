-- Bills and reminders a person adds or edits by hand. Until now the only copy
-- lived on the phone, so signing out (which wipes the phone) or moving to a new
-- phone lost them. They travel through the normal sync log like categories do.
--
-- The whole bill is stored as one JSON document: it is edited as a unit, and
-- the phone owns its shape. The newest push replaces the document. Deletes
-- keep a tombstone so a phone that is still offline cannot bring a deleted
-- bill back.
create table if not exists user_commitments (
  id          uuid primary key,
  profile_id  uuid not null references profiles(id) on delete cascade,
  payload     jsonb not null
              check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 16384),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create index if not exists idx_user_commitments_profile
  on user_commitments(profile_id, updated_at);

create trigger trg_user_commitments_touch before update on user_commitments
  for each row execute function pandapay.touch_updated_at();

alter table user_commitments enable row level security;
alter table user_commitments force row level security;
drop policy if exists user_commitments_owner on user_commitments;
create policy user_commitments_owner on user_commitments
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    execute 'grant select, insert, update, delete on user_commitments to app_user';
  end if;
end $$;

-- Generic sync_apply_change refuses inserts, and a bill has no derived state,
-- so it gets its own function (same shape as the merchant-rule one): it checks
-- the caller and device, validates the document, writes the row and records
-- the change so other phones receive it through sync_pull.
create or replace function pandapay.sync_apply_user_commitment(
  p_profile uuid, p_device uuid, p_entity_id uuid, p_op public.sync_op,
  p_payload jsonb, p_client_seq bigint
) returns table(out_applied boolean, out_conflicts int, out_reason text)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_existing public.user_commitments%rowtype;
  v_inserted boolean;
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id = p_profile) then
    raise exception 'Sync access denied' using errcode = '42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id = p_device and d.profile_id = p_profile
  ) then
    raise exception 'Sync access denied' using errcode = '42501';
  end if;

  select * into v_existing from public.user_commitments where id = p_entity_id for update;
  if found and v_existing.profile_id <> p_profile then
    -- Never reveal or touch another account's row.
    return query select false, 0, 'not_found'::text;
    return;
  end if;

  if p_op = 'delete' then
    if not found then
      return query select false, 0, 'not_found'::text;
      return;
    end if;
    if v_existing.deleted_at is null then
      update public.user_commitments
         set deleted_at = now(), payload = '{}'::jsonb
       where id = p_entity_id and profile_id = p_profile;
      insert into public.change_log(profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
        values (p_profile, p_device, 'user_commitments', p_entity_id, 'delete', '{}'::jsonb, '{}'::jsonb, p_client_seq);
    end if;
    return query select true, 0, null::text;
    return;
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 16384
     or jsonb_typeof(p_payload -> 'id') is distinct from 'string' then
    return query select false, 0, 'malformed'::text;
    return;
  end if;
  if found and v_existing.deleted_at is not null then
    -- Deleted elsewhere. Accept and ignore so the phone's queue drains; the
    -- delete reaches that phone through sync_pull.
    return query select true, 0, null::text;
    return;
  end if;

  v_inserted := not found;
  if v_inserted then
    insert into public.user_commitments(id, profile_id, payload)
      values (p_entity_id, p_profile, p_payload);
  else
    update public.user_commitments set payload = p_payload
     where id = p_entity_id and profile_id = p_profile;
  end if;
  insert into public.change_log(profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    values (p_profile, p_device, 'user_commitments', p_entity_id,
            case when v_inserted then 'insert'::public.sync_op else 'update'::public.sync_op end,
            p_payload, '{}'::jsonb, p_client_seq);
  return query select true, 0, null::text;
end $$;

revoke execute on function pandapay.sync_apply_user_commitment(uuid,uuid,uuid,public.sync_op,jsonb,bigint) from public restrict;
do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    execute 'grant execute on function pandapay.sync_apply_user_commitment(uuid,uuid,uuid,public.sync_op,jsonb,bigint) to app_user';
  end if;
end $$;

comment on table user_commitments is
  'Hand-entered and hand-edited bills (one JSON document each), synced between a person''s phones.';
