-- Run after all migrations (incl. 20261106120000_card_state_v2) and db/setup_app_role.sql:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/tests/20261106120000_card_state_v2_test.sql
-- Everything runs inside one transaction and is rolled back; no real data is touched.
--
-- Card Rewards Phase 1, WP8 (server recording v2). Proves:
--   1. the new columns exist with the right types and defaults (plan H3: additive);
--   2. an old-style (v1 path) insert into cap_states / milestone_states still works
--      and reads back as a v1 row (cap_kind null, approximate_window false);
--   3. cap_states.cap_kind only takes the C1 cap kinds;
--   4. transactions.card_state_v2 defaults to null and stores a JSON object;
--   5. the existing owner-only RLS still applies to the new columns.
\set ON_ERROR_STOP on

begin;

create temp table t_ids (k text primary key, id uuid not null);
grant select on t_ids to public;

do $$
declare
  v_issuer  uuid := gen_random_uuid();
  v_card    uuid := gen_random_uuid();
  v_owner   uuid := gen_random_uuid();
  v_other   uuid := gen_random_uuid();
  v_ucard   uuid := gen_random_uuid();
  v_cap     uuid; v_ms uuid; v_txn uuid;
  v_state   record;
  v_count   int;
begin
  -- 1. Columns, types and defaults.
  select count(*) into v_count from information_schema.columns
   where table_schema = 'public' and (
     (table_name = 'cap_states' and column_name = 'cap_kind' and data_type = 'text'
        and is_nullable = 'YES' and column_default is null) or
     (table_name = 'cap_states' and column_name = 'cap_amount' and data_type = 'numeric'
        and numeric_precision = 14 and numeric_scale = 2 and is_nullable = 'YES') or
     (table_name = 'cap_states' and column_name = 'approximate_window' and data_type = 'boolean'
        and is_nullable = 'NO' and column_default = 'false') or
     (table_name = 'milestone_states' and column_name = 'approximate_window' and data_type = 'boolean'
        and is_nullable = 'NO' and column_default = 'false') or
     (table_name = 'transactions' and column_name = 'card_state_v2' and data_type = 'jsonb'
        and is_nullable = 'YES' and column_default is null));
  if v_count <> 5 then
    raise exception 'card_state_v2 columns missing or wrongly typed (found % of 5)', v_count;
  end if;

  -- Seed: a card, its cap and milestone, two profiles, one user card, one spend.
  insert into issuers (id, slug, name) values (v_issuer, 'wp8-test-bank', 'WP8 Test Bank');
  insert into card_products (id, issuer_id, slug, name, network, status, verified_at,
                             base_reward_unit, base_reward_rate, point_value_inr, accrual_rounding)
  values (v_card, v_issuer, 'wp8-test-card', 'WP8 Test Card', 'visa', 'published', now(),
          'points_per_100', 1, 0.25, 'floor');
  insert into cap_rules (card_product_id, label, measure, period, cap_value, cap_kind, cap_amount,
                         min_engine_version)
    values (v_card, 'wp8 bonus cap', 'reward_value', 'calendar_month', 375, 'bonus_points', 1500, 2)
    returning id into v_cap;
  insert into milestone_rules (card_product_id, label, period, threshold_spend_inr,
                               reward_description, reward_value_inr, anchor, window_days)
    values (v_card, 'wp8 welcome', 'lifetime', 15000, 'welcome', 500, 'card_anniversary', 90)
    returning id into v_ms;
  insert into profiles (id) values (v_owner), (v_other);
  insert into user_cards (id, profile_id, card_product_id) values (v_ucard, v_owner, v_card);
  insert into transactions (profile_id, user_card_id, amount_inr, occurred_at, source)
    values (v_owner, v_ucard, 2000, '2026-11-05T10:00:00Z', 'manual') returning id into v_txn;

  -- 2. The v1 path's insert (no new columns) still works and reads as a v1 row.
  insert into cap_states (profile_id, user_card_id, cap_rule_id, period_start, period_end,
                          consumed, cap_value_snapshot)
    values (v_owner, v_ucard, v_cap, '2026-11-01', '2026-11-30', 45, 375);
  select cap_kind, cap_amount, approximate_window into v_state
    from cap_states where user_card_id = v_ucard and cap_rule_id = v_cap;
  if v_state.cap_kind is not null or v_state.cap_amount is not null or v_state.approximate_window then
    raise exception 'an old-style cap_states insert must read back as a v1 row';
  end if;
  insert into milestone_states (profile_id, user_card_id, milestone_rule_id, period_start,
                                period_end, qualified_spend)
    values (v_owner, v_ucard, v_ms, '2026-11-01', '2027-01-29', 2000);
  if (select approximate_window from milestone_states where milestone_rule_id = v_ms) then
    raise exception 'milestone_states.approximate_window must default to false';
  end if;
  if (select card_state_v2 from transactions where id = v_txn) is not null then
    raise exception 'transactions.card_state_v2 must default to null';
  end if;

  -- 3. Only the C1 cap kinds are accepted.
  update cap_states set cap_kind = 'bonus_points', cap_amount = 1500, consumed = 180,
                        approximate_window = true
   where user_card_id = v_ucard and cap_rule_id = v_cap;
  begin
    update cap_states set cap_kind = 'rupees' where user_card_id = v_ucard and cap_rule_id = v_cap;
    raise exception 'cap_states accepted an unknown cap_kind';
  exception when check_violation then null;
  end;
  foreach v_state.cap_kind in array array['bonus_points','total_points','bonus_cashback',
                                          'total_cashback','eligible_spend','txn_count'] loop
    update cap_states set cap_kind = v_state.cap_kind where user_card_id = v_ucard and cap_rule_id = v_cap;
  end loop;
  update cap_states set cap_kind = 'bonus_points' where user_card_id = v_ucard and cap_rule_id = v_cap;

  -- 4. The per-transaction record is a JSON object.
  update transactions
     set card_state_v2 = jsonb_build_object('v', 1, 'user_card_id', v_ucard,
           'caps', jsonb_build_array(jsonb_build_object('id', v_cap, 'kind', 'bonus_points',
             'start', '2026-11-01', 'end', '2026-11-30', 'delta', 180)))
   where id = v_txn;
  if (select card_state_v2 -> 'caps' -> 0 ->> 'delta' from transactions where id = v_txn) <> '180' then
    raise exception 'transactions.card_state_v2 did not round-trip';
  end if;

  insert into t_ids values ('owner', v_owner), ('other', v_other), ('ucard', v_ucard), ('cap', v_cap);
end $$;

-- 5. RLS: the owner reads the new columns; another profile sees nothing.
set local role app_user;
select set_config('app.user_id', (select id::text from t_ids where k = 'owner'), true);
do $$
declare v_kind text; v_amount numeric; v_approx boolean;
begin
  select cap_kind, cap_amount, approximate_window into v_kind, v_amount, v_approx
    from cap_states where cap_rule_id = (select id from t_ids where k = 'cap');
  if v_kind is distinct from 'bonus_points' or v_amount is distinct from 1500.00 or v_approx is not true then
    raise exception 'owner cannot read v2 cap_states columns (% % %)', v_kind, v_amount, v_approx;
  end if;
end $$;
select set_config('app.user_id', (select id::text from t_ids where k = 'other'), true);
do $$
begin
  if exists (select 1 from cap_states where cap_rule_id = (select id from t_ids where k = 'cap')) then
    raise exception 'another profile can see the owner''s cap_states';
  end if;
  if exists (select 1 from transactions where card_state_v2 is not null
               and user_card_id = (select id from t_ids where k = 'ucard')) then
    raise exception 'another profile can see the owner''s transaction record';
  end if;
end $$;
reset role;

select 'card_state_v2 migration test passed' as result;

rollback;
