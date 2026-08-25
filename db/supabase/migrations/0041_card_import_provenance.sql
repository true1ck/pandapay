-- >>> MIGRATION 0041 — CARD IMPORT PROVENANCE + RE-RUN IDEMPOTENCY ==========
--
-- 0037 made the CardPipeline import possible. This makes it repeatable.
--
-- ============================================================================
-- THE PROBLEM
-- ============================================================================
-- The extraction is a live, multi-day process — 392 cards, a handful finishing
-- per hour, restarted across many runs. The intended workflow is therefore to
-- re-run the importer regularly and pick up whatever has finished since.
--
-- Re-running today is correct but expensive. upsertCardProduct() refreshes any
-- card still in 'draft' unconditionally: it UPDATEs the parent row and then
-- DELETEs and re-INSERTs every reward_rule, cap_rule, milestone_rule,
-- fee_waiver_rule, benefit and redemption_option beneath it. For a card whose
-- extraction has not changed since the last run, that is a large amount of
-- write traffic to arrive at byte-identical data.
--
-- It is not merely wasteful. Every one of those child writes fires
-- pandapay.bump_card_data_version() (0003), which is the device sync key:
--
--     devices pull cards where data_version > catalogue_version_seen
--
-- So a no-op re-import of 392 cards bumps 392 data_versions by ~6 each, and
-- every installed app then re-downloads the entire published catalogue to
-- receive data it already has. Running the sync hourly would keep every device
-- in a permanent state of re-syncing nothing.
--
-- ============================================================================
-- THE FIX
-- ============================================================================
-- Store a hash of the exact source record each card was built from. On a
-- re-run the importer hashes the incoming record, compares, and skips the
-- whole card when they match — no UPDATE, no child churn, no version bump.
-- Cards whose extraction genuinely changed still refresh normally.
--
-- The hash is over the canonicalised source JSON (recursively key-sorted), so
-- a re-serialisation that only reorders keys is correctly recognised as the
-- same content rather than looking like an edit.
--
-- ============================================================================
-- WHY THESE COLUMNS ARE ALSO WORTH HAVING ON THEIR OWN
-- ============================================================================
-- import_source_run_id answers the question a human reviewer actually asks
-- when a value looks wrong: "where did this number come from?" It points at
-- results/<run_id>/items/<card>.json, which holds the full stage-by-stage
-- audit trail — prompt, raw response, and final — for that extraction. Without
-- it, a draft card in the console is a set of numbers with no traceable
-- origin, and the reviewer's only recourse is to guess which run produced it.
--
-- These are DELIBERATELY NOT on v_card_catalogue_export. Provenance is
-- reviewer context; devices rank cards and have no use for it, and adding
-- columns to the device view costs every device bandwidth on every sync.
-- Appended to the admin view only.
--
-- DEVICE SYNC CONTRACT (DB-2.7): additive only. New nullable columns, and
-- four columns appended at the END of the admin view — see 0038's own header
-- for what happens when a view is rebuilt from stale text and drops the
-- trailing columns a later migration added.

begin;

alter table card_products
  add column if not exists import_source_hash   text,
  add column if not exists import_source_run_id text,
  add column if not exists import_transform_version text,
  add column if not exists imported_at          timestamptz;

alter table card_products
  drop constraint if exists card_products_import_source_hash_sha256;
alter table card_products
  add constraint card_products_import_source_hash_sha256
  check (import_source_hash is null or import_source_hash ~ '^[0-9a-f]{64}$');

comment on column card_products.import_source_hash is
  'sha256 of the canonicalised (recursively key-sorted) CardPipeline source '
  'record this card was built from. The importer skips a card entirely when '
  'this and import_transform_version match, which stops a no-op re-run from '
  'bumping data_version and forcing every device to re-sync. NULL for cards '
  'created by hand, by db/seed/, or before this migration — those are always '
  'treated as "changed" and refreshed on the next import, which is the safe '
  'direction to be wrong in.';

comment on column card_products.import_source_run_id is
  'CardPipeline run id (e.g. 20260826-011515) that produced the extraction '
  'behind this card. The full audit trail for it lives in that project at '
  'results/<run_id>/items/<card-id>.json — prompts, raw provider responses '
  'and the final record. This is the reviewer''s path back to the source when '
  'a fee or a reward rate on a draft card looks wrong.';

comment on column card_products.imported_at is
  'When the importer last WROTE this card. Unchanged by a skipped no-op '
  'run, so it reflects the last real change rather than the last time the '
  'sync script happened to be executed. Distinct from verified_at, which is '
  'a human''s claim to have checked the card against the issuer and is never '
  'set by any automated path.';

comment on column card_products.import_transform_version is
  'Version of import_card_pipeline.js mapping semantics used to build the '
  'structured catalogue rows. The importer refreshes a draft when this '
  'differs even if import_source_hash is unchanged, so mapping fixes reach '
  'existing drafts. Reviewed/published cards remain protected unless an '
  'operator explicitly uses --force.';

-- Re-import matches on card_products.slug (the importer's identity for a
-- card); the hash comparison is a follow-up read on the row already found by
-- that unique index, so no index is needed on the hash itself.

-- ---------------------------------------------------------------------------
-- Admin export view: append the four provenance columns AFTER 0037's
-- extended_data and 0038's excluded_categories. Reproduced in full because
-- CREATE OR REPLACE VIEW cannot add a column any other way, and the whole
-- body must be restated exactly as it currently stands.
-- ---------------------------------------------------------------------------
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
  -- 0038's trailing column. Must stay in this position.
  c.excluded_categories,
  -- 0041 appends here. Anything added in future goes AFTER these four.
  c.import_source_hash,
  c.import_source_run_id,
  c.imported_at,
  c.import_transform_version
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;

commit;
