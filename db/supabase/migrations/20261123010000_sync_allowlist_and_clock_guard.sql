-- WP-S1: sync allowlist regression repair and applied-only change_log payloads.
--
-- Additive replacement of three functions, each a STRICT SUPERSET of its
-- latest definition (no field removed, none reordered):
--
--   pandapay.sync_fields_for        20261023180000_user_merchant_rule_actions.sql
--   pandapay.sync_apply_change_v2   20261025150000_sync_apply_change_v2.sql
--   pandapay.sync_apply_change      20261025151350_legacy_sync_context_isolation.sql
--
-- 1. user_cards += last4, annual_fee_override_inr. Migrations 0039 and
--    20261013120000 added them on purpose (Edit Card queues both while offline);
--    20261019144500_sync_user_category_field.sql re-declared sync_fields_for from
--    an old template and dropped them, and every later re-declaration copied the
--    omission, so an offline last4 / annual-fee edit was acknowledged and then
--    silently never stored. The typed writer never had them at all.
-- 2. transactions += instrument, entry_kind in the legacy list (the typed
--    writer already allows both). payment_method and exclude_from_spend are
--    NOT added: they have their own routes.
-- 3. change_log.payload now records only the fields that were applied. It used
--    to store the whole submitted payload, including ignored fields and the
--    values of fields that lost their conflict, so other devices pulled values
--    the server never stored. field_clocks already held winners only. A change
--    whose fields all lost (or none were allowlisted) is still logged, with an
--    empty payload. The shipped client re-fetches authoritative rows when it
--    pulls and never reads these payloads for cards/transactions; commitments
--    and merchant rules use their own functions, which are untouched.
-- 4. The typed writer also rejects a negative or sub-paise
--    annual_fee_override_inr (numeric(10,2) with CHECK >= 0).
--
-- A function replacement is full, so a future re-declaration must again be a
-- superset: db/tests/20261123010000_sync_allowlist_and_clock_guard_test.sql
-- asserts the complete field list of every sync entity.
--
-- Not changed here: the legacy writer assigns every column through a text cast
-- (see the comment in 0034), which PostgreSQL only accepts for text-like
-- columns. The typed-write rollout is a separate decision (plan D1).

create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','status','note',
      'instrument','entry_kind'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source',
      'last4','annual_fee_override_inr'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    when 'user_merchant_category_rules' then array[
      'action','flag','match_basis','match_value','category_id','user_category_id','is_active','version'
    ]
    else null::text[]
  end;
$$;

CREATE OR REPLACE FUNCTION pandapay.sync_apply_change_v2(
  p_profile      uuid,
  p_device       uuid,
  p_entity       text,
  p_entity_id    uuid,
  p_op           public.sync_op,
  p_payload      jsonb,
  p_field_clocks jsonb,
  p_client_seq   bigint
) RETURNS TABLE(out_applied boolean, out_conflicts integer, out_reason text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_fields             text[];
  v_field              text;
  v_existing            jsonb;
  v_existing_clocks     jsonb;
  v_incoming_clock      bigint;
  v_existing_clock      bigint;
  v_set_pairs           text[] := ARRAY[]::text[];
  v_patch               jsonb := '{}'::jsonb;
  v_merged_clocks       jsonb := '{}'::jsonb;
  v_conflicts           integer := 0;
  v_numeric             numeric;
  v_related_card_id     uuid;
  v_sql                 text;
BEGIN
  -- Keep generic metadata/category entities on their dedicated sync RPCs.
  -- In particular, merchant-category rules use version semantics, not LWW.
  v_fields := CASE p_entity
    WHEN 'transactions' THEN ARRAY[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','instrument','entry_kind','note'
    ]
    WHEN 'user_cards' THEN ARRAY[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source',
      'last4','annual_fee_override_inr'
    ]
    WHEN 'card_overrides' THEN ARRAY[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    ELSE NULL
  END;
  IF v_fields IS NULL THEN
    RETURN QUERY SELECT false, 0, 'unknown_entity'::text;
    RETURN;
  END IF;

  -- Unlike the legacy public RPC, this SECURITY DEFINER routine is bound to
  -- the authenticated backend request context and that profile's device.
  IF p_profile IS NULL OR p_profile IS DISTINCT FROM pandapay.uid() THEN
    RETURN QUERY SELECT false, 0, 'not_found'::text;
    RETURN;
  END IF;
  IF p_device IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_devices d
     WHERE d.id = p_device AND d.profile_id = p_profile
  ) THEN
    RETURN QUERY SELECT false, 0, 'not_found'::text;
    RETURN;
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR
     p_field_clocks IS NULL OR jsonb_typeof(p_field_clocks) <> 'object' THEN
    RETURN QUERY SELECT false, 0, 'malformed'::text;
    RETURN;
  END IF;

  -- Transaction status and deletes need the domain transition path, which
  -- reverses/reapplies reward state. Never let this generic writer bypass it.
  IF p_entity = 'transactions' AND p_op = 'delete' THEN
    RAISE EXCEPTION 'transaction delete requires the domain route'
      USING ERRCODE = '42501';
  END IF;
  IF p_entity = 'transactions' AND p_payload ? 'status' THEN
    RAISE EXCEPTION 'transaction status requires the domain route'
      USING ERRCODE = '42501';
  END IF;

  -- An UPDATE or DELETE must lock the same-profile row before reading its
  -- values/clocks, so concurrent device writes cannot compare against stale
  -- state. Table identifiers are selected only from the allowlist above.
  EXECUTE format(
    'SELECT to_jsonb(t) FROM public.%I AS t WHERE t.id = $1 AND t.profile_id = $2 FOR UPDATE',
    p_entity
  ) INTO v_existing USING p_entity_id, p_profile;
  -- EXECUTE ... INTO does not update PL/pgSQL FOUND consistently across
  -- dynamic statements; to_jsonb(row) is non-null for every owned row.
  IF v_existing IS NULL THEN
    RETURN QUERY SELECT false, 0, 'not_found'::text;
    RETURN;
  END IF;

  IF p_op = 'delete' THEN
    IF p_entity = 'user_cards' THEN
      UPDATE public.user_cards SET is_archived = true, archived_at = now()
       WHERE id = p_entity_id AND profile_id = p_profile;
    ELSE
      EXECUTE format(
        'DELETE FROM public.%I WHERE id = $1 AND profile_id = $2', p_entity
      ) USING p_entity_id, p_profile;
    END IF;
    INSERT INTO public.change_log
      (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    VALUES
      (p_profile, p_device, p_entity, p_entity_id, 'delete', '{}'::jsonb,
       '{}'::jsonb, p_client_seq);
    RETURN QUERY SELECT true, 0, NULL::text;
    RETURN;
  END IF;

  SELECT COALESCE((
    SELECT cl.field_clocks
      FROM public.change_log cl
     WHERE cl.profile_id = p_profile
       AND cl.entity = p_entity
       AND cl.entity_id = p_entity_id
     ORDER BY cl.server_seq DESC
     LIMIT 1
  ), '{}'::jsonb) INTO v_existing_clocks;

  FOREACH v_field IN ARRAY v_fields LOOP
    CONTINUE WHEN NOT (p_payload ? v_field);

    v_incoming_clock := COALESCE((p_field_clocks ->> v_field)::bigint, 0);
    v_existing_clock := COALESCE((v_existing_clocks ->> v_field)::bigint, 0);

    IF v_incoming_clock < v_existing_clock THEN
      v_conflicts := v_conflicts + 1;
      INSERT INTO public.sync_conflicts
        (profile_id, entity, entity_id, field, local_value, server_value,
         chosen_value, strategy, device_id)
      VALUES
        (p_profile, p_entity, p_entity_id, v_field,
         p_payload -> v_field, v_existing -> v_field, v_existing -> v_field,
         'last_write_wins', p_device);
      CONTINUE;
    END IF;

    IF v_incoming_clock = v_existing_clock
       AND v_existing_clock > 0
       AND (v_existing -> v_field) IS DISTINCT FROM (p_payload -> v_field) THEN
      v_conflicts := v_conflicts + 1;
      INSERT INTO public.sync_conflicts
        (profile_id, entity, entity_id, field, local_value, server_value,
         chosen_value, strategy, device_id)
      VALUES
        (p_profile, p_entity, p_entity_id, v_field,
         p_payload -> v_field, v_existing -> v_field, p_payload -> v_field,
         'last_write_wins', p_device);
    END IF;

    -- Financial amounts and credit limits are stored to two decimals. Reject
    -- sub-paise values before the typmod cast could silently round them.
    IF (p_entity = 'transactions' AND v_field = 'amount_inr') OR
       (p_entity = 'user_cards' AND v_field IN ('credit_limit_inr', 'annual_fee_override_inr')) THEN
      IF p_payload -> v_field <> 'null'::jsonb THEN
        v_numeric := (p_payload ->> v_field)::numeric;
        IF v_numeric::text IN ('NaN', 'Infinity', '-Infinity') OR
           v_numeric * 100 <> trunc(v_numeric * 100) THEN
          RAISE EXCEPTION 'financial amount has fractional paise'
            USING ERRCODE = '22003';
        END IF;
        IF p_entity = 'user_cards' AND v_field = 'credit_limit_inr' AND v_numeric <= 0 THEN
          RAISE EXCEPTION 'credit limit must be positive or null'
            USING ERRCODE = '23514';
        END IF;
        IF p_entity = 'user_cards' AND v_field = 'annual_fee_override_inr' AND v_numeric < 0 THEN
          RAISE EXCEPTION 'annual fee override must not be negative'
            USING ERRCODE = '23514';
        END IF;
      END IF;
    END IF;

    v_patch := v_patch || jsonb_build_object(v_field, p_payload -> v_field);
    v_set_pairs := array_append(
      v_set_pairs,
      format('%I = (jsonb_populate_record(NULL::public.%I, $1)).%I',
             v_field, p_entity, v_field)
    );
    v_merged_clocks := v_merged_clocks || jsonb_build_object(v_field, v_incoming_clock);
  END LOOP;

  IF cardinality(v_set_pairs) IS NULL OR cardinality(v_set_pairs) = 0 THEN
    -- Preserve legacy behavior when all supplied fields lose (or none are
    -- allowlisted): still log the attempt so the pull stream and the conflict
    -- log agree, but with an empty payload. A change_log payload records only
    -- what was applied, never losing or ignored values.
    INSERT INTO public.change_log
      (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    VALUES
      (p_profile, p_device, p_entity, p_entity_id, 'update', '{}'::jsonb,
       v_existing_clocks, p_client_seq);
    RETURN QUERY SELECT true, v_conflicts, NULL::text;
    RETURN;
  END IF;

  IF p_entity = 'card_overrides' AND v_patch ? 'user_card_id' AND
     v_patch -> 'user_card_id' <> 'null'::jsonb THEN
    v_related_card_id := (v_patch ->> 'user_card_id')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM public.user_cards uc
       WHERE uc.id = v_related_card_id AND uc.profile_id = p_profile
    ) THEN
      RAISE EXCEPTION 'card override user card is not owned by profile'
        USING ERRCODE = '23503';
    END IF;
  END IF;

  -- jsonb_populate_record uses the actual target row type for input
  -- conversion (UUID, enum, date/time, citext, numeric, arrays, JSON, etc.).
  -- Only allowlisted winning keys were copied into the bound JSON patch.
  v_sql := format(
    'UPDATE public.%I SET %s WHERE id = $2 AND profile_id = $3',
    p_entity, array_to_string(v_set_pairs, ', ')
  );
  EXECUTE v_sql USING v_patch, p_entity_id, p_profile;

  INSERT INTO public.change_log
    (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
  VALUES
    (p_profile, p_device, p_entity, p_entity_id, 'update', v_patch,
     v_existing_clocks || v_merged_clocks, p_client_seq);

  RETURN QUERY SELECT true, v_conflicts, NULL::text;
END;
$$;

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
  v_patch jsonb := '{}'::jsonb;
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
    v_patch := v_patch || jsonb_build_object(v_field, p_payload -> v_field);
    v_merged_clocks := v_merged_clocks || jsonb_build_object(v_field, v_incoming_clock);
  end loop;

  if array_length(v_set_pairs, 1) is null then
    -- Every field lost. Still logged, so the pull stream and the conflict log
    -- agree about what happened, but with an empty payload: a change_log
    -- payload records only what was applied.
    insert into public.change_log (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
         values (p_profile, p_device, p_entity, p_entity_id, 'update', '{}'::jsonb,
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
       values (p_profile, p_device, p_entity, p_entity_id, 'update', v_patch,
               v_existing_clocks || v_merged_clocks, p_client_seq);

  return query select true, v_conflicts, null::text;
end $$;
