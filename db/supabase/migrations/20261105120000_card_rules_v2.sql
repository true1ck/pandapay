-- >>> MIGRATION 20261105120000 — CARD REWARD RULES V2 (Card Rewards Phase 1, C1/C2)
-- Additive only (plan H3): every new column is nullable or defaulted, nothing
-- is dropped or renamed, so old server code keeps working during rollout.
--
-- The v1 public feed (v_card_catalogue_export) keeps its exact shape and enum
-- domains and hides everything v2-only (plan H1/H2):
--   * reward_rules with min_engine_version = 2 or rule_role = 'info'
--   * cap_rules with min_engine_version = 2
-- The v2 feed (v_card_catalogue_export_v2) publishes every rule, every role.

begin;

-- ── card_products ────────────────────────────────────────────────────────────
alter table card_products
  add column if not exists accrual_block_inr    int,
  add column if not exists accrual_rounding     text,
  add column if not exists cashback_rounding    text,
  add column if not exists points_expiry_months int,
  add column if not exists model_status         text not null default 'basic',
  add column if not exists model_coverage       jsonb not null default '{}'::jsonb;

alter table card_products
  add constraint card_accrual_rounding_known
    check (accrual_rounding is null or accrual_rounding in
      ('floor','round','none','points_half_up','points_floor')),
  add constraint card_cashback_rounding_known
    check (cashback_rounding is null or cashback_rounding in
      ('paise','rupee_floor','rupee_half_up')),
  add constraint card_model_status_known
    check (model_status in ('verified','partial','basic'));

-- ── reward_rules ─────────────────────────────────────────────────────────────
alter table reward_rules
  add column if not exists rule_role          text not null default 'earn',
  add column if not exists merchant_slugs     text[] not null default '{}',
  add column if not exists platform_slugs     text[] not null default '{}',
  add column if not exists mcc_include        text[] not null default '{}',
  add column if not exists mcc_exclude        text[] not null default '{}',
  add column if not exists block_inr          int,
  add column if not exists min_engine_version int not null default 1,
  add column if not exists source_local_id    text,
  add column if not exists display_note       text;

alter table reward_rules
  add constraint reward_rule_role_known
    check (rule_role in ('base','earn','exclusion','info')),
  add constraint reward_rule_engine_version_known
    check (min_engine_version between 1 and 2);

-- ── cap_rules ────────────────────────────────────────────────────────────────
alter table cap_rules
  add column if not exists cap_kind           text,
  add column if not exists cap_amount         numeric(14,2),
  add column if not exists scope              text not null default 'targets',
  add column if not exists parent_cap_id      uuid references cap_rules(id) on delete set null,
  add column if not exists post_cap_behavior  text,
  add column if not exists anchor             text,
  add column if not exists min_engine_version int not null default 1,
  add column if not exists source_local_id    text;

alter table cap_rules
  add constraint cap_rule_kind_known
    check (cap_kind is null or cap_kind in
      ('bonus_points','total_points','bonus_cashback','total_cashback','eligible_spend','txn_count')),
  add constraint cap_rule_scope_known
    check (scope in ('targets','card')),
  add constraint cap_rule_post_cap_behavior_known
    check (post_cap_behavior is null or post_cap_behavior in ('base_rate','zero','custom_rate')),
  add constraint cap_rule_anchor_known
    check (anchor is null or anchor in
      ('card_anniversary','calendar_year','fiscal_year','statement_cycle')),
  add constraint cap_rule_engine_version_known
    check (min_engine_version between 1 and 2);

create index if not exists idx_cap_rules_parent on cap_rules (parent_cap_id)
  where parent_cap_id is not null;

-- Which reward rules a cap covers (scope = 'targets').
create table cap_rule_targets (
  cap_rule_id     uuid not null references cap_rules(id) on delete cascade,
  reward_rule_id  uuid not null references reward_rules(id) on delete cascade,
  primary key (cap_rule_id, reward_rule_id)
);
create index idx_cap_rule_targets_reward_rule on cap_rule_targets (reward_rule_id);

-- cap_rule_targets has no card_product_id of its own, so the standard
-- bump_card_data_version() cannot read it; this sibling resolves the card via
-- the cap and then bumps the same data_version.
create or replace function pandapay.bump_card_data_version_via_cap() returns trigger
language plpgsql as $$
declare target uuid;
begin
  select card_product_id into target
    from cap_rules
   where id = coalesce(new.cap_rule_id, old.cap_rule_id);
  if target is not null then
    update card_products
       set data_version = data_version + 1,
           updated_at   = now()
     where id = target;
  end if;
  return coalesce(new, old);
end $$;

create trigger trg_cap_rule_targets_version
  after insert or update or delete on cap_rule_targets
  for each row execute function pandapay.bump_card_data_version_via_cap();

-- ── milestone_rules ──────────────────────────────────────────────────────────
alter table milestone_rules
  add column if not exists reward_points          numeric(14,2),
  add column if not exists reward_kind            text,
  add column if not exists excluded_category_ids  uuid[] not null default '{}',
  add column if not exists window_days            int,
  add column if not exists source_local_id        text;

alter table milestone_rules
  add constraint milestone_reward_kind_known
    check (reward_kind is null or reward_kind in
      ('points','voucher','cashback','fee_waiver','benefit','other'));

-- ── Identity indexes (C8 D1) ────────────────────────────────────────────────
-- Recreated with the v2 columns so two v2 rules/caps that differ only in v2
-- fields do not collide. The new keys only widen identity, so existing rows
-- cannot violate them. source_local_id is deliberately not part of identity.
drop index if exists uq_reward_rules_semantic_identity;
create unique index uq_reward_rules_semantic_identity
  on reward_rules (
    card_product_id, category_id, merchant_pattern, rail, unit, rate,
    min_txn_inr, max_txn_inr, priority, conditions, notes,
    effective_from, effective_to, excluded_categories,
    rule_role, merchant_slugs, platform_slugs, mcc_include, mcc_exclude,
    block_inr, min_engine_version
  ) nulls not distinct;

drop index if exists uq_cap_rules_semantic_identity;
create unique index uq_cap_rules_semantic_identity
  on cap_rules (
    card_product_id, reward_rule_id, category_id, benefit_kind, label, measure,
    period, cap_value, post_cap_unit, post_cap_rate, resets_on_day,
    cap_kind, cap_amount, scope, parent_cap_id, post_cap_behavior, anchor,
    min_engine_version
  ) nulls not distinct;

drop index if exists uq_cap_rules_label_identity_v1;
create unique index uq_cap_rules_label_identity_v1
  on cap_rules (
    card_product_id, reward_rule_id, category_id, benefit_kind,
    (pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(label, E'[\011-\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')) collate "C",
    measure, period, cap_value, post_cap_unit, post_cap_rate, resets_on_day,
    cap_kind, cap_amount, scope, parent_cap_id, post_cap_behavior, anchor,
    min_engine_version
  ) nulls not distinct;

drop index if exists uq_milestone_rules_semantic_identity;
create unique index uq_milestone_rules_semantic_identity
  on milestone_rules (
    card_product_id, label, period, threshold_spend_inr, reward_description,
    reward_value_inr, is_repeatable, max_repeats, anchor,
    reward_points, reward_kind, window_days, excluded_category_ids
  ) nulls not distinct;

-- ── benefit_unlock_rules (spend-gated benefits as structured data) ───────────
create table benefit_unlock_rules (
  id                    uuid primary key default gen_random_uuid(),
  card_product_id       uuid not null references card_products(id) on delete cascade,
  card_benefit_id       uuid references card_benefits(id) on delete cascade,
  kind                  text not null,
  label                 text not null,
  spend_threshold_inr   numeric(14,2) not null,
  spend_window          text not null,
  window_days           int,
  unlocks_quota         int,
  unlocks_period        cap_period,
  tier_label            text,
  excluded_category_ids uuid[] not null default '{}',
  notes                 text,
  source_local_id       text,
  created_at            timestamptz not null default now(),
  constraint benefit_unlock_kind_known
    check (kind in ('lounge_domestic','lounge_international','lounge_railway',
                    'fee_waiver','tier','welcome','membership','other')),
  constraint benefit_unlock_window_known
    check (spend_window in ('previous_calendar_quarter','current_calendar_quarter',
                            'previous_calendar_month','calendar_month','card_year',
                            'calendar_year','first_days_after_issue','rolling_days'))
);
create index idx_benefit_unlock_rules_card on benefit_unlock_rules (card_product_id);
create trigger trg_benefit_unlock_rules_version
  after insert or update or delete on benefit_unlock_rules
  for each row execute function pandapay.bump_card_data_version();

-- ── merchant and platform directory (public read, admin write) ───────────────
create table merchant_brands (
  slug          text primary key check (slug ~ '^[a-z0-9_]+$'),
  name          text not null,
  parent_slug   text references merchant_brands(slug),
  category_slug text,
  aliases       text[] not null default '{}',
  vpa_prefixes  text[] not null default '{}',
  mcc           text[] not null default '{}',
  is_active     boolean not null default true,
  updated_at    timestamptz not null default now()
);
create index idx_merchant_brands_parent on merchant_brands (parent_slug)
  where parent_slug is not null;
create trigger trg_merchant_brands_touch
  before update on merchant_brands
  for each row execute function pandapay.touch_updated_at();

create table payment_platforms (
  slug        text primary key check (slug ~ '^[a-z0-9_]+$'),
  name        text not null,
  kind        text not null,
  issuer_slug text,
  aliases     text[] not null default '{}',
  notes       text,
  is_active   boolean not null default true,
  constraint payment_platform_kind_known
    check (kind in ('payment_app','bank_portal','merchant_app','network_program'))
);

-- ── RLS: published-or-admin read on card children, admin write ───────────────
alter table benefit_unlock_rules enable row level security;
create policy benefit_unlock_rules_public_read on benefit_unlock_rules for select to public
  using (exists (
    select 1 from card_products cp
     where cp.id = benefit_unlock_rules.card_product_id
       and (cp.status = 'published' or pandapay.is_admin())));
create policy benefit_unlock_rules_admin_write on benefit_unlock_rules for all to public
  using (pandapay.is_admin()) with check (pandapay.is_admin());

alter table cap_rule_targets enable row level security;
create policy cap_rule_targets_public_read on cap_rule_targets for select to public
  using (exists (
    select 1 from cap_rules k
      join card_products cp on cp.id = k.card_product_id
     where k.id = cap_rule_targets.cap_rule_id
       and (cp.status = 'published' or pandapay.is_admin())));
create policy cap_rule_targets_admin_write on cap_rule_targets for all to public
  using (pandapay.is_admin()) with check (pandapay.is_admin());

alter table merchant_brands enable row level security;
create policy merchant_brands_public_read on merchant_brands for select to public using (true);
create policy merchant_brands_admin_write on merchant_brands for all to public
  using (pandapay.is_admin()) with check (pandapay.is_admin());

alter table payment_platforms enable row level security;
create policy payment_platforms_public_read on payment_platforms for select to public using (true);
create policy payment_platforms_admin_write on payment_platforms for all to public
  using (pandapay.is_admin()) with check (pandapay.is_admin());

-- The private admin runtime (20261030100000) guards each admin-writable table
-- with restrictive per-permission policies. Give the new tables the same
-- catalogue.read / catalogue.edit|publish treatment.
do $$
declare
  t text;
  guard text := 'pandapay.admin_has_permission(current_setting(''pandapay.admin_permission'',true)) '
    || 'AND current_setting(''pandapay.admin_permission'',true)=ANY(''{catalogue.edit,catalogue.publish}''::text[])';
begin
  if not exists (select 1 from pg_roles where rolname = 'pandapay_admin_api') then
    return;
  end if;
  foreach t in array array['benefit_unlock_rules','cap_rule_targets','merchant_brands','payment_platforms'] loop
    execute format('create policy private_admin_read_guard on public.%I as restrictive for select to pandapay_admin_api using (pandapay.admin_has_permission(%L))', t, 'catalogue.read');
    execute format('create policy private_admin_insert_guard on public.%I as restrictive for insert to pandapay_admin_api with check (%s)', t, guard);
    execute format('create policy private_admin_update_guard on public.%I as restrictive for update to pandapay_admin_api using (%s) with check (%s)', t, guard, guard);
    execute format('create policy private_admin_delete_guard on public.%I as restrictive for delete to pandapay_admin_api using (%s)', t, guard);
    execute format('grant select, insert, update, delete on public.%I to pandapay_admin_api', t);
  end loop;
end $$;

-- ── v1 public feed: same shape, v2-only rows hidden ──────────────────────────
-- Only the two child filters change; every key and the column order are as in
-- migration 0043.
create or replace view v_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.data_version, c.verified_at,
  c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id
               and r.min_engine_version = 1 and r.rule_role <> 'info'), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(to_jsonb(k) - 'card_product_id') from cap_rules k
             where k.card_product_id = c.id
               and k.min_engine_version = 1
               and not exists (select 1 from reward_rules rr
                                where rr.id = k.reward_rule_id
                                  and (rr.min_engine_version <> 1 or rr.rule_role = 'info'))
               and not exists (select 1 from cap_rule_targets t
                                join reward_rules rr on rr.id = t.reward_rule_id
                               where t.cap_rule_id = k.id
                                 and (rr.min_engine_version <> 1 or rr.rule_role = 'info'))
          ), '[]'::jsonb) as cap_rules,
  coalesce((select jsonb_agg(to_jsonb(m) - 'card_product_id') from milestone_rules m
             where m.card_product_id = c.id), '[]'::jsonb) as milestone_rules,
  coalesce((select jsonb_agg(to_jsonb(f) - 'card_product_id') from fee_waiver_rules f
             where f.card_product_id = c.id), '[]'::jsonb) as fee_waiver_rules,
  coalesce((select jsonb_agg(to_jsonb(b) - 'card_product_id') from card_benefits b
             where b.card_product_id = c.id), '[]'::jsonb) as benefits,
  (select to_jsonb(x) - 'card_product_id' from forex_rules x where x.card_product_id = c.id) as forex,
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel,
  c.base_reward_unit, c.base_reward_rate,
  (c.apply_url is not null and c.apply_url <> '') as has_apply_url,
  c.excluded_categories,
  coalesce((
    select jsonb_agg(
      jsonb_build_object('id', v.id, 'network', v.network,
        'network_tier', v.network_tier, 'label', v.label)
      order by v.network::text, v.network_tier
    )
    from card_product_network_variants v
    where v.card_product_id = c.id and v.is_active
  ), '[]'::jsonb) as network_variants
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

-- ── v2 public feed: everything, plus targets, unlock rules, redemption ───────
create or replace view v_card_catalogue_export_v2 as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.data_version, c.verified_at,
  c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(
              (to_jsonb(k) - 'card_product_id') || jsonb_build_object('targets',
                coalesce((select jsonb_agg(t.reward_rule_id order by t.reward_rule_id)
                            from cap_rule_targets t where t.cap_rule_id = k.id), '[]'::jsonb)))
              from cap_rules k
             where k.card_product_id = c.id), '[]'::jsonb) as cap_rules,
  coalesce((select jsonb_agg(to_jsonb(m) - 'card_product_id') from milestone_rules m
             where m.card_product_id = c.id), '[]'::jsonb) as milestone_rules,
  coalesce((select jsonb_agg(to_jsonb(f) - 'card_product_id') from fee_waiver_rules f
             where f.card_product_id = c.id), '[]'::jsonb) as fee_waiver_rules,
  coalesce((select jsonb_agg(to_jsonb(b) - 'card_product_id') from card_benefits b
             where b.card_product_id = c.id), '[]'::jsonb) as benefits,
  (select to_jsonb(x) - 'card_product_id' from forex_rules x where x.card_product_id = c.id) as forex,
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel,
  c.base_reward_unit, c.base_reward_rate,
  (c.apply_url is not null and c.apply_url <> '') as has_apply_url,
  c.excluded_categories,
  coalesce((
    select jsonb_agg(
      jsonb_build_object('id', v.id, 'network', v.network,
        'network_tier', v.network_tier, 'label', v.label)
      order by v.network::text, v.network_tier
    )
    from card_product_network_variants v
    where v.card_product_id = c.id and v.is_active
  ), '[]'::jsonb) as network_variants,
  c.accrual_block_inr, c.accrual_rounding, c.cashback_rounding, c.points_expiry_months,
  c.model_status, c.model_coverage,
  coalesce((select jsonb_agg(to_jsonb(u) - 'card_product_id') from benefit_unlock_rules u
             where u.card_product_id = c.id), '[]'::jsonb) as unlock_rules,
  coalesce((select jsonb_agg(to_jsonb(rd) - 'card_product_id') from redemption_options rd
             where rd.card_product_id = c.id), '[]'::jsonb) as redemption_options
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

-- ── admin feed: append the v2 card fields and child collections ──────────────
create or replace view v_admin_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.status, c.data_version,
  c.verified_at, c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(
              (to_jsonb(k) - 'card_product_id') || jsonb_build_object('targets',
                coalesce((select jsonb_agg(t.reward_rule_id order by t.reward_rule_id)
                            from cap_rule_targets t where t.cap_rule_id = k.id), '[]'::jsonb)))
              from cap_rules k
             where k.card_product_id = c.id), '[]'::jsonb) as cap_rules,
  coalesce((select jsonb_agg(to_jsonb(m) - 'card_product_id') from milestone_rules m
             where m.card_product_id = c.id), '[]'::jsonb) as milestone_rules,
  coalesce((select jsonb_agg(to_jsonb(f) - 'card_product_id') from fee_waiver_rules f
             where f.card_product_id = c.id), '[]'::jsonb) as fee_waiver_rules,
  coalesce((select jsonb_agg(to_jsonb(b) - 'card_product_id') from card_benefits b
             where b.card_product_id = c.id), '[]'::jsonb) as benefits,
  (select to_jsonb(x) - 'card_product_id' from forex_rules x where x.card_product_id = c.id) as forex,
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel,
  (select to_jsonb(z) - 'card_product_id' from billing_cycle_rules z where z.card_product_id = c.id) as billing_cycle,
  coalesce((select jsonb_agg(to_jsonb(rd) - 'card_product_id') from redemption_options rd
             where rd.card_product_id = c.id), '[]'::jsonb) as redemption_options,
  c.base_reward_unit, c.base_reward_rate,
  c.extended_data,
  c.excluded_categories,
  c.import_source_hash,
  c.import_source_run_id,
  c.imported_at,
  c.import_transform_version,
  coalesce((
    select jsonb_agg(to_jsonb(v) - 'card_product_id' order by v.network::text, v.network_tier)
    from card_product_network_variants v
    where v.card_product_id = c.id and v.is_active
  ), '[]'::jsonb) as network_variants,
  c.accrual_block_inr, c.accrual_rounding, c.cashback_rounding, c.points_expiry_months,
  c.model_status, c.model_coverage,
  coalesce((select jsonb_agg(to_jsonb(u) - 'card_product_id') from benefit_unlock_rules u
             where u.card_product_id = c.id), '[]'::jsonb) as unlock_rules
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;

commit;
