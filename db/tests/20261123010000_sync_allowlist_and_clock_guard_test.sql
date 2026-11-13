-- Regression test for migration 20261123010000 (sync allowlist repair).
--
-- Why this exists: pandapay.sync_fields_for and the typed writer's allowlist are
-- FULL-FUNCTION replacements. 20261019144500 re-declared sync_fields_for from an
-- old template and silently dropped user_cards.last4 and annual_fee_override_inr,
-- and four later migrations copied the omission. A dropped field never raises:
-- the sync push reports success and the value is quietly ignored. So this test
-- pins the COMPLETE field list of every sync entity, for both the legacy
-- allowlist (sync_fields_for) and the typed writer (sync_apply_change_v2).
-- A future migration that re-declares either function must keep these lists a
-- superset; update the lists here in the same change, deliberately.
--
-- Synthetic data only. Run with `psql -v ON_ERROR_STOP=1` on a fully migrated
-- scratch database; everything is rolled back.

\set ON_ERROR_STOP on

begin;

select set_config('app.user_id', '11110000-0000-0000-0000-0000000000a1', true);

-- ---------------------------------------------------------------------------
-- 1. Legacy allowlist: the complete list per entity.
-- ---------------------------------------------------------------------------
do $$
declare
  v_expected jsonb := jsonb_build_object(
    'transactions', jsonb_build_array(
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','status','note',
      'instrument','entry_kind'),
    'user_cards', jsonb_build_array(
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source','last4','annual_fee_override_inr'),
    'card_overrides', jsonb_build_array(
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'),
    'user_merchant_category_rules', jsonb_build_array(
      'action','flag','match_basis','match_value','category_id','user_category_id',
      'is_active','version')
  );
  v_entity text;
  v_actual text[];
  v_want text[];
begin
  for v_entity in select jsonb_object_keys(v_expected) loop
    v_actual := pandapay.sync_fields_for(v_entity);
    select array_agg(value order by value) into v_want
      from jsonb_array_elements_text(v_expected -> v_entity);
    if v_actual is null then
      raise exception 'sync_fields_for(%) returned null', v_entity;
    end if;
    if (select array_agg(f order by f) from unnest(v_actual) f) is distinct from v_want then
      raise exception 'sync_fields_for(%) list changed: got %, expected %', v_entity, v_actual, v_want;
    end if;
    if cardinality(v_actual) <> (select count(distinct f) from unnest(v_actual) f) then
      raise exception 'sync_fields_for(%) has duplicate fields', v_entity;
    end if;
  end loop;
  if pandapay.sync_fields_for('no_such_entity') is not null then
    raise exception 'unknown entity must have no allowlist';
  end if;
  -- Deliberately NOT sync fields: they have their own routes.
  if pandapay.sync_fields_for('transactions') && array['payment_method','exclude_from_spend'] then
    raise exception 'payment_method / exclude_from_spend must stay off the sync allowlist';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Typed writer allowlist: complete list per entity, read from its source.
--    (v2 inlines its lists; status is excluded because transactions status
--    needs the domain route, and merchant rules use their own function.)
-- ---------------------------------------------------------------------------
do $$
declare
  v_src text := (select prosrc from pg_proc
                  where oid = 'pandapay.sync_apply_change_v2(uuid,uuid,text,uuid,public.sync_op,jsonb,jsonb,bigint)'::regprocedure);
  v_expected jsonb := jsonb_build_object(
    'transactions', jsonb_build_array(
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','instrument','entry_kind','note'),
    'user_cards', jsonb_build_array(
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source','last4','annual_fee_override_inr'),
    'card_overrides', jsonb_build_array(
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled')
  );
  v_entity text;
  v_block text;
  v_actual text[];
  v_want text[];
  v_legacy text[];
begin
  for v_entity in select jsonb_object_keys(v_expected) loop
    v_block := (regexp_match(v_src, 'WHEN ''' || v_entity || ''' THEN ARRAY\[(.*?)\]', 's'))[1];
    if v_block is null then
      raise exception 'typed writer has no allowlist for %', v_entity;
    end if;
    select array_agg(m[1] order by m[1]) into v_actual
      from regexp_matches(v_block, '''([a-z0-9_]+)''', 'g') m;
    select array_agg(value order by value) into v_want
      from jsonb_array_elements_text(v_expected -> v_entity);
    if v_actual is distinct from v_want then
      raise exception 'sync_apply_change_v2 list for % changed: got %, expected %', v_entity, v_actual, v_want;
    end if;
    -- The legacy list must contain every typed field (status excepted).
    v_legacy := pandapay.sync_fields_for(v_entity);
    if exists (select 1 from unnest(v_actual) f where f <> all (v_legacy)) then
      raise exception 'typed writer allows a field the legacy list lacks for %', v_entity;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Behaviour: fixtures.
-- ---------------------------------------------------------------------------
insert into profiles (id) values ('11110000-0000-0000-0000-0000000000a1');
insert into issuers (id, slug, name)
  values ('33330000-0000-0000-0000-0000000000c1', 'sync-allowlist-bank', 'Sync Allowlist Bank');
insert into card_products (id, issuer_id, slug, name, network, card_type, status, verified_at)
  values ('44440000-0000-0000-0000-0000000000d1', '33330000-0000-0000-0000-0000000000c1',
          'sync-allowlist-card', 'Sync Allowlist Card', 'visa', 'credit', 'published', now());
insert into user_cards (id, profile_id, card_product_id, last4) values
  ('55550000-0000-0000-0000-0000000000e1', '11110000-0000-0000-0000-0000000000a1',
   '44440000-0000-0000-0000-0000000000d1', '1111'),
  ('55550000-0000-0000-0000-0000000000e2', '11110000-0000-0000-0000-0000000000a1',
   '44440000-0000-0000-0000-0000000000d1', null);
insert into transactions (id, profile_id, user_card_id, amount_inr, occurred_at, source, merchant_name, note)
  values ('66660000-0000-0000-0000-0000000000f1', '11110000-0000-0000-0000-0000000000a1',
          '55550000-0000-0000-0000-0000000000e1', 500.00, now(), 'manual', 'Synthetic Shop', null);

do $$
declare
  v_profile uuid := '11110000-0000-0000-0000-0000000000a1';
  v_card_a uuid := '55550000-0000-0000-0000-0000000000e1';
  v_card_b uuid := '55550000-0000-0000-0000-0000000000e2';
  v_txn uuid := '66660000-0000-0000-0000-0000000000f1';
  v_phone uuid;
  v_tablet uuid;
  v_applied boolean; v_conflicts int; v_reason text;
  v_last4 text; v_fee numeric; v_payload jsonb; v_state text;
begin
  v_phone  := pandapay.register_sync_device(v_profile, 'android', 'Phone');
  v_tablet := pandapay.register_sync_device(v_profile, 'android', 'Tablet');

  -- 3a. Typed writer: last4 and annual_fee_override_inr now apply (they were
  --     never on its list, and had been dropped from the legacy list).
  select out_applied, out_reason into v_applied, v_reason from pandapay.sync_apply_change_v2(
    v_profile, v_phone, 'user_cards', v_card_b, 'update',
    '{"last4":"2222","annual_fee_override_inr":0}'::jsonb,
    '{"last4":1000,"annual_fee_override_inr":1000}'::jsonb, 1);
  if not v_applied then raise exception 'typed last4/annual fee write refused: %', v_reason; end if;
  select last4, annual_fee_override_inr into v_last4, v_fee from user_cards where id = v_card_b;
  if v_last4 is distinct from '2222' or v_fee is distinct from 0 then
    raise exception 'typed writer did not store last4/annual_fee_override_inr (% / %)', v_last4, v_fee;
  end if;

  -- 3b. Legacy writer: last4 (a text-like column) applies too.
  select out_applied, out_reason into v_applied, v_reason from pandapay.sync_apply_change(
    v_profile, v_phone, 'user_cards', v_card_b, 'update',
    '{"last4":"3333"}'::jsonb, '{"last4":2000}'::jsonb, 2);
  if not v_applied then raise exception 'legacy last4 write refused: %', v_reason; end if;
  select last4 into v_last4 from user_cards where id = v_card_b;
  if v_last4 is distinct from '3333' then
    raise exception 'legacy writer did not store last4 (%)', v_last4;
  end if;

  -- 3c. Typed writer: transactions instrument / entry_kind apply.
  select out_applied, out_reason into v_applied, v_reason from pandapay.sync_apply_change_v2(
    v_profile, v_phone, 'transactions', v_txn, 'update',
    '{"instrument":"credit_card","entry_kind":"spend"}'::jsonb,
    '{"instrument":1000,"entry_kind":1000}'::jsonb, 3);
  if not v_applied then raise exception 'typed instrument/entry_kind write refused: %', v_reason; end if;

  -- 3d. Annual fee guards (typed): negative -> 23514, sub-paise -> 22003.
  begin
    perform pandapay.sync_apply_change_v2(v_profile, v_phone, 'user_cards', v_card_b, 'update',
      '{"annual_fee_override_inr":-1}'::jsonb, '{"annual_fee_override_inr":3000}'::jsonb, 4);
    raise exception 'negative annual fee override was accepted';
  exception when check_violation then null;
  end;
  begin
    perform pandapay.sync_apply_change_v2(v_profile, v_phone, 'user_cards', v_card_b, 'update',
      '{"annual_fee_override_inr":10.005}'::jsonb, '{"annual_fee_override_inr":3000}'::jsonb, 5);
    raise exception 'sub-paise annual fee override was accepted';
  exception when numeric_value_out_of_range then null;
  end;

  -- 3e. A last4 that collides with another active card of the same product is a
  --     unique violation on uq_user_cards_active_identity (the API turns this
  --     into a permanent reject with a fixed detail, not a 500).
  begin
    perform pandapay.sync_apply_change_v2(v_profile, v_phone, 'user_cards', v_card_b, 'update',
      '{"last4":"1111"}'::jsonb, '{"last4":4000}'::jsonb, 6);
    raise exception 'duplicate active last4 was accepted';
  exception when unique_violation then
    get stacked diagnostics v_state = constraint_name;
    if v_state <> 'uq_user_cards_active_identity' then
      raise exception 'unexpected constraint %', v_state;
    end if;
  end;

  -- 3f. change_log.payload records only what was applied (typed writer).
  --     tablet writes note with a newer clock, phone then writes an older note
  --     plus an unlisted field: the phone's attempt must log an empty payload.
  select out_applied into v_applied from pandapay.sync_apply_change_v2(
    v_profile, v_tablet, 'transactions', v_txn, 'update',
    '{"note":"newer","not_a_column":"x"}'::jsonb, '{"note":9000}'::jsonb, 10);
  select payload into v_payload from change_log
   where entity_id = v_txn and client_seq = 10 and device_id = v_tablet;
  if v_payload is distinct from '{"note":"newer"}'::jsonb then
    raise exception 'typed change_log payload should hold applied fields only, got %', v_payload;
  end if;
  select out_applied, out_conflicts into v_applied, v_conflicts from pandapay.sync_apply_change_v2(
    v_profile, v_phone, 'transactions', v_txn, 'update',
    '{"note":"older","not_a_column":"y"}'::jsonb, '{"note":5000}'::jsonb, 11);
  if v_conflicts <> 1 then raise exception 'older note should be one conflict, got %', v_conflicts; end if;
  select payload into v_payload from change_log
   where entity_id = v_txn and client_seq = 11 and device_id = v_phone;
  if v_payload is distinct from '{}'::jsonb then
    raise exception 'losing change must log an empty payload, got %', v_payload;
  end if;
  if (select note from transactions where id = v_txn) is distinct from 'newer' then
    raise exception 'losing note overwrote the winner';
  end if;

  -- 3g. Same, legacy writer.
  select out_applied into v_applied from pandapay.sync_apply_change(
    v_profile, v_tablet, 'transactions', v_txn, 'update',
    '{"merchant_name":"Legacy Shop","not_a_column":"x"}'::jsonb, '{"merchant_name":9000}'::jsonb, 20);
  select payload into v_payload from change_log
   where entity_id = v_txn and client_seq = 20 and device_id = v_tablet;
  if v_payload is distinct from '{"merchant_name":"Legacy Shop"}'::jsonb then
    raise exception 'legacy change_log payload should hold applied fields only, got %', v_payload;
  end if;
  select out_applied, out_conflicts into v_applied, v_conflicts from pandapay.sync_apply_change(
    v_profile, v_phone, 'transactions', v_txn, 'update',
    '{"merchant_name":"Older Shop"}'::jsonb, '{"merchant_name":5000}'::jsonb, 21);
  select payload into v_payload from change_log
   where entity_id = v_txn and client_seq = 21 and device_id = v_phone;
  if v_conflicts <> 1 or v_payload is distinct from '{}'::jsonb then
    raise exception 'legacy losing change: conflicts %, payload %', v_conflicts, v_payload;
  end if;

  -- 3h. Existing behaviour is retained: unknown entity, wrong device.
  select out_reason into v_reason from pandapay.sync_apply_change_v2(
    v_profile, v_phone, 'no_such_entity', v_txn, 'update', '{}'::jsonb, '{}'::jsonb, 30);
  if v_reason <> 'unknown_entity' then raise exception 'unknown entity reason changed: %', v_reason; end if;
  select out_reason into v_reason from pandapay.sync_apply_change_v2(
    v_profile, gen_random_uuid(), 'user_cards', v_card_a, 'update', '{}'::jsonb, '{}'::jsonb, 31);
  if v_reason <> 'not_found' then raise exception 'unregistered device reason changed: %', v_reason; end if;
end $$;

rollback;
