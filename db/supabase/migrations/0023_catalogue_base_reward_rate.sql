-- >>> MIGRATION 0023 — CATALOGUE EXPORT: BASE REWARD RATE =====================
--
-- Expose card_products.base_reward_unit / base_reward_rate on the two
-- catalogue export views.
--
-- Both columns have existed on card_products since 0003 and every seeded
-- card sets them, but neither view selected them, so the API never sent
-- them and the client model never had them. The consequence was visible on
-- Home: RecommendationEngine._evaluate() matches reward_rules by category
-- and, finding none, excluded the card with "No applicable reward rule."
-- For a category no card enumerates — most of them, since the seed carries
-- roughly one category rule per card — that meant every card read ₹0 and
-- Home had no verdict to show at all. A 1% cashback card does not earn
-- nothing at a pharmacy; the engine now falls back to this base rate.
--
-- DEVICE SYNC CONTRACT (DB-2.7, see 0010's own comment): additive only —
-- no column removed or retyped, and CardProductJson.fromJson reads both as
-- optional — so no app-version gate is needed. Older clients ignore them.
--
-- Both new columns are APPENDED to the end of each select list, not slotted
-- in beside point_value_inr where they'd read better: CREATE OR REPLACE
-- VIEW may only add columns at the end, and dropping these views would
-- cascade through the RLS grants in 0011/0015.

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
  c.base_reward_unit, c.base_reward_rate
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
  c.base_reward_unit, c.base_reward_rate
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;
