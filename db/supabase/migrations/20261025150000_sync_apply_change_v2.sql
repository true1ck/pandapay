-- Typed, opt-in replacement for the legacy generic sync writer.
-- The legacy function and its grants remain unchanged until the API can
-- reconcile transaction state atomically before committing a push.
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
      'statement_day_source','due_day_source'
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
       (p_entity = 'user_cards' AND v_field = 'credit_limit_inr') THEN
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
    -- allowlisted): record the attempted payload without changing the row.
    INSERT INTO public.change_log
      (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    VALUES
      (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
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
    (p_profile, p_device, p_entity, p_entity_id, 'update', p_payload,
     v_existing_clocks || v_merged_clocks, p_client_seq);

  RETURN QUERY SELECT true, v_conflicts, NULL::text;
END;
$$;

REVOKE ALL ON FUNCTION pandapay.sync_apply_change_v2(
  uuid, uuid, text, uuid, public.sync_op, jsonb, jsonb, bigint
) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'app_user') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION pandapay.sync_apply_change_v2(uuid, uuid, text, uuid, public.sync_op, jsonb, jsonb, bigint) TO app_user';
  END IF;
END;
$$;
