-- >>> MIGRATION 0037 — CARD CATALOGUE PROVENANCE =================================
--
-- The catalogue is already normalized well enough for ranking. This migration
-- adds the missing provenance layer so structured scraping can preserve
-- multiple source URLs, evidence excerpts, and verification metadata without
-- flattening every upstream variation into a bespoke table column.

alter table card_products
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_links jsonb not null default '{}'::jsonb,
  add column if not exists source_excerpt text,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

comment on column card_products.source_class is
  'Provenance label for the latest canonical row source: issuer_official, third_party_structured, third_party_page, or community_open_source.';

comment on column card_products.source_links is
  'Structured source URLs for the card product, e.g. canonical, brochure, FAQ, T&C, or application page.';

comment on column card_products.provenance is
  'Opaque provenance blob for the latest published row: source ids, excerpts, verification notes, or crawl metadata.';

alter table reward_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table cap_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table milestone_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table fee_waiver_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table card_benefits
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table forex_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table fuel_surcharge_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table billing_cycle_rules
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table redemption_options
  add column if not exists source_url text,
  add column if not exists source_page_id uuid references source_pages(id) on delete set null,
  add column if not exists source_class text,
  add column if not exists source_license text,
  add column if not exists source_excerpt text,
  add column if not exists verified_at timestamptz,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

alter table card_source_drafts
  add column if not exists page_role text,
  add column if not exists source_priority int,
  add column if not exists source_links jsonb not null default '{}'::jsonb,
  add column if not exists raw_text text,
  add column if not exists provenance jsonb not null default '{}'::jsonb;

comment on column card_source_drafts.page_role is
  'Source page role or dataset role, e.g. product_page, brochure_pdf, tnc, faq, or structured_dataset.';

comment on column card_source_drafts.source_priority is
  'Lower numbers mean higher trust/priority when multiple sources produce the same card key.';

comment on column card_source_drafts.source_links is
  'All source URLs associated with the draft, not just the primary fetch URL.';

comment on column card_source_drafts.raw_text is
  'Optional extracted text or normalised text used to produce the draft, useful for human review.';

comment on column card_source_drafts.provenance is
  'Opaque ingestion metadata for the draft: crawl ids, parser version, or corroboration notes.';
