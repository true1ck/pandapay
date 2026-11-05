-- Run after all migrations (incl. 20261105120000_card_rules_v2) and db/setup_app_role.sql:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/tests/20261105120000_card_rules_v2_test.sql
-- Everything runs inside one transaction and is rolled back; no real data is touched.
\set ON_ERROR_STOP on

begin;

create temp table t_ids (k text primary key, id uuid not null);
grant select on t_ids to public;

do $$
declare
  v_issuer uuid := gen_random_uuid();
  v_card   uuid := gen_random_uuid();
  v_draft  uuid := gen_random_uuid();
  v_rule1  uuid; v_rule2 uuid; v_rule3 uuid;
  v_cap1   uuid; v_cap2 uuid; v_cap3 uuid; v_cap4 uuid; v_dr uuid; v_dcap uuid;
  v_before bigint; v_after bigint;
  v1 jsonb; v2 jsonb;
begin
  insert into issuers (id, slug, name) values (v_issuer, 'wp1-test-bank', 'WP1 Test Bank');
  insert into card_products (id, issuer_id, slug, name, network, status, verified_at,
                             base_reward_unit, base_reward_rate, point_value_inr,
                             accrual_block_inr, accrual_rounding, model_status)
  values (v_card, v_issuer, 'wp1-test-card', 'WP1 Test Card', 'visa', 'published', now(),
          'points_per_100', 1, 0.25, 100, 'floor', 'partial');
  insert into card_products (id, issuer_id, slug, name, network, status)
  values (v_draft, v_issuer, 'wp1-test-draft', 'WP1 Draft Card', 'visa', 'draft');

  -- defaults of the new columns on an old-style insert (old server code path)
  if (select model_status from card_products where id = v_draft) <> 'basic'
     or (select model_coverage from card_products where id = v_draft) <> '{}'::jsonb then
    raise exception 'card_products v2 column defaults are wrong';
  end if;

  -- Backward-compat proof: one v1 rule, one engine-2 rule, one info rule.
  insert into reward_rules (card_product_id, unit, rate, notes)
    values (v_card, 'points_per_100', 5, 'v1 rule') returning id into v_rule1;
  insert into reward_rules (card_product_id, unit, rate, notes, min_engine_version,
                            platform_slugs, source_local_id, display_note)
    values (v_card, 'points_per_100', 10, 'v2 rule', 2,
            array['phonepe_app'], 'phonepe-10x', '10 pts/100 in app') returning id into v_rule2;
  insert into reward_rules (card_product_id, unit, rate, notes, rule_role)
    values (v_card, 'points_per_100', 3, 'info rule', 'info') returning id into v_rule3;

  if (select rule_role from reward_rules where id = v_rule1) <> 'earn'
     or (select min_engine_version from reward_rules where id = v_rule1) <> 1
     or (select merchant_slugs from reward_rules where id = v_rule1) <> '{}' then
    raise exception 'reward_rules v2 column defaults are wrong';
  end if;

  -- One legacy cap (v1) and one v2 cap with targets and a parent.
  insert into cap_rules (card_product_id, reward_rule_id, label, measure, period, cap_value)
    values (v_card, v_rule1, 'legacy cap', 'spend_amount', 'calendar_month', 10000)
    returning id into v_cap1;
  insert into cap_rules (card_product_id, label, measure, period, cap_value,
                         cap_kind, cap_amount, scope, parent_cap_id, post_cap_behavior,
                         min_engine_version, source_local_id)
    values (v_card, 'v2 cap', 'reward_value', 'calendar_month', 0,
            'bonus_points', 1500, 'targets', v_cap1, 'base_rate', 2, 'phonepe-other-monthly')
    returning id into v_cap2;

  select data_version into v_before from card_products where id = v_card;
  insert into cap_rule_targets (cap_rule_id, reward_rule_id) values (v_cap2, v_rule2);
  select data_version into v_after from card_products where id = v_card;
  if v_after <= v_before then
    raise exception 'cap_rule_targets insert did not bump data_version (% -> %)', v_before, v_after;
  end if;

  v_before := v_after;
  insert into benefit_unlock_rules (card_product_id, kind, label, spend_threshold_inr,
                                    spend_window, unlocks_quota, unlocks_period)
    values (v_card, 'lounge_domestic', 'Lounge', 50000,
            'previous_calendar_quarter', 2, 'quarter');
  select data_version into v_after from card_products where id = v_card;
  if v_after <= v_before then
    raise exception 'benefit_unlock_rules insert did not bump data_version';
  end if;

  v_before := v_after;
  delete from cap_rule_targets where cap_rule_id = v_cap2;
  select data_version into v_after from card_products where id = v_card;
  if v_after <= v_before then
    raise exception 'cap_rule_targets delete did not bump data_version';
  end if;
  insert into cap_rule_targets (cap_rule_id, reward_rule_id) values (v_cap2, v_rule2);

  insert into redemption_options (card_product_id, program_name, method, value_per_point_inr)
    values (v_card, 'Statement credit', 'statement_credit', 0.25);

  insert into milestone_rules (card_product_id, label, threshold_spend_inr, reward_description,
                               reward_value_inr, reward_points, reward_kind, window_days)
    values (v_card, 'Welcome', 15000, 'bonus points', 0, 10000, 'points', 90);

  -- ── v1 view ──
  select to_jsonb(x) into v1 from v_card_catalogue_export x where x.id = v_card;
  if jsonb_array_length(v1->'reward_rules') <> 1
     or (v1->'reward_rules'->0->>'id')::uuid <> v_rule1 then
    raise exception 'v1 view must show only the v1 rule, got %', v1->'reward_rules';
  end if;
  if jsonb_array_length(v1->'cap_rules') <> 1
     or (v1->'cap_rules'->0->>'id')::uuid <> v_cap1 then
    raise exception 'v1 view must show only the v1 cap, got %', v1->'cap_rules';
  end if;
  if exists (select 1 from v_card_catalogue_export where id = v_draft) then
    raise exception 'v1 view must not list draft cards';
  end if;
  -- exact v1 key set (plan H1): no new card-level keys may leak into v1
  if (select array_agg(k order by k collate "C") from jsonb_object_keys(v1) k) is distinct from
     array['annual_fee_inr','art_asset','art_primary_color','base_reward_rate','base_reward_unit',
           'benefits','cap_rules','card_type','data_version','excluded_categories','fee_waiver_rules',
           'forex','fuel','has_apply_url','id','is_upi_linkable','issuer_name','issuer_slug','joining_fee_inr',
           'milestone_rules','name','network','network_variants','point_value_inr',
           'reward_rules','slug','verified_at']::text[] then
    raise exception 'v1 card key set changed: %', (select array_agg(k order by k collate "C") from jsonb_object_keys(v1) k);
  end if;
  -- v1 rule keeps every old key with its old enum value
  if v1->'reward_rules'->0->>'unit' <> 'points_per_100'
     or v1->'cap_rules'->0->>'measure' <> 'spend_amount'
     or v1->'cap_rules'->0->>'period' <> 'calendar_month' then
    raise exception 'v1 rule/cap enum values changed';
  end if;

  -- ── v2 view ──
  select to_jsonb(x) into v2 from v_card_catalogue_export_v2 x where x.id = v_card;
  if jsonb_array_length(v2->'reward_rules') <> 3 then
    raise exception 'v2 view must show all three rules, got %', jsonb_array_length(v2->'reward_rules');
  end if;
  if jsonb_array_length(v2->'cap_rules') <> 2 then
    raise exception 'v2 view must show both caps';
  end if;
  if (select (c->'targets') from jsonb_array_elements(v2->'cap_rules') c
       where (c->>'id')::uuid = v_cap2) <> jsonb_build_array(v_rule2) then
    raise exception 'v2 cap targets missing';
  end if;
  if (select (c->'targets') from jsonb_array_elements(v2->'cap_rules') c
       where (c->>'id')::uuid = v_cap1) <> '[]'::jsonb then
    raise exception 'cap without targets must have an empty targets array';
  end if;
  if (v2->>'model_status') <> 'partial' or (v2->>'accrual_rounding') <> 'floor'
     or (v2->>'accrual_block_inr')::int <> 100 then
    raise exception 'v2 card-level fields missing';
  end if;
  if jsonb_array_length(v2->'unlock_rules') <> 1
     or v2->'unlock_rules'->0->>'kind' <> 'lounge_domestic' then
    raise exception 'v2 unlock_rules missing';
  end if;
  if jsonb_array_length(v2->'redemption_options') <> 1 then
    raise exception 'v2 redemption_options missing';
  end if;
  if (v2->'milestone_rules'->0->>'reward_points')::numeric <> 10000 then
    raise exception 'v2 milestone reward_points missing';
  end if;
  -- rule ids are identical across feeds
  if (v1->'reward_rules'->0->>'id') <> (select r->>'id' from jsonb_array_elements(v2->'reward_rules') r
                                         where (r->>'id')::uuid = v_rule1) then
    raise exception 'rule ids differ between feeds';
  end if;

  -- ── admin view ──
  if jsonb_array_length((select reward_rules from v_admin_card_catalogue_export where id = v_card)) <> 3
     or jsonb_array_length((select unlock_rules from v_admin_card_catalogue_export where id = v_card)) <> 1 then
    raise exception 'admin view must publish all rules and unlock rules';
  end if;

  -- ── constraints reject unknown enum values ──
  begin
    insert into reward_rules (card_product_id, unit, rate, rule_role) values (v_card, 'points_per_100', 1, 'bogus');
    raise exception 'rule_role check missing';
  exception when check_violation then null; end;
  begin
    insert into reward_rules (card_product_id, unit, rate, min_engine_version) values (v_card, 'points_per_100', 1, 3);
    raise exception 'min_engine_version check missing';
  exception when check_violation then null; end;
  begin
    insert into cap_rules (card_product_id, label, measure, period, cap_value, cap_kind)
      values (v_card, 'x', 'reward_value', 'calendar_month', 1, 'bogus');
    raise exception 'cap_kind check missing';
  exception when check_violation then null; end;
  begin
    update card_products set model_status = 'bogus' where id = v_card;
    raise exception 'model_status check missing';
  exception when check_violation then null; end;
  begin
    insert into merchant_brands (slug, name) values ('Bad Slug', 'x');
    raise exception 'merchant slug check missing';
  exception when check_violation then null; end;
  begin
    insert into payment_platforms (slug, name, kind) values ('p_bad', 'x', 'bogus');
    raise exception 'platform kind check missing';
  exception when check_violation then null; end;

  -- cap parent set null on parent delete
  delete from cap_rules where id = v_cap1;
  if (select parent_cap_id from cap_rules where id = v_cap2) is not null then
    raise exception 'parent_cap_id must be set null when the parent cap is deleted';
  end if;

  -- D1: rows differing only in v2 columns must both insert
  insert into reward_rules (card_product_id, unit, rate, notes, min_engine_version, platform_slugs)
    values (v_card, 'points_per_100', 7, 'identity', 2, array['a_app']);
  insert into reward_rules (card_product_id, unit, rate, notes, min_engine_version, platform_slugs)
    values (v_card, 'points_per_100', 7, 'identity', 2, array['b_app']);
  begin
    insert into reward_rules (card_product_id, unit, rate, notes, min_engine_version, platform_slugs)
      values (v_card, 'points_per_100', 7, 'identity', 2, array['b_app']);
    raise exception 'identical reward rules must still collide';
  exception when unique_violation then null; end;
  insert into cap_rules (card_product_id, label, measure, period, cap_value, cap_kind, cap_amount, min_engine_version)
    values (v_card, 'same label', 'reward_value', 'calendar_month', 0, 'bonus_points', 100, 2);
  insert into cap_rules (card_product_id, label, measure, period, cap_value, cap_kind, cap_amount, min_engine_version)
    values (v_card, 'same label', 'reward_value', 'calendar_month', 0, 'total_points', 100, 2);
  begin
    insert into cap_rules (card_product_id, label, measure, period, cap_value, cap_kind, cap_amount, min_engine_version)
      values (v_card, ' SAME  label', 'reward_value', 'calendar_month', 0, 'total_points', 100, 2);
    raise exception 'label-normalised identical caps must still collide';
  exception when unique_violation then null; end;
  insert into milestone_rules (card_product_id, label, threshold_spend_inr, reward_description, reward_value_inr, reward_points)
    values (v_card, 'M', 1, 'd', 0, 1);
  insert into milestone_rules (card_product_id, label, threshold_spend_inr, reward_description, reward_value_inr, reward_points)
    values (v_card, 'M', 1, 'd', 0, 2);

  -- D7: extra rounding modes
  update card_products set accrual_rounding = 'points_half_up' where id = v_card;
  update card_products set accrual_rounding = 'points_floor' where id = v_card;
  begin
    update card_products set accrual_rounding = 'ceil' where id = v_card;
    raise exception 'accrual_rounding check too loose';
  exception when check_violation then null; end;
  update card_products set accrual_rounding = 'floor' where id = v_card;

  -- D11: cashback_rounding
  update card_products set cashback_rounding = 'rupee_floor' where id = v_card;
  update card_products set cashback_rounding = 'rupee_half_up' where id = v_card;
  update card_products set cashback_rounding = 'paise' where id = v_card;
  begin
    update card_products set cashback_rounding = 'ceil' where id = v_card;
    raise exception 'cashback_rounding check too loose';
  exception when check_violation then null; end;
  update card_products set cashback_rounding = 'rupee_floor' where id = v_card;
  select to_jsonb(x) into v2 from v_card_catalogue_export_v2 x where x.id = v_card;
  select to_jsonb(x) into v1 from v_card_catalogue_export x where x.id = v_card;
  if v2->>'cashback_rounding' is distinct from 'rupee_floor' then
    raise exception 'v2 view must return cashback_rounding';
  end if;
  if v1 ? 'cashback_rounding' then
    raise exception 'v1 view must not return cashback_rounding';
  end if;
  if (select cashback_rounding from v_admin_card_catalogue_export where id = v_card) is distinct from 'rupee_floor' then
    raise exception 'admin view must return cashback_rounding';
  end if;

  -- D2: v1 view hides engine-1 caps tied to a hidden rule
  insert into cap_rules (card_product_id, reward_rule_id, label, measure, period, cap_value)
    values (v_card, v_rule2, 'cap on hidden rule', 'spend_amount', 'calendar_month', 500)
    returning id into v_cap3;
  insert into cap_rules (card_product_id, label, measure, period, cap_value)
    values (v_card, 'cap targeting info rule', 'spend_amount', 'calendar_month', 600)
    returning id into v_cap4;
  insert into cap_rule_targets (cap_rule_id, reward_rule_id) values (v_cap4, v_rule3);
  select to_jsonb(x) into v1 from v_card_catalogue_export x where x.id = v_card;
  select to_jsonb(x) into v2 from v_card_catalogue_export_v2 x where x.id = v_card;
  if exists (select 1 from jsonb_array_elements(v1->'cap_rules') c where (c->>'id')::uuid in (v_cap3, v_cap4)) then
    raise exception 'v1 view must hide caps tied to hidden rules';
  end if;
  if (select count(*) from jsonb_array_elements(v2->'cap_rules') c where (c->>'id')::uuid in (v_cap3, v_cap4)) <> 2 then
    raise exception 'v2 view must show caps tied to hidden rules';
  end if;

  -- draft card cap target (for the non-admin read check)
  insert into reward_rules (card_product_id, unit, rate) values (v_draft, 'points_per_100', 1) returning id into v_dr;
  insert into cap_rules (card_product_id, label, measure, period, cap_value) values (v_draft, 'draft cap', 'spend_amount', 'calendar_month', 1) returning id into v_dcap;
  insert into cap_rule_targets (cap_rule_id, reward_rule_id) values (v_dcap, v_dr);
  insert into t_ids values ('draft_cap', v_dcap);

  -- directory fixtures for the RLS checks
  insert into merchant_brands (slug, name, parent_slug, aliases) values
    ('wp1_parent', 'WP1 Parent', null, array['wp1 parent']),
    ('wp1_child', 'WP1 Child', 'wp1_parent', array['wp1 child']);
  insert into payment_platforms (slug, name, kind) values ('wp1_app', 'WP1 App', 'payment_app');

  insert into t_ids values ('card', v_card), ('draft', v_draft);
  insert into benefit_unlock_rules (card_product_id, kind, label, spend_threshold_inr, spend_window)
    values (v_draft, 'tier', 'Draft tier', 1, 'calendar_year');
  insert into cap_rule_targets (cap_rule_id, reward_rule_id)
    select k.id, r.id from cap_rules k join reward_rules r on r.card_product_id = k.card_product_id
     where k.card_product_id = v_card and k.id = v_cap2 and r.id = v_rule1;
end $$;

-- ── RLS as the customer runtime (non-admin) ──
set local role app_user;
do $$
declare n int;
begin
  if pandapay.is_admin() then raise exception 'app_user must not be admin'; end if;

  select count(*) into n from benefit_unlock_rules;
  if n <> 1 then raise exception 'non-admin must see only published-card unlock rules, saw %', n; end if;

  select count(*) into n from cap_rule_targets;
  if n <> 3 then raise exception 'non-admin must see targets of published cards only, saw %', n; end if;
  select count(*) into n from cap_rule_targets where cap_rule_id = (select id from t_ids where k = 'draft_cap');
  if n <> 0 then raise exception 'non-admin must not see targets of a draft card cap'; end if;

  select count(*) into n from merchant_brands where slug like 'wp1\_%';
  if n <> 2 then raise exception 'merchant_brands must be publicly readable, saw %', n; end if;
  select count(*) into n from payment_platforms where slug = 'wp1_app';
  if n <> 1 then raise exception 'payment_platforms must be publicly readable'; end if;

  begin
    insert into merchant_brands (slug, name) values ('wp1_evil', 'x');
    raise exception 'non-admin insert into merchant_brands must fail';
  exception when insufficient_privilege then null; end;
  begin
    insert into payment_platforms (slug, name, kind) values ('wp1_evil', 'x', 'payment_app');
    raise exception 'non-admin insert into payment_platforms must fail';
  exception when insufficient_privilege then null; end;
  begin
    insert into benefit_unlock_rules (card_product_id, kind, label, spend_threshold_inr, spend_window)
      select id, 'tier', 'x', 1, 'calendar_year' from t_ids where k = 'card';
    raise exception 'non-admin insert into benefit_unlock_rules must fail';
  exception when insufficient_privilege then null; end;
  begin
    insert into cap_rule_targets (cap_rule_id, reward_rule_id)
      select k.id, r.id from cap_rules k, reward_rules r limit 1;
    raise exception 'non-admin insert into cap_rule_targets must fail';
  exception when insufficient_privilege then null; end;

  -- the public feeds work for the customer runtime
  select count(*) into n from v_card_catalogue_export_v2 where slug = 'wp1-test-card';
  if n <> 1 then raise exception 'v2 view not readable by app_user'; end if;
  select count(*) into n from v_card_catalogue_export where slug = 'wp1-test-draft';
  if n <> 0 then raise exception 'draft card visible in v1 feed'; end if;
end $$;
reset role;

rollback;
\echo 'card_rules_v2 migration test passed'
