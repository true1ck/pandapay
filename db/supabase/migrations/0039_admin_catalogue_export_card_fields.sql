-- >>> MIGRATION 0039 — ADMIN CATALOGUE EXPORT: CARD OWN FIELDS ================
--
-- v_admin_card_catalogue_export (0022, extended by 0023) already returns
-- every reward_rules/cap_rules/.../redemption_options column plus a handful
-- of card_products columns, but not all of them: fee_gst_applicable,
-- point_value_basis, positioning_notes, source_url and verified_by were
-- never selected, so the console's new "Card Info" tab (catalogue_screen.dart)
-- has nothing to read/write those fields against. Same append-only rule as
-- 0023: CREATE OR REPLACE VIEW may only add columns at the end.
--
-- Also adds card_products' own provenance columns (source_class,
-- source_license, source_links, source_excerpt — added by 0037 alongside
-- the same columns on every child rule table, but never selected on the
-- parent row itself) for the console's new "Provenance" tab.
-- card_products.provenance (the opaque ingestion blob) is deliberately left
-- out — display-only, unstructured, not worth a column here.

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
  c.fee_gst_applicable, c.point_value_basis, c.positioning_notes, c.source_url, c.verified_by,
  c.source_class, c.source_license, c.source_links, c.source_excerpt
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;
