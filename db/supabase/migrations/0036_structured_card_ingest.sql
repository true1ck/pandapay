-- >>> MIGRATION 0036 — STRUCTURED CARD INGEST =================================
--
-- This migration adds a lightweight staging surface for structured third-party
-- and issuer-sourced card facts. The goal is to keep provenance and raw source
-- payloads while still allowing the rest of the codebase to reason about a
-- normalized, reviewable draft before promotion into `card_products`.

alter table sources
  add column if not exists source_class text not null default 'issuer_official',
  add column if not exists source_priority int not null default 100,
  add column if not exists license_note text,
  add column if not exists last_verified_at timestamptz;

comment on column sources.source_class is
  'High-level origin of the source: issuer_official, third_party_structured, third_party_page, community_open_source.';

create table if not exists card_source_drafts (
  id                  uuid primary key default gen_random_uuid(),
  source_id           uuid not null references sources(id) on delete cascade,
  source_page_id      uuid references source_pages(id) on delete set null,
  source_url          text not null,
  source_class        text not null,
  source_license      text,
  card_key            text not null,
  card_name           text not null,
  issuer_name         text not null,
  network             text,
  tier                text,
  as_of               date,
  source_payload      jsonb not null,
  normalized_fields   jsonb not null,
  field_confidence    jsonb not null default '{}'::jsonb,
  evidence            jsonb not null default '[]'::jsonb,
  status              text not null default 'draft'
                      check (status in ('draft', 'ready', 'rejected', 'promoted')),
  confidence          numeric(4,3),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (source_id, card_key)
);

create index if not exists idx_card_source_drafts_status
  on card_source_drafts (status, created_at desc);

create index if not exists idx_card_source_drafts_card_key
  on card_source_drafts (card_key, source_id);
