-- User-created categories are private account data, not catalogue rows.
-- They are created locally first and arrive here through the normal sync
-- change log, so the same category is available on every signed-in device.
create table if not exists user_categories (
  id         uuid primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 40),
  slug       text not null check (length(trim(slug)) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_user_categories_profile
  on user_categories(profile_id, created_at, name);

create trigger trg_user_categories_touch before update on user_categories
  for each row execute function pandapay.touch_updated_at();

alter table user_categories enable row level security;
alter table user_categories force row level security;
drop policy if exists user_categories_owner on user_categories;
create policy user_categories_owner on user_categories
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

-- Inserts need a SECURITY DEFINER function because sync_apply_change
-- deliberately rejects generic inserts: transactions and cards have side
-- effects and must be created through their domain endpoints. A category has
-- no derived state, so this function validates and records the insert while
-- preserving the same append-only change log used by pull on other devices.
create or replace function pandapay.sync_insert_user_category(
  p_profile uuid,
  p_device uuid,
  p_entity_id uuid,
  p_name text,
  p_slug text,
  p_field_clocks jsonb,
  p_client_seq bigint
) returns table(out_applied boolean, out_reason text)
language plpgsql security definer
set search_path = public, pandapay
as $$
begin
  if p_name is null or length(trim(p_name)) not between 1 and 40
     or p_slug is null or length(trim(p_slug)) not between 1 and 80 then
    return query select false, 'malformed'::text;
    return;
  end if;

  insert into user_categories(id, profile_id, name, slug)
  values (p_entity_id, p_profile, trim(p_name), trim(p_slug))
  on conflict (id) do update
    set name = excluded.name,
        slug = excluded.slug
  where user_categories.profile_id = p_profile;

  insert into change_log(
    profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq
  ) values (
    p_profile, p_device, 'user_categories', p_entity_id, 'insert',
    jsonb_build_object('name', trim(p_name), 'slug', trim(p_slug)),
    coalesce(p_field_clocks, '{}'::jsonb), p_client_seq
  );

  return query select true, null::text;
end $$;

grant execute on function pandapay.sync_insert_user_category(uuid, uuid, uuid, text, text, jsonb, bigint) to public;
