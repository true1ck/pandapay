-- >>> MIGRATION 0037 — CARD CATALOGUE BULK IMPORT SUPPORT ====================
--
-- Prep for importing CardPipeline's LLM-extracted card data
-- (/Users/chandresh_kerkar/Documents/PandaPath/CardPipeline) into card_products.
-- That source's 18-section schema captures a lot more than this schema has
-- columns for — eligibility criteria, APR/cash-advance/EMI fee detail,
-- statement/late-fee slabs, add-on card rules, brand-specific voucher caps,
-- promo registries. None of it is read by RecommendationEngine today, and
-- none of it should be silently dropped on the floor either: extended_data
-- is a single reference-only catch-all so a human reviewing an imported
-- draft card can still see everything the extraction found, even the parts
-- with nowhere structured to go yet.
--
-- DEVICE SYNC CONTRACT (DB-2.7, see 0010/0023's own comments): additive
-- only. extended_data is appended to v_admin_card_catalogue_export (admin/
-- reviewer context) only, NOT to the public v_card_catalogue_export devices
-- sync from — it is not ranking input, so it never needs to reach a device.

begin;

alter table card_products
  add column if not exists extended_data jsonb not null default '{}'::jsonb;

comment on column card_products.extended_data is
  'Catch-all for CardPipeline-sourced fields with no dedicated column: '
  'eligibility_engine, fees_and_surcharges (apr/cash_advance/'
  'category_surcharges/emi_charges/banking_penalties/reward_redemption_fee/'
  'dynamic_currency_conversion_dcc — forex_markup and fuel_surcharge DO have '
  'real tables, forex_rules/fuel_surcharge_rules, and are never duplicated '
  'here), statement_and_late_fees (minus grace_period_days, which maps to '
  'billing_cycle_rules), addon_card_rules, brand_specific_voucher_caps, '
  'dynamic_promotions_registry, additional_data, plus card_product-level '
  'extras (network_tier, card_tier, bin_ranges, application_mode, '
  'form_factors, tokenization_support, data_source_tier, schema_version). '
  'Reference-only — RecommendationEngine never reads this column, and it is '
  'intentionally excluded from v_card_catalogue_export (devices never '
  'receive it).';

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
  c.extended_data
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;

commit;
