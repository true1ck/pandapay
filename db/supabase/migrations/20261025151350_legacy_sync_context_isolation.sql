-- B02 / LP01: preserve legacy API signatures and restrict SECURITY DEFINER sync.
-- Additive replacement: no row, UUID, key, cursor, history or cipher rewrite.
-- Identity is trusted only through the backend-set transaction-local app.user_id;
-- PUBLIC/PostgREST callers must not receive this backend credential or GUC power.
-- Full current-clone/consumer/provider acceptance remains required before rollout.
-- The canonical product runner owns the transaction and checksum.

create or replace function pandapay.register_sync_device(
  p_profile     uuid,
  p_platform    text,
  p_label       text default null,
  p_app_version text default null,
  p_device_id   uuid default null
) returns uuid language plpgsql security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device_id is not null then
    update public.user_devices
       set last_seen_at = now(),
           app_version  = coalesce(p_app_version, app_version),
           device_label = coalesce(p_label, device_label)
     where id = p_device_id and profile_id = p_profile
     returning id into v_id;
    if v_id is not null then
      return v_id;
    end if;
    -- Falls through when the id is unknown or belongs to someone else. A
    -- client holding a stale id gets a new device row rather than an error,
    -- because failing here would strand it: it cannot sync without a device,
    -- and it has no way to discover why its id stopped working.
  end if;

  insert into public.user_devices (profile_id, platform, device_label, app_version, last_seen_at)
       values (
         p_profile,
         case when p_platform in ('android','ios','web') then p_platform else 'web' end,
         p_label, p_app_version, now()
       )
    returning id into v_id;

  insert into public.sync_cursors (device_id, profile_id) values (v_id, p_profile)
  on conflict (device_id) do nothing;

  return v_id;
end $$;

create or replace function pandapay.sync_apply_change(
  p_profile      uuid,
  p_device       uuid,
  p_entity       text,
  p_entity_id    uuid,
  p_op           public.sync_op,
  p_payload      jsonb,
  p_field_clocks jsonb,
  p_client_seq   bigint
) returns table(out_applied boolean, out_conflicts int, out_reason text)
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fields text[];
  v_field text;
  v_existing jsonb;
  v_existing_clocks jsonb;
  v_incoming_clock bigint;
  v_existing_clock bigint;
  v_set_pairs text[] := '{}';
  v_merged_clocks jsonb := '{}'::jsonb;
  v_conflicts int := 0;
  v_owned boolean;
  v_sql text;
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  -- Match the API's domain boundary in SQL as well. Never allow the
  -- generic legacy RPC to bypass transaction status/reward reconciliation.
  if p_entity='transactions' and (p_op='delete' or p_payload ? 'status') then
    raise exception 'Transaction transition requires the domain route' using errcode='42501';
  end if;
  v_fields := pandapay.sync_fields_for(p_entity);
  if v_fields is null then
    return query select false, 0, 'unknown_entity'::text; return;
  end if;

  -- Ownership. RLS would also stop a cross-profile write, but this function is
  -- SECURITY DEFINER and therefore bypasses it — so the check has to be
  -- explicit here. Without it, `entity_id` would be a straightforward way to
  -- edit another user's transactions.
  execute format(
    'select exists (select 1 from public.%I where id = $1 and profile_id = $2)', p_entity
  ) into v_owned using p_entity_id, p_profile;

  if p_op = 'delete' then
    if not v_owned then
      return query select false, 0, 'not_found'::text; return;
    end if;
    -- R4 is "archive, never delete" for user_cards, and a delete arriving
    -- over sync must not become the one path that circumvents it.
    if p_entity = 'user_cards' then
      update public.user_cards set is_archived = true, archived_at = now()
       where id = p_entity_id and profile_id = p_profile;
    else
      execute format('delete from public.%I where id = $1 and profile_id = $2', p_entity)
        using p_entity_id, p_profile;
    end if;

    insert into public.change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
         values (p_profile, p_device, p_entity, p_entity_id, 'delete', '{}'::jsonb, '{}'::jsonb, p_client_seq);
    return query select true, 0, null::text; return;
  end if;

  if not v_owned then
    -- An insert of a row this profile doesn't have yet. Deliberately NOT
    -- supported over sync: every entity here is created through a route that
    -- enforces real invariants (a transaction updates cap/milestone/points
    -- state; a user_card checks the product is published). Letting a push
    -- conjure rows would bypass all of it, so a client that wants to create
    -- something calls the ordinary endpoint and syncs edits afterwards.
    return query select false, 0, 'not_found'::text; return;
  end if;

  -- Current values and clocks for the fields being written.
  execute format('select to_jsonb(t) from public.%I t where t.id = $1', p_entity)
    into v_existing using p_entity_id;
  v_existing_clocks := coalesce(
    (select field_clocks from public.change_log
      where entity = p_entity and entity_id = p_entity_id
      order by server_seq desc limit 1),
    '{}'::jsonb);

  foreach v_field in array v_fields loop
    continue when not (p_payload ? v_field);

    v_incoming_clock := coalesce((p_field_clocks ->> v_field)::bigint, 0);
    v_existing_clock := coalesce((v_existing_clocks ->> v_field)::bigint, 0);

    if v_incoming_clock < v_existing_clock then
      -- The incoming write is older than what is already stored for this
      -- field. It loses — but it is recorded, because "your edit was
      -- superseded" is information the user is entitled to.
      v_conflicts := v_conflicts + 1;
      insert into public.sync_conflicts (
        profile_id, entity, entity_id, field, local_value, server_value, chosen_value,
        strategy, device_id
      ) values (
        p_profile, p_entity, p_entity_id, v_field,
        p_payload -> v_field, v_existing -> v_field, v_existing -> v_field,
        'last_write_wins', p_device
      );
      continue;
    end if;

    -- Equal clocks are treated as "incoming wins" rather than as a conflict:
    -- two writes in the same millisecond are almost always the same device
    -- retrying, and logging that as a conflict would fill the user's conflict
    -- log with noise that means nothing.
    if v_incoming_clock = v_existing_clock
       and v_existing_clock > 0
       and (v_existing -> v_field) is distinct from (p_payload -> v_field) then
      v_conflicts := v_conflicts + 1;
      insert into public.sync_conflicts (
        profile_id, entity, entity_id, field, local_value, server_value, chosen_value,
        strategy, device_id
      ) values (
        p_profile, p_entity, p_entity_id, v_field,
        p_payload -> v_field, v_existing -> v_field, p_payload -> v_field,
        'last_write_wins', p_device
      );
    end if;

    v_set_pairs := v_set_pairs || format('%I = ($1 ->> %L)::text', v_field, v_field);
    v_merged_clocks := v_merged_clocks || jsonb_build_object(v_field, v_incoming_clock);
  end loop;

  if array_length(v_set_pairs, 1) is null then
    -- Every field lost. Still logged, so the pull stream and the conflict log
    -- agree about what happened.
    insert into public.change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
         values (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
                 v_existing_clocks, p_client_seq);
    return query select true, v_conflicts, null::text; return;
  end if;

  -- Text-cast assignment lets one statement handle every column type: Postgres
  -- applies the column's own input conversion, so a numeric stays numeric and
  -- an enum is validated as an enum. A malformed value raises here rather than
  -- being silently coerced, which is the behaviour wanted for financial data.
  v_sql := format('update public.%I set %s where id = $2 and profile_id = $3',
                  p_entity, array_to_string(v_set_pairs, ', '));
  execute v_sql using p_payload, p_entity_id, p_profile;

  insert into public.change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
       values (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
               v_existing_clocks || v_merged_clocks, p_client_seq);

  return query select true, v_conflicts, null::text;
end $$;

create or replace function pandapay.sync_pull(
  p_profile uuid,
  p_device  uuid,
  p_since   bigint,
  p_limit   int default 500
) returns table(
  server_seq bigint, entity text, entity_id uuid, op public.sync_op,
  payload jsonb, field_clocks jsonb, created_at timestamptz
) language plpgsql security definer
set search_path = ''
as $$
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  return query
  select c.server_seq, c.entity, c.entity_id, c.op, c.payload, c.field_clocks, c.created_at
    from public.change_log c
   where c.profile_id = p_profile
     and c.server_seq > p_since
     and (c.device_id is distinct from p_device)
   order by c.server_seq
   limit least(greatest(p_limit, 1), 1000);
end $$;

create or replace function pandapay.sync_ack(
  p_profile uuid, p_device uuid, p_server_seq bigint
) returns void language plpgsql security definer
set search_path = ''
as $$
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_server_seq is null or p_server_seq<0 then
    raise exception 'Invalid sync acknowledgement' using errcode='22023';
  end if;
  -- Do not overwrite a historically inconsistent cursor's owner. Preserve
  -- the row for explicit reconciliation and fail the entire request.
  if exists(select 1 from public.sync_cursors c
             where c.device_id=p_device and c.profile_id is distinct from p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  insert into public.sync_cursors (device_id, profile_id, last_server_seq, last_pulled_at)
       values (p_device, p_profile, p_server_seq, now())
  on conflict (device_id) do update
     -- greatest(): an out-of-order or replayed ack must never move the cursor
     -- backwards and cause changes to be delivered twice.
     set last_server_seq = greatest(public.sync_cursors.last_server_seq, excluded.last_server_seq),
         last_pulled_at  = now();
end $$;

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
set search_path = ''
as $$
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 40
     or p_slug is null or length(trim(p_slug)) not between 1 and 80 then
    return query select false, 'malformed'::text;
    return;
  end if;

  insert into public.user_categories(id, profile_id, name, slug)
  values (p_entity_id, p_profile, trim(p_name), trim(p_slug))
  on conflict (id) do update
    set name = excluded.name,
        slug = excluded.slug
  where public.user_categories.profile_id = p_profile;

  if not found then
    return query select false, 'not_found'::text;
    return;
  end if;

  insert into public.change_log(
    profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq
  ) values (
    p_profile, p_device, 'user_categories', p_entity_id, 'insert',
    jsonb_build_object('name', trim(p_name), 'slug', trim(p_slug)),
    coalesce(p_field_clocks, '{}'::jsonb), p_client_seq
  );

  return query select true, null::text;
end $$;

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
set search_path = ''
as $$
declare
  normalized_terms text[];
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 40
     or p_slug is null or length(trim(p_slug)) not between 1 and 80
     or (p_parent_category_id is not null and p_parent_user_category_id is not null)
     or p_parent_user_category_id = p_entity_id then
    return query select false, 'malformed'::text;
    return;
  end if;

  if p_parent_user_category_id is not null and not exists (
    select 1 from public.user_categories
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

  insert into public.user_categories(
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
  where public.user_categories.profile_id = p_profile;

  if not found then
    return query select false, 'not_found'::text;
    return;
  end if;

  insert into public.change_log(
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

create or replace function pandapay.sync_apply_user_merchant_category_rule(
  p_profile uuid, p_device uuid, p_entity_id uuid, p_op public.sync_op,
  p_payload jsonb, p_client_seq bigint
) returns table(out_applied boolean, out_conflicts int, out_reason text)
language plpgsql security definer
set search_path = ''
as $$
declare
  current_rule public.user_merchant_category_rules%rowtype;
  incoming_version bigint;
  incoming_action text;
  incoming_flag text;
  incoming_category uuid;
  incoming_user_category uuid;
  incoming_active boolean;
begin
  if p_profile is null or p_profile is distinct from pandapay.uid()
     or not exists(select 1 from public.profiles p where p.id=p_profile) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_device is null or not exists(
    select 1 from public.user_devices d where d.id=p_device and d.profile_id=p_profile
  ) then
    raise exception 'Sync access denied' using errcode='42501';
  end if;
  if p_op = 'insert' then
    return query select false, 0, 'not_found'::text;
    return;
  end if;
  select * into current_rule from public.user_merchant_category_rules
   where id = p_entity_id and profile_id = p_profile for update;
  if not found then
    return query select false, 0, 'not_found'::text;
    return;
  end if;
  incoming_version := nullif(p_payload->>'version', '')::bigint;
  incoming_action := coalesce(nullif(p_payload->>'action', ''), current_rule.action, 'category');
  incoming_flag := case when p_payload ? 'flag' then nullif(p_payload->>'flag', '') else current_rule.flag end;
  incoming_category := case when p_payload ? 'category_id' then nullif(p_payload->>'category_id', '')::uuid else current_rule.category_id end;
  incoming_user_category := case when p_payload ? 'user_category_id' then nullif(p_payload->>'user_category_id', '')::uuid else current_rule.user_category_id end;
  incoming_active := coalesce((p_payload->>'is_active')::boolean, current_rule.is_active);
  if incoming_version is null or incoming_version <= current_rule.version then
    return query select false, 1, 'stale_revision'::text;
    return;
  end if;
  if incoming_action not in ('category', 'flag') then
    return query select false, 0, 'action_invalid'::text;
    return;
  end if;
  if incoming_action = 'category' then
    if incoming_category is null or not exists (select 1 from public.spend_categories where id = incoming_category)
       or incoming_flag is not null then
      return query select false, 0, 'category_action_target_invalid'::text;
      return;
    end if;
  elsif incoming_flag is null or incoming_category is not null or incoming_user_category is not null then
    return query select false, 0, 'flag_action_target_invalid'::text;
    return;
  end if;
  update public.user_merchant_category_rules set
    action = incoming_action,
    flag = incoming_flag,
    category_id = incoming_category,
    user_category_id = incoming_user_category,
    is_active = incoming_active,
    version = incoming_version,
    updated_at = now()
   where id = p_entity_id and profile_id = p_profile;
  insert into public.change_log(profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    values (p_profile, p_device, 'user_merchant_category_rules', p_entity_id, 'update', p_payload, '{}'::jsonb, p_client_seq);
  return query select true, 0, null::text;
end $$;

-- PUBLIC is a privilege group, not a substitute for authenticated backend identity.
revoke execute on function pandapay.register_sync_device(uuid,text,text,text,uuid) from public restrict;
revoke execute on function pandapay.sync_apply_change(uuid,uuid,text,uuid,public.sync_op,jsonb,jsonb,bigint) from public restrict;
revoke execute on function pandapay.sync_pull(uuid,uuid,bigint,integer) from public restrict;
revoke execute on function pandapay.sync_ack(uuid,uuid,bigint) from public restrict;
revoke execute on function pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,jsonb,bigint) from public restrict;
revoke execute on function pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,uuid,uuid,text[],jsonb,bigint) from public restrict;
revoke execute on function pandapay.sync_apply_user_merchant_category_rule(uuid,uuid,uuid,public.sync_op,jsonb,bigint) from public restrict;

do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    execute 'grant execute on function pandapay.register_sync_device(uuid,text,text,text,uuid) to app_user';
    execute 'grant execute on function pandapay.sync_apply_change(uuid,uuid,text,uuid,public.sync_op,jsonb,jsonb,bigint) to app_user';
    execute 'grant execute on function pandapay.sync_pull(uuid,uuid,bigint,integer) to app_user';
    execute 'grant execute on function pandapay.sync_ack(uuid,uuid,bigint) to app_user';
    execute 'grant execute on function pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,jsonb,bigint) to app_user';
    execute 'grant execute on function pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,uuid,uuid,text[],jsonb,bigint) to app_user';
    execute 'grant execute on function pandapay.sync_apply_user_merchant_category_rule(uuid,uuid,uuid,public.sync_op,jsonb,bigint) to app_user';
  end if;
end $$;
