-- User categories can be top-level private categories or children of either
-- a published category (Travel -> Office) or another private category.
alter table user_categories
  add column if not exists parent_category_id uuid references spend_categories(id) on delete cascade,
  add column if not exists parent_user_category_id uuid references user_categories(id) on delete cascade,
  add column if not exists match_terms text[] not null default '{}';

alter table user_categories
  drop constraint if exists user_categories_one_parent;
alter table user_categories
  add constraint user_categories_one_parent check (
    not (parent_category_id is not null and parent_user_category_id is not null)
    and (parent_user_category_id is null or parent_user_category_id <> id)
  );

create index if not exists idx_user_categories_parent_category
  on user_categories(profile_id, parent_category_id, name);
create index if not exists idx_user_categories_parent_user_category
  on user_categories(profile_id, parent_user_category_id, name);

-- The old seven-argument function remains valid for already-queued devices;
-- new clients use this richer overload.
create or replace function pandapay.sync_insert_user_category(
  p_profile uuid,
  p_device uuid,
  p_entity_id uuid,
  p_name text,
  p_slug text,
  p_parent_category_id uuid,
  p_parent_user_category_id uuid,
  p_match_terms text[],
  p_field_clocks jsonb,
  p_client_seq bigint
) returns table(out_applied boolean, out_reason text)
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  normalized_terms text[];
begin
  if p_name is null or length(trim(p_name)) not between 1 and 40
     or p_slug is null or length(trim(p_slug)) not between 1 and 80
     or (p_parent_category_id is not null and p_parent_user_category_id is not null)
     or p_parent_user_category_id = p_entity_id then
    return query select false, 'malformed'::text;
    return;
  end if;

  if p_parent_user_category_id is not null and not exists (
    select 1 from user_categories
     where id = p_parent_user_category_id and profile_id = p_profile
  ) then
    return query select false, 'not_found'::text;
    return;
  end if;

  normalized_terms := coalesce(
    array(
      select lower(trim(term))
        from unnest(coalesce(p_match_terms, '{}'::text[])) as term
       where length(trim(term)) between 2 and 60
    ), '{}'
  );

  insert into user_categories(
    id, profile_id, name, slug, parent_category_id,
    parent_user_category_id, match_terms
  ) values (
    p_entity_id, p_profile, trim(p_name), trim(p_slug), p_parent_category_id,
    p_parent_user_category_id, normalized_terms
  )
  on conflict (id) do update set
    name = excluded.name,
    slug = excluded.slug,
    parent_category_id = excluded.parent_category_id,
    parent_user_category_id = excluded.parent_user_category_id,
    match_terms = excluded.match_terms
  where user_categories.profile_id = p_profile;

  insert into change_log(
    profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq
  ) values (
    p_profile, p_device, 'user_categories', p_entity_id, 'insert',
    jsonb_build_object(
      'name', trim(p_name), 'slug', trim(p_slug),
      'parent_category_id', p_parent_category_id,
      'parent_user_category_id', p_parent_user_category_id,
      'match_terms', to_jsonb(normalized_terms)
    ),
    coalesce(p_field_clocks, '{}'::jsonb), p_client_seq
  );

  return query select true, null::text;
end $$;

grant execute on function pandapay.sync_insert_user_category(uuid, uuid, uuid, text, text, uuid, uuid, text[], jsonb, bigint) to public;
