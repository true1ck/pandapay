-- >>> MIGRATION 0038 — RULE CONSTRAINTS, EXCLUSIONS, POST-CAP SEMANTICS ======
--
-- Three related correctness fixes to how a card's earning rules are
-- modelled. All of them close gaps where the SCHEMA already carried the
-- information and the ENGINE ignored it, so this migration is mostly about
-- making "unspecified" expressible and adding the two columns that had no
-- home at all.
--
-- DEVICE SYNC CONTRACT (DB-2.7, see 0010's own comment): additive only.
-- `excluded_categories` defaults to '{}' on both new columns and
-- CardProductJson/RewardRuleJson read them as optional, so an older client
-- that doesn't know about them decodes exactly as before. The one
-- non-additive change is `cap_rules.post_cap_rate` becoming nullable, which
-- widens the domain rather than narrowing it — an older client parsing it
-- as a non-null number would now see null, so this DOES need the app
-- version shipping alongside it (CapRuleJson.fromJson reads it via
-- _numOrNull as of the same change).

-- ---------------------------------------------------------------------------
-- 1. post_cap_rate: 0 and "unspecified" must stop being the same value.
-- ---------------------------------------------------------------------------
--
-- The column was `numeric(8,4) not null default 0`, so every cap rule ever
-- written carries 0 — and the engine read that as "this card earns nothing
-- once the cap is spent". That is not what an issuer means. The Indian
-- market wording is "5% on groceries up to ₹3,000/month", with "and 1%
-- after that" left implicit because the 1% is just the card's ordinary base
-- rate. Reading the implicit case as zero made a cap-exhausted 5% card
-- report ₹0 on further spend and sort BELOW cards that were genuinely worse
-- than its own base rate — wrong in both directions at once.
--
-- Null now means "the catalogue doesn't say; fall back to
-- card_products.base_reward_rate", which RecommendationEngine.resolvePostCapRate
-- implements. An explicit 0 still means an explicit 0.
alter table cap_rules alter column post_cap_rate drop default;
alter table cap_rules alter column post_cap_rate drop not null;

-- Backfill: rows where the rate is 0 AND no unit was given were never
-- deliberately set — 0 is just the old column default and post_cap_unit is
-- what an editor would have had to fill in to mean it. Rows with a unit are
-- left alone: someone chose those, and an explicit "earns nothing past the
-- cap" is a real (if uncommon) card term we must not overwrite.
update cap_rules set post_cap_rate = null
 where post_cap_rate = 0 and post_cap_unit is null;

comment on column cap_rules.post_cap_rate is
  'What one rupee earns once the cap is spent. NULL = the catalogue does not '
  'say, so the card''s base_reward_rate applies (the normal case). An '
  'explicit 0 means the card genuinely earns nothing past the cap.';

-- ---------------------------------------------------------------------------
-- 2. Category exclusions.
-- ---------------------------------------------------------------------------
--
-- Indian issuers near-universally exclude rent, wallet loads, fuel,
-- insurance premiums, government payments, EMI conversions and gift cards
-- from earning. Only fee_waiver_rules could express this (0003:118); there
-- was no way to say it about a reward rule or about a card as a whole, so
-- the app promised rewards on spend that earns nothing — the single most
-- trust-damaging thing a rewards optimizer can do.
--
-- Same uuid[] shape and same '{}' default as fee_waiver_rules.excluded_categories,
-- so the console editor and the JSON contract are consistent across all
-- three.

-- Card-level: earns nothing at ANY rate, base rate included.
alter table card_products add column if not exists excluded_categories uuid[] not null default '{}';
comment on column card_products.excluded_categories is
  'Categories this card earns nothing on at any rate, base rate included. '
  'The engine returns these as an exclusion with a reason rather than '
  'quietly paying a rate the card does not honour.';

-- Rule-level: this accelerated rule does not pay here, but the card still
-- earns its base rate. A weaker statement than the card-level one.
alter table reward_rules add column if not exists excluded_categories uuid[] not null default '{}';
comment on column reward_rules.excluded_categories is
  'Categories this specific rule does not pay on. Weaker than '
  'card_products.excluded_categories: the card still earns its base rate.';

-- ---------------------------------------------------------------------------
-- 3. Expose card-level exclusions on the two catalogue export views.
-- ---------------------------------------------------------------------------
--
-- reward_rules.excluded_categories needs no view change — both views select
-- `to_jsonb(r)` over the whole row, so a new column on that table flows
-- through automatically. card_products columns are named individually and
-- so must be added by hand.
--
-- APPENDED to the end of each select list: CREATE OR REPLACE VIEW may only
-- ADD columns at the end, and dropping these views would cascade through
-- the RLS grants in 0011/0015. Same constraint 0023 documented.
--
-- CRITICAL, and the reason this block is longer than it looks like it
-- should be: each definition must reproduce the view's CURRENT shape, not
-- the one 0023 left behind. Later migrations appended their own trailing
-- columns — `has_apply_url` (0030) on the device view, `extended_data`
-- (0037) on the admin view — and rebuilding from 0023's text silently drops
-- them. Postgres does not treat that as a drop: it sees a rename of the
-- trailing column and refuses with
--   "cannot change name of view column has_apply_url to excluded_categories"
-- which is a confusing message for what is really "your view definition is
-- out of date". Anything appended here in future must go AFTER these.

create or replace view v_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.data_version, c.verified_at,
  c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(to_jsonb(k) - 'card_product_id') from cap_rules k
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
  -- 0030's trailing column. Must stay in this position.
  (c.apply_url is not null and c.apply_url <> '') as has_apply_url,
  c.excluded_categories
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

create or replace view v_admin_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.status, c.data_version,
  c.verified_at, c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(to_jsonb(k) - 'card_product_id') from cap_rules k
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
  -- 0037's trailing column. Must stay in this position.
  c.extended_data,
  c.excluded_categories
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;
