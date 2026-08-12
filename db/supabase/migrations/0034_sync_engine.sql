-- >>> MIGRATION 0034 — SYNC ENGINE ============================================
--
-- Plan Phase 4. `change_log`, `sync_cursors` and `sync_conflicts` have existed
-- since 0005_sync.sql and have never had a row written to them. This is the
-- producer and consumer that migration was designed for.
--
-- 0005's header states the requirement plainly: "silent data loss during sync
-- is the fastest way to lose a finance user." Everything below follows from
-- taking that literally.
--
-- ============================================================================
-- WHY PER-FIELD, NOT PER-ROW
-- ============================================================================
-- The naive design is row-level last-write-wins: whoever wrote most recently
-- replaces the row. For this data that silently destroys work. A user
-- categorises a transaction on their phone; on their tablet, thirty seconds
-- earlier, they had typed a note on the same transaction. Row-level LWW throws
-- the note away — and tells nobody, because from the server's point of view
-- one complete row simply replaced another.
--
-- So each row carries `field_clocks`: a jsonb map of field name -> the
-- millisecond timestamp at which THAT FIELD was last set, on whichever device
-- set it. A field is overwritten only when the incoming clock for that field
-- is newer. The note and the category both survive, because they were never
-- in competition.
--
-- ============================================================================
-- WHY CONFLICTS ARE RECORDED EVEN THOUGH THEY RESOLVE AUTOMATICALLY
-- ============================================================================
-- When two devices genuinely set the SAME field, one value has to lose. The
-- resolution is automatic (newest clock wins), but the losing value is written
-- to `sync_conflicts` rather than discarded. That row is the difference
-- between "the app changed my note" and "the app changed my note, told me, and
-- can show me what it was". F5's conflict log renders exactly this.
--
-- ============================================================================
-- WHAT IS AND IS NOT SYNCED
-- ============================================================================
-- Three entities: `transactions`, `user_cards`, `card_overrides`. These are
-- what a user edits by hand and would notice losing.
--
-- Deliberately excluded, and not by oversight:
--   * `cap_states` / `milestone_states` / `points_ledger` — DERIVED from
--     transactions by the server. Syncing them would let two devices disagree
--     about arithmetic; recomputing from synced transactions cannot.
--   * anything in the catalogue — server-owned, pull-only, already versioned.
--   * `analytics_events` — append-only telemetry, no edit to conflict over.

-- ---------------------------------------------------------------------------
-- Which columns participate, per entity
-- ---------------------------------------------------------------------------
-- An allowlist, not "every column". Server-computed fields (`profile_id`,
-- `dedupe_hash`, `created_at`, the reward projections) must never be writable
-- by a client push — a device could otherwise rewrite its own reward history,
-- and `profile_id` in particular would be a cross-account write primitive.
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;

create or replace function pandapay.is_syncable_entity(p_entity text)
returns boolean language sql immutable as $$
  select pandapay.sync_fields_for(p_entity) is not null;
$$;

-- ---------------------------------------------------------------------------
-- Device registration
-- ---------------------------------------------------------------------------
-- `change_log.device_id` and `sync_cursors.device_id` both reference the
-- PRODUCT `user_devices` table (0004), which is a different table from the
-- auth service's identically-named one — auth's is keyed by users.id and holds
-- FCM tokens, this one is keyed by profiles.id. They live in separate
-- databases and must not be conflated.
create or replace function pandapay.register_sync_device(
  p_profile     uuid,
  p_platform    text,
  p_label       text default null,
  p_app_version text default null,
  p_device_id   uuid default null
) returns uuid language plpgsql security definer
set search_path = public, pandapay
as $$
declare v_id uuid;
begin
  if p_device_id is not null then
    update user_devices
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

  insert into user_devices (profile_id, platform, device_label, app_version, last_seen_at)
       values (
         p_profile,
         case when p_platform in ('android','ios','web') then p_platform else 'web' end,
         p_label, p_app_version, now()
       )
    returning id into v_id;

  insert into sync_cursors (device_id, profile_id) values (v_id, p_profile)
  on conflict (device_id) do nothing;

  return v_id;
end $$;

grant execute on function pandapay.register_sync_device(uuid, text, text, text, uuid) to public;

-- ---------------------------------------------------------------------------
-- Push: apply one incoming change
-- ---------------------------------------------------------------------------
-- Returns the applied op and the number of fields that lost a conflict, so the
-- caller can report an honest per-change result rather than a blanket "synced".
create or replace function pandapay.sync_apply_change(
  p_profile      uuid,
  p_device       uuid,
  p_entity       text,
  p_entity_id    uuid,
  p_op           sync_op,
  p_payload      jsonb,
  p_field_clocks jsonb,
  p_client_seq   bigint
) returns table(out_applied boolean, out_conflicts int, out_reason text)
language plpgsql security definer
set search_path = public, pandapay
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
  v_fields := pandapay.sync_fields_for(p_entity);
  if v_fields is null then
    return query select false, 0, 'unknown_entity'::text; return;
  end if;

  -- Ownership. RLS would also stop a cross-profile write, but this function is
  -- SECURITY DEFINER and therefore bypasses it — so the check has to be
  -- explicit here. Without it, `entity_id` would be a straightforward way to
  -- edit another user's transactions.
  execute format(
    'select exists (select 1 from %I where id = $1 and profile_id = $2)', p_entity
  ) into v_owned using p_entity_id, p_profile;

  if p_op = 'delete' then
    if not v_owned then
      return query select false, 0, 'not_found'::text; return;
    end if;
    -- R4 is "archive, never delete" for user_cards, and a delete arriving
    -- over sync must not become the one path that circumvents it.
    if p_entity = 'user_cards' then
      update user_cards set is_archived = true, archived_at = now()
       where id = p_entity_id and profile_id = p_profile;
    else
      execute format('delete from %I where id = $1 and profile_id = $2', p_entity)
        using p_entity_id, p_profile;
    end if;

    insert into change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
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
  execute format('select to_jsonb(t) from %I t where t.id = $1', p_entity)
    into v_existing using p_entity_id;
  v_existing_clocks := coalesce(
    (select field_clocks from change_log
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
      insert into sync_conflicts (
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
      insert into sync_conflicts (
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
    insert into change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
         values (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
                 v_existing_clocks, p_client_seq);
    return query select true, v_conflicts, null::text; return;
  end if;

  -- Text-cast assignment lets one statement handle every column type: Postgres
  -- applies the column's own input conversion, so a numeric stays numeric and
  -- an enum is validated as an enum. A malformed value raises here rather than
  -- being silently coerced, which is the behaviour wanted for financial data.
  v_sql := format('update %I set %s where id = $2 and profile_id = $3',
                  p_entity, array_to_string(v_set_pairs, ', '));
  execute v_sql using p_payload, p_entity_id, p_profile;

  insert into change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
       values (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
               v_existing_clocks || v_merged_clocks, p_client_seq);

  return query select true, v_conflicts, null::text;
end $$;

grant execute on function pandapay.sync_apply_change(uuid, uuid, text, uuid, sync_op, jsonb, jsonb, bigint) to public;

-- ---------------------------------------------------------------------------
-- Pull
-- ---------------------------------------------------------------------------
-- Excludes the requesting device's own writes. A device already has its own
-- changes applied locally, and echoing them back would make every push cost a
-- redundant round trip of data the client would then have to recognise and
-- discard.
create or replace function pandapay.sync_pull(
  p_profile uuid,
  p_device  uuid,
  p_since   bigint,
  p_limit   int default 500
) returns table(
  server_seq bigint, entity text, entity_id uuid, op sync_op,
  payload jsonb, field_clocks jsonb, created_at timestamptz
) language sql security definer
set search_path = public, pandapay
as $$
  select c.server_seq, c.entity, c.entity_id, c.op, c.payload, c.field_clocks, c.created_at
    from change_log c
   where c.profile_id = p_profile
     and c.server_seq > p_since
     and (c.device_id is distinct from p_device)
   order by c.server_seq
   limit least(greatest(p_limit, 1), 1000);
$$;

grant execute on function pandapay.sync_pull(uuid, uuid, bigint, int) to public;

-- Advanced only after the client confirms it applied everything up to this
-- point. A cursor moved on send rather than on acknowledgement is how a
-- dropped response turns into permanently skipped changes.
create or replace function pandapay.sync_ack(
  p_profile uuid, p_device uuid, p_server_seq bigint
) returns void language plpgsql security definer
set search_path = public, pandapay
as $$
begin
  insert into sync_cursors (device_id, profile_id, last_server_seq, last_pulled_at)
       values (p_device, p_profile, p_server_seq, now())
  on conflict (device_id) do update
     -- greatest(): an out-of-order or replayed ack must never move the cursor
     -- backwards and cause changes to be delivered twice.
     set last_server_seq = greatest(sync_cursors.last_server_seq, excluded.last_server_seq),
         last_pulled_at  = now();
end $$;

grant execute on function pandapay.sync_ack(uuid, uuid, bigint) to public;

create index if not exists idx_change_log_profile_seq on change_log (profile_id, server_seq);
create index if not exists idx_change_log_entity on change_log (entity, entity_id, server_seq desc);
create index if not exists idx_sync_conflicts_unack
  on sync_conflicts (profile_id, created_at desc) where not user_acknowledged;
