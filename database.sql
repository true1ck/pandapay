-- =============================================================================
--  PandaPay — Single Shared Database Schema  (PostgreSQL 15+ / Supabase)
-- =============================================================================
--  Companion to: product-plan.md, ui-spec.md, admin-console-plan.md,
--                Userappimplementation_plan.md, adminimplementation_plan.md
--
--  ONE DATABASE, BOTH SIDES.
--  This single Postgres instance backs all three applications:
--    1. PandaPay mobile app  (Flutter, Android-first)  — user-facing
--    2. PandaPay Console     (Next.js, internal)       — admin/data-ops
--    3. Ingest workers       (Cloudflare Email Worker, scraper, jobs)
--
--  There is exactly ONE copy of card data (admin-console-plan §4.5). The console
--  writes it, the app reads it, `data_version` drives incremental device sync.
--
--  DESIGN RULES ENFORCED BY THIS SCHEMA
--  R1. Card numbers are never stored. No column exists for one. (product-plan §17)
--  R2. Crowdsourced rows carry NO user identity, NO amount, NO exact coordinate,
--      NO individual timestamp. Enforced structurally + by CHECK constraints +
--      by the anonymization audit in §11. (product-plan §6.2)
--  R3. Every financial figure carries an estimated/confirmed state. (§5.10)
--  R4. Cards are archived, never hard-deleted, when they have history. (ui-spec)
--  R5. Nothing scraped or user-signalled auto-publishes. Every publish path
--      passes through a human approval row in `policy_change_alerts`. (§4.4)
--  R6. RLS default-deny on every user table; users can only ever see own rows.
--
-- =============================================================================
--  DATABASE IMPLEMENTATION PLAN  (workstream DB — run BEFORE app workstreams)
-- =============================================================================
--
--  DB-0  Provisioning                                                  [0.5 wk]
--    DB-0.1  Provision VPS + Supabase self-host (or managed) instance.
--    DB-0.2  Enable extensions: pgcrypto, citext, pg_trgm, postgis-lite via
--            cube/earthdistance OR plain lat/lng + geohash (chosen: geohash,
--            zero extension cost, sufficient for ~50m grid snapping).
--    DB-0.3  Create roles: `app_user` (RLS-bound), `ingest_worker` (service),
--            `console_admin`, `readonly_analytics`.
--    DB-0.4  Wire Supabase CLI, `supabase/migrations/` directory, CI check that
--            migrations apply cleanly to an empty DB on every PR.
--
--  DB-1  Core enums + reference tables (§1, §2)                        [0.5 wk]
--    DB-1.1  Enums.  DB-1.2 Issuers + networks.  DB-1.3 Spend category
--            taxonomy + MCC map (seed ~1000 MCCs).  DB-1.4 Emergency contacts.
--
--  DB-2  Card catalogue + reward rule model (§3)                       [1.5 wk]
--    DB-2.1  card_products with data_version + verified_at + publish status.
--    DB-2.2  reward_rules (rate model that supports %, points/₹100, miles).
--    DB-2.3  cap_rules, milestone_rules, fee_waiver_rules.
--    DB-2.4  lounge_benefits, forex_rules, fuel_surcharge_rules, card_benefits.
--    DB-2.5  redemption_options + point valuation.
--    DB-2.6  `bump_data_version` trigger on every child table — a cap change
--            must move the parent card's version or devices won't resync.
--    DB-2.7  `v_card_catalogue_export` view = exact payload devices download.
--            THIS VIEW IS THE DEVICE SYNC CONTRACT. Version it.
--
--  DB-3  User domain (§4, §5)                                          [1.5 wk]
--    DB-3.1  profiles, user_consents (DPDP audit trail), user_devices.
--    DB-3.2  user_cards + per-card tracker inputs (limit, cycle dates).
--    DB-3.3  transactions + splits + dedupe hash + estimated/confirmed state.
--    DB-3.4  card_overrides (manual "always use X here").
--    DB-3.5  Derived state tables: cap_states, milestone_states,
--            fee_waiver_states, lounge_usage, points_ledger.
--    DB-3.6  needs_review_items, duplicate_candidates, missed_opportunities.
--    DB-3.7  monthly_reports (materialized per user per month).
--
--  DB-4  Sync + conflict model (§6)                                    [1 wk]
--    DB-4.1  change_log append-only (device_id, entity, op, lww_clock).
--    DB-4.2  sync_cursors per device.
--    DB-4.3  sync_conflicts — every silent resolution MUST leave a row.
--    DB-4.4  Reconciliation RPCs: `sync_push`, `sync_pull`.
--
--  DB-5  Ingest pipeline (§7)                                          [1 wk]
--    DB-5.1  forwarding_addresses (unique per user, revocable).
--    DB-5.2  inbound_emails (raw retained 30d, then purged by cron).
--    DB-5.3  statement_imports, sms_import_batches.
--    DB-5.4  parser_patterns + parser_failures (feeds D4 queue + parser fixes).
--
--  DB-6  Crowdsource datasets (§8) — the moat                          [1.5 wk]
--    DB-6.1  merchants (VPA-keyed), merchant_locations (grid-snapped).
--    DB-6.2  merchant_contributions — device_hash only, NEVER user_id.
--    DB-6.3  acceptance_reports + acceptance_summary.
--    DB-6.4  effective_rate_samples + effective_rate_summary (Source B1).
--    DB-6.5  confidence scoring function + publish gate (N >= 2..3).
--    DB-6.6  contribution_quotas + abuse_signals (rate limit, poisoning guard).
--
--  DB-7  Admin console + policy change detection (§9, §10)             [1.5 wk]
--    DB-7.1  admin_users + admin_audit_log.
--    DB-7.2  sources (bank | news), source_pages, scrape_runs, page_snapshots.
--    DB-7.3  extraction_proposals (AI first pass, never live).
--    DB-7.4  policy_change_alerts + policy_alert_evidence — the unified queue
--            fed by 4 signals: scrape diff, empirical divergence, email
--            keyword hit, user error report.
--    DB-7.5  publish_transaction RPC: approve alert -> write catalogue ->
--            bump data_version -> write audit -> optionally force-sync flag.
--    DB-7.6  card_requests, data_error_reports queues.
--
--  DB-8  Platform / ops (§12)                                          [0.5 wk]
--    DB-8.1  feature_flags, remote_config, app_versions (forced upgrade),
--            kill_switches, changelog_entries.
--    DB-8.2  backup_runs + restore_drills (an untested backup is not a backup).
--    DB-8.3  anonymization_audit_runs (§11) wired into CI.
--
--  DB-9  Hardening                                                     [1 wk]
--    DB-9.1  RLS on 100% of user tables; automated test asserting no table in
--            `public` lacks RLS.
--    DB-9.2  Index pass against the real query list in the app plans.
--    DB-9.3  pgTAP suite: RLS isolation, dedupe, confidence gate, cap math.
--    DB-9.4  pg_cron: nightly backup, 30d email purge, confidence recompute,
--            divergence detection, monthly report materialization.
--
--  MIGRATION FILE SPLIT (supabase/migrations/) — apply in this order:
--    0001_extensions_and_enums.sql        <- DB-1.1
--    0002_reference_data.sql              <- DB-1.2..1.4
--    0003_card_catalogue.sql              <- DB-2
--    0004_user_domain.sql                 <- DB-3
--    0005_sync.sql                        <- DB-4
--    0006_ingest.sql                      <- DB-5
--    0007_crowdsource.sql                 <- DB-6
--    0008_admin_console.sql               <- DB-7
--    0009_platform_ops.sql                <- DB-8
--    0010_functions_and_views.sql         <- §10
--    0011_rls_policies.sql                <- §11
--    0012_indexes.sql                     <- §12
--    0013_cron_jobs.sql                   <- DB-9.4
--    0014_seed_reference.sql              <- §13 (idempotent)
--
--  This file is the consolidated, authoritative schema. Split it along the
--  boundaries marked by `-- >>> MIGRATION 000N` when creating migration files.
--
--  ROLLBACK POLICY: every migration ships with a tested `-- DOWN` section in
--  its own file. Migrations are additive-only in production (add column, backfill,
--  switch reads, drop later in a separate release) — never a destructive change
--  in a single deploy while devices on older versions are still syncing.
-- =============================================================================


-- >>> MIGRATION 0001 — EXTENSIONS AND ENUMS ===================================

create extension if not exists "pgcrypto";   -- gen_random_uuid, digest
create extension if not exists "citext";     -- case-insensitive email/vpa
create extension if not exists "pg_trgm";    -- merchant fuzzy search
create extension if not exists "pg_cron";    -- scheduled jobs (self-hosted)

create schema if not exists pandapay;        -- helper functions live here
comment on schema pandapay is 'Internal helper functions; not exposed via PostgREST.';

-- ---- Card / catalogue enums -------------------------------------------------
create type card_network       as enum ('rupay','visa','mastercard','amex','diners');
create type card_type          as enum ('credit','debit','prepaid','forex');
create type publish_status     as enum ('draft','in_review','published','archived');
create type reward_unit        as enum (
  'cashback_percent',      -- x% of spend returned as cash
  'points_per_100',        -- n points per ₹100 spent
  'points_per_150',        -- n points per ₹150 spent (common: HDFC)
  'points_per_200',
  'miles_per_100',
  'flat_points',           -- fixed points per qualifying txn
  'discount_percent'       -- instant discount, not accrual
);
create type cap_period         as enum ('statement_cycle','calendar_month','quarter','half_year','annual','lifetime');
create type cap_measure        as enum ('reward_value','spend_amount','txn_count');
create type benefit_kind       as enum (
  'lounge_domestic','lounge_international','golf','concierge','insurance_travel',
  'insurance_purchase','extended_warranty','dining_program','movie','fuel_surcharge',
  'roadside_assistance','other'
);

-- ---- Transaction / tracking enums ------------------------------------------
create type txn_source         as enum ('manual','sms','email','statement','sms_bulk','imported');
create type txn_confidence     as enum ('estimated','confirmed');  -- product-plan §5.10 (R3)
create type txn_status         as enum ('active','ignored','reversed','deleted');
create type txn_rail           as enum ('upi_qr','swipe','online','contactless','atm','emi','unknown');
create type review_state       as enum ('pending','resolved','dismissed');

-- ---- Crowdsource enums ------------------------------------------------------
create type contribution_kind  as enum ('vpa_merchant','merchant_location','category_correction','acceptance','effective_rate');
create type acceptance_result  as enum ('accepted','declined','not_supported','unknown');
create type record_confidence  as enum ('unverified','low','medium','high','operator_verified');

-- ---- Admin / policy-change enums -------------------------------------------
create type source_kind        as enum ('bank_official','news_review','regulator','other');
create type scrape_status      as enum ('queued','running','success','failed','skipped_robots','skipped_unchanged');
create type alert_signal       as enum ('scrape_diff','empirical_divergence','email_keyword','user_report','manual');
create type alert_state        as enum ('open','needs_more_evidence','approved','rejected','superseded');

-- ---- Sync / platform enums --------------------------------------------------
create type sync_op            as enum ('insert','update','delete');
create type conflict_strategy  as enum ('last_write_wins','server_wins','client_wins','manual');


-- >>> MIGRATION 0002 — REFERENCE DATA =========================================

-- Shared trigger: maintain updated_at.
create or replace function pandapay.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create table issuers (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  short_name        text,
  logo_url          text,
  website_url       text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger trg_issuers_touch before update on issuers
  for each row execute function pandapay.touch_updated_at();

-- G4 Emergency Card Info: must work offline + logged out, so it ships to device.
create table issuer_emergency_contacts (
  id                uuid primary key default gen_random_uuid(),
  issuer_id         uuid not null references issuers(id) on delete cascade,
  label             text not null,                   -- 'Lost card (India)'
  phone             text not null,
  is_international  boolean not null default false,
  is_collect_call   boolean not null default false,
  block_procedure   text,                            -- SMS/IVR steps
  sort_order        int not null default 0,
  updated_at        timestamptz not null default now()
);

-- Internal spend taxonomy. The engine ranks on THIS, not on raw MCC.
create table spend_categories (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,            -- 'groceries','fuel','dining'
  name              text not null,
  icon              text,
  is_primary_chip   boolean not null default false,  -- shown on B1 chip row
  sort_order        int not null default 0
);

-- MCC -> category. Seeded from the ISO 18245 list; QR `mc` maps through here.
create table mcc_categories (
  mcc               char(4) primary key,
  description       text not null,
  category_id       uuid references spend_categories(id),
  is_p2p_indicator  boolean not null default false   -- helps B3 P2P detection
);


-- >>> MIGRATION 0003 — CARD CATALOGUE =========================================
-- Single source of truth. Console writes, app reads. (admin-console-plan §4.5)

create table card_products (
  id                    uuid primary key default gen_random_uuid(),
  issuer_id             uuid not null references issuers(id) on delete restrict,
  slug                  text not null unique,
  name                  text not null,
  network               card_network not null,
  card_type             card_type not null default 'credit',
  -- R1: NO card number column exists here, or anywhere. By design.
  joining_fee_inr       numeric(10,2) not null default 0,
  annual_fee_inr        numeric(10,2) not null default 0,
  fee_gst_applicable    boolean not null default true,
  is_upi_linkable       boolean not null default false,   -- RuPay credit only (§4.1)
  art_asset             text,                              -- bundled asset key
  art_primary_color     text,
  base_reward_unit      reward_unit,
  base_reward_rate      numeric(8,4),                      -- fallback / "all other spends"
  point_value_inr       numeric(8,4),                      -- ₹ per point, our valuation
  point_value_basis     text,                              -- 'transfer to partner @1:1'
  positioning_notes     text,

  status                publish_status not null default 'draft',
  data_version          bigint not null default 1,         -- §4.5 device sync key
  verified_at           timestamptz,                       -- §5.11 freshness date
  verified_by           uuid,                              -- admin_users.id
  source_url            text,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint card_published_needs_verification
    check (status <> 'published' or verified_at is not null)
);
create trigger trg_card_products_touch before update on card_products
  for each row execute function pandapay.touch_updated_at();

-- Any change to a child rule must move the parent's data_version, otherwise
-- devices keep serving stale advice. DB-2.6.
create or replace function pandapay.bump_card_data_version() returns trigger
language plpgsql as $$
declare target uuid;
begin
  target := coalesce(new.card_product_id, old.card_product_id);
  update card_products
     set data_version = data_version + 1,
         updated_at   = now()
   where id = target;
  return coalesce(new, old);
end $$;

create table reward_rules (
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  category_id         uuid references spend_categories(id),      -- null = all spends
  merchant_pattern    text,                                       -- 'amazon','swiggy'
  rail                txn_rail,                                   -- rail-specific rates (§10.7)
  unit                reward_unit not null,
  rate                numeric(8,4) not null,
  min_txn_inr         numeric(10,2),
  max_txn_inr         numeric(10,2),
  priority            int not null default 100,                   -- lower wins
  conditions          jsonb not null default '{}'::jsonb,         -- structured extras
  notes               text,
  effective_from      date,
  effective_to        date,
  created_at          timestamptz not null default now()
);
create trigger trg_reward_rules_version
  after insert or update or delete on reward_rules
  for each row execute function pandapay.bump_card_data_version();

-- §10.1 THE killer feature. Also covers §10.10 fuel-surcharge caps.
create table cap_rules (
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  reward_rule_id      uuid references reward_rules(id) on delete cascade,
  category_id         uuid references spend_categories(id),
  benefit_kind        benefit_kind,
  label               text not null,                    -- '5% groceries cap'
  measure             cap_measure not null,
  period              cap_period not null,
  cap_value           numeric(12,2) not null,
  post_cap_unit       reward_unit,
  post_cap_rate       numeric(8,4) not null default 0,  -- what you earn after the cap
  resets_on_day       int check (resets_on_day between 1 and 31),
  created_at          timestamptz not null default now()
);
create trigger trg_cap_rules_version
  after insert or update or delete on cap_rules
  for each row execute function pandapay.bump_card_data_version();

create table milestone_rules (            -- §10.4
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  label               text not null,
  period              cap_period not null default 'annual',
  threshold_spend_inr numeric(12,2) not null,
  reward_description  text not null,
  reward_value_inr    numeric(12,2) not null,
  is_repeatable       boolean not null default false,
  max_repeats         int,
  anchor              text not null default 'card_anniversary'
                      check (anchor in ('card_anniversary','calendar_year','fiscal_year','statement_cycle')),
  created_at          timestamptz not null default now()
);
create trigger trg_milestone_rules_version
  after insert or update or delete on milestone_rules
  for each row execute function pandapay.bump_card_data_version();

create table fee_waiver_rules (           -- §10.5
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  threshold_spend_inr numeric(12,2) not null,
  period              cap_period not null default 'annual',
  waives_fee_inr      numeric(10,2) not null,
  excluded_categories uuid[] default '{}',   -- rent/fuel/wallet commonly excluded
  notes               text,
  created_at          timestamptz not null default now()
);
create trigger trg_fee_waiver_rules_version
  after insert or update or delete on fee_waiver_rules
  for each row execute function pandapay.bump_card_data_version();

create table card_benefits (              -- §10.11, §10.14 — feeds C5 cheat sheet
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  kind                benefit_kind not null,
  label               text not null,
  description         text,
  quota_count         int,                            -- lounge visits etc.
  quota_period        cap_period,
  network_program     text,                           -- 'Priority Pass','DreamFolks'
  value_estimate_inr  numeric(10,2),
  conditions          jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);
create trigger trg_card_benefits_version
  after insert or update or delete on card_benefits
  for each row execute function pandapay.bump_card_data_version();

create table forex_rules (                -- §10.9
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade unique,
  markup_percent      numeric(6,4) not null,
  gst_on_markup       boolean not null default true,
  waiver_notes        text,
  created_at          timestamptz not null default now()
);
create trigger trg_forex_rules_version
  after insert or update or delete on forex_rules
  for each row execute function pandapay.bump_card_data_version();

create table fuel_surcharge_rules (       -- §10.10
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade unique,
  surcharge_percent   numeric(6,4) not null default 1.0,
  waiver_percent      numeric(6,4) not null default 1.0,
  min_txn_inr         numeric(10,2),
  max_txn_inr         numeric(10,2),
  monthly_waiver_cap  numeric(10,2),
  created_at          timestamptz not null default now()
);
create trigger trg_fuel_rules_version
  after insert or update or delete on fuel_surcharge_rules
  for each row execute function pandapay.bump_card_data_version();

create table billing_cycle_rules (        -- §10.6 float optimizer defaults
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade unique,
  grace_period_days   int not null default 20,
  cycle_notes         text
);

create table redemption_options (         -- C6 value estimates; future §22.3
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid references card_products(id) on delete cascade,
  program_name        text not null,
  method              text not null,      -- 'statement_credit','airmiles_transfer'
  value_per_point_inr numeric(8,4) not null,
  min_points          int,
  last_checked_at     timestamptz,
  notes               text
);

-- Human-readable record of what changed, when, and why. Powers H10 What's New
-- and lets a user understand why advice moved. (ui-spec H10)
create table card_catalogue_changes (
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  data_version_after  bigint not null,
  field_path          text not null,           -- 'cap_rules.5pct_groceries.cap_value'
  old_value           jsonb,
  new_value           jsonb,
  change_summary      text not null,           -- shown to users, plain language
  is_user_visible     boolean not null default true,
  approved_by         uuid,
  policy_alert_id     uuid,                    -- FK added after 0008
  created_at          timestamptz not null default now()
);


-- >>> MIGRATION 0004 — USER DOMAIN ============================================
-- Every table here is RLS-protected. Local-only users never appear at all.

create table profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  email               citext,
  display_name        text,
  locale              text not null default 'en-IN',
  currency            text not null default 'INR',
  number_format       text not null default 'lakh_crore',
  travel_mode_active  boolean not null default false,
  contributions_opt_in boolean not null default false,   -- §6.2, default OFF
  onboarding_completed_at timestamptz,
  deletion_requested_at timestamptz,                     -- DPDP erasure (§8.2)
  deletion_due_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger trg_profiles_touch before update on profiles
  for each row execute function pandapay.touch_updated_at();

-- DPDP §8.2: purpose-specific, unbundled, timestamped, versioned, auditable.
create table user_consents (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  purpose             text not null,        -- 'terms','crowdsource','marketing'
  policy_version      text not null,
  granted             boolean not null,
  granted_at          timestamptz not null default now(),
  revoked_at          timestamptz,
  source_screen       text,                 -- 'A4','H4'
  ip_country          text                  -- country only; never full IP
);

create table user_devices (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  device_label        text,
  platform            text not null check (platform in ('android','ios','web')),
  app_version         text,
  os_version          text,
  push_token          text,
  last_seen_at        timestamptz,
  catalogue_version_seen bigint not null default 0,   -- max data_version pulled
  created_at          timestamptz not null default now()
);

create table user_cards (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  card_product_id     uuid not null references card_products(id) on delete restrict,
  nickname            text,
  -- R1 reminder: last-4 is NOT stored either. Nickname disambiguates duplicates.
  credit_limit_inr    numeric(12,2),                 -- optional; gates E3
  statement_day       int check (statement_day between 1 and 31),
  due_day             int check (due_day between 1 and 31),
  opened_on           date,
  anniversary_on      date,
  points_balance      numeric(12,2) not null default 0,
  points_balance_state txn_confidence not null default 'estimated',
  sort_order          int not null default 0,
  is_default          boolean not null default false,
  is_archived         boolean not null default false,  -- R4: archive, never delete
  archived_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger trg_user_cards_touch before update on user_cards
  for each row execute function pandapay.touch_updated_at();

-- §4.6 / B8 — user intent beats the algorithm.
create table card_overrides (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  scope               text not null check (scope in ('vpa','merchant_name','category')),
  vpa                 citext,
  merchant_name       text,
  category_id         uuid references spend_categories(id),
  reason_note         text,
  is_enabled          boolean not null default true,
  created_at          timestamptz not null default now(),
  constraint override_scope_populated check (
    (scope='vpa'            and vpa is not null) or
    (scope='merchant_name'  and merchant_name is not null) or
    (scope='category'       and category_id is not null)
  )
);

create table transactions (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid references user_cards(id) on delete set null,
  amount_inr          numeric(12,2) not null check (amount_inr > 0),
  occurred_at         timestamptz not null,
  merchant_name       text,
  merchant_vpa        citext,
  mcc                 char(4),
  category_id         uuid references spend_categories(id),
  rail                txn_rail not null default 'unknown',
  source              txn_source not null,
  status              txn_status not null default 'active',

  -- R3 estimated/confirmed
  reward_state        txn_confidence not null default 'estimated',
  expected_points     numeric(12,4),
  expected_value_inr  numeric(12,2),
  confirmed_points    numeric(12,4),
  confirmed_value_inr numeric(12,2),
  reconciled_at       timestamptz,
  statement_import_id uuid,

  -- §12.2 missed-opportunity computation inputs
  recommended_card_id uuid references user_cards(id) on delete set null,
  optimal_value_inr   numeric(12,2),
  followed_recommendation boolean,

  -- §5.8 dedupe: stable hash over (amount, merchant, date, card)
  dedupe_hash         text,
  is_split_parent     boolean not null default false,
  parent_txn_id       uuid references transactions(id) on delete cascade,
  raw_source_ref      uuid,                 -- inbound_emails / needs_review item
  note                text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger trg_transactions_touch before update on transactions
  for each row execute function pandapay.touch_updated_at();

create table transaction_splits (
  id                  uuid primary key default gen_random_uuid(),
  transaction_id      uuid not null references transactions(id) on delete cascade,
  user_card_id        uuid references user_cards(id) on delete set null,
  category_id         uuid references spend_categories(id),
  amount_inr          numeric(12,2) not null check (amount_inr > 0),
  note                text
);

create table points_ledger (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  transaction_id      uuid references transactions(id) on delete set null,
  delta_points        numeric(12,4) not null,
  reason              text not null,        -- 'earn','redeem','expiry','adjustment'
  state               txn_confidence not null default 'estimated',
  expires_on          date,                 -- §10.12 point expiry
  occurred_at         timestamptz not null default now()
);

-- Derived state, recomputed on transaction write and on catalogue version bump.
create table cap_states (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  cap_rule_id         uuid not null references cap_rules(id) on delete cascade,
  period_start        date not null,
  period_end          date not null,
  consumed            numeric(12,2) not null default 0,
  cap_value_snapshot  numeric(12,2) not null,     -- value at period start
  state               txn_confidence not null default 'estimated',
  updated_at          timestamptz not null default now(),
  unique (user_card_id, cap_rule_id, period_start)
);

create table milestone_states (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  milestone_rule_id   uuid not null references milestone_rules(id) on delete cascade,
  period_start        date not null,
  period_end          date not null,
  qualified_spend     numeric(12,2) not null default 0,
  achieved_at         timestamptz,
  updated_at          timestamptz not null default now(),
  unique (user_card_id, milestone_rule_id, period_start)
);

create table fee_waiver_states (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  fee_waiver_rule_id  uuid not null references fee_waiver_rules(id) on delete cascade,
  period_start        date not null,
  period_end          date not null,       -- the deadline shown in E5
  qualified_spend     numeric(12,2) not null default 0,
  waived_at           timestamptz,
  updated_at          timestamptz not null default now(),
  unique (user_card_id, fee_waiver_rule_id, period_start)
);

create table lounge_usage (               -- E6; banks rarely message this
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  benefit_id          uuid not null references card_benefits(id) on delete cascade,
  used_on             date not null,
  airport             text,
  logged_manually     boolean not null default true,
  created_at          timestamptz not null default now()
);

-- D4: never drop data silently (§5.7).
create table needs_review_items (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  source              txn_source not null,
  raw_text            text not null,          -- shown verbatim to the user
  sender              text,
  received_at         timestamptz not null default now(),
  parse_error         text,
  parser_pattern_id   uuid,
  suggested_amount    numeric(12,2),
  suggested_merchant  text,
  suggested_card_id   uuid references user_cards(id) on delete set null,
  state               review_state not null default 'pending',
  resolved_txn_id     uuid references transactions(id) on delete set null,
  resolved_at         timestamptz
);

-- D5: dedupe across SMS + email + statement (§5.8).
create table duplicate_candidates (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  txn_a_id            uuid not null references transactions(id) on delete cascade,
  txn_b_id            uuid not null references transactions(id) on delete cascade,
  match_score         numeric(4,3) not null,
  match_reason        text not null,
  state               review_state not null default 'pending',
  resolution          text check (resolution in ('merged','kept_both','deleted_one')),
  resolved_at         timestamptz,
  detected_at         timestamptz not null default now(),
  constraint dup_pair_ordered check (txn_a_id < txn_b_id),
  unique (txn_a_id, txn_b_id)
);

-- E9 §12.1 — materialized monthly so the report opens instantly.
create table monthly_reports (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  period_month        date not null,             -- first day of month
  total_spend_inr     numeric(12,2) not null default 0,
  rewards_earned_inr  numeric(12,2) not null default 0,
  baseline_single_card_inr numeric(12,2) not null default 0,
  extra_earned_inr    numeric(12,2) not null default 0,
  value_missed_inr    numeric(12,2) not null default 0,
  breakdown           jsonb not null default '{}'::jsonb,
  generated_at        timestamptz not null default now(),
  unique (profile_id, period_month)
);


-- >>> MIGRATION 0005 — SYNC + CONFLICT ========================================
-- §7.3: silent data loss during sync is the fastest way to lose a finance user.

create table change_log (               -- append-only; never updated
  id                  bigserial primary key,
  profile_id          uuid not null references profiles(id) on delete cascade,
  device_id           uuid references user_devices(id) on delete set null,
  entity              text not null,        -- 'transactions','user_cards',...
  entity_id           uuid not null,
  op                  sync_op not null,
  payload             jsonb not null,       -- full row after change
  field_clocks        jsonb not null default '{}'::jsonb,  -- per-field LWW stamps
  client_seq          bigint not null,
  server_seq          bigint generated always as identity,
  created_at          timestamptz not null default now()
);

create table sync_cursors (
  device_id           uuid primary key references user_devices(id) on delete cascade,
  profile_id          uuid not null references profiles(id) on delete cascade,
  last_server_seq     bigint not null default 0,
  last_pushed_at      timestamptz,
  last_pulled_at      timestamptz
);

-- Every automatic resolution leaves a row. F5 renders this as the conflict log.
create table sync_conflicts (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  entity              text not null,
  entity_id           uuid not null,
  field               text not null,
  local_value         jsonb,
  server_value        jsonb,
  chosen_value        jsonb,
  strategy            conflict_strategy not null,
  device_id           uuid references user_devices(id) on delete set null,
  user_acknowledged   boolean not null default false,
  created_at          timestamptz not null default now()
);


-- >>> MIGRATION 0006 — INGEST PIPELINE ========================================

-- §5.2 the guaranteed tracking path. One address per user, revocable.
create table forwarding_addresses (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  local_part          citext not null unique,   -- e.g. u7f3k9@in.pandapay.app
  is_active           boolean not null default true,
  verified_at         timestamptz,
  first_email_at      timestamptz,
  email_count         int not null default 0,
  rotated_from        uuid references forwarding_addresses(id),
  created_at          timestamptz not null default now()
);

-- Raw retained only as long as needed to fix parsers; purged by cron (DB-9.4).
create table inbound_emails (
  id                  uuid primary key default gen_random_uuid(),
  forwarding_address_id uuid not null references forwarding_addresses(id) on delete cascade,
  profile_id          uuid not null references profiles(id) on delete cascade,
  sender              text not null,
  subject             text,
  body_text           text,
  received_at         timestamptz not null default now(),
  is_known_bank_sender boolean not null default false,
  parsed_ok           boolean,
  parser_pattern_id   uuid,
  produced_txn_id     uuid references transactions(id) on delete set null,
  -- admin-console-plan §4.2 B2: keyword scan for policy-change announcements
  policy_keyword_hit  boolean not null default false,
  purge_after         timestamptz not null default (now() + interval '30 days')
);

create table statement_imports (        -- §5.4 the accuracy anchor
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  user_card_id        uuid not null references user_cards(id) on delete cascade,
  -- NOTE: the PDF itself and its password NEVER reach this table. Parsing is
  -- 100% on-device; only the extracted, structured result is synced. (§5.4)
  statement_from      date not null,
  statement_to        date not null,
  closing_balance_inr numeric(12,2),
  points_posted       numeric(12,2),
  txn_count           int not null default 0,
  reconciled_count    int not null default 0,
  issuer_format_id    text,
  imported_at         timestamptz not null default now()
);

create table sms_import_batches (       -- §5.5 onboarding backfill
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  message_count       int not null default 0,
  parsed_count        int not null default 0,
  failed_count        int not null default 0,
  imported_at         timestamptz not null default now()
);

-- Parser definitions are catalogue data: shipped to devices, fixed centrally.
create table parser_patterns (
  id                  uuid primary key default gen_random_uuid(),
  issuer_id           uuid references issuers(id) on delete set null,
  channel             txn_source not null,
  sender_pattern      text,                    -- 'VM-HDFCBK','alerts@axisbank'
  regex               text not null,
  field_map           jsonb not null,          -- {amount:1, merchant:2, ...}
  version             int not null default 1,
  is_active           boolean not null default true,
  sample_text         text,
  success_count       bigint not null default 0,
  failure_count       bigint not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Anonymous parser telemetry: pattern that failed + redacted shape, no content.
create table parser_failures (
  id                  uuid primary key default gen_random_uuid(),
  channel             txn_source not null,
  issuer_id           uuid references issuers(id) on delete set null,
  sender_pattern      text,
  redacted_shape      text not null,   -- digits->#, names->X. NEVER raw content.
  app_version         text,
  occurrences         int not null default 1,
  first_seen_at       timestamptz not null default now(),
  last_seen_at        timestamptz not null default now(),
  fixed_in_pattern_id uuid references parser_patterns(id) on delete set null,
  constraint redacted_shape_has_no_digits check (redacted_shape !~ '[0-9]')
);


-- >>> MIGRATION 0007 — CROWDSOURCE DATASETS ===================================
-- R2 IS ABSOLUTE HERE. No profile_id column exists in ANY table in this section.
-- Devices are identified by a salted, rotating hash used only for rate limiting.

create table merchants (
  id                  uuid primary key default gen_random_uuid(),
  vpa                 citext not null unique,     -- globally unique merchant key
  display_name        text,
  mcc                 char(4),
  category_id         uuid references spend_categories(id),
  confidence          record_confidence not null default 'unverified',
  confidence_score    numeric(4,3) not null default 0,
  confirmation_count  int not null default 0,
  distinct_device_count int not null default 0,
  is_p2p              boolean not null default false,
  is_published        boolean not null default false,   -- gate: N >= 2..3 (§6.3)
  operator_locked     boolean not null default false,   -- console manual override
  first_seen_on       date not null default current_date,  -- DATE not timestamp (R2)
  last_confirmed_on   date not null default current_date,
  updated_at          timestamptz not null default now()
);

-- Grid-snapped to ~50m. Raw coordinates are never accepted or stored. (§6.2)
create table merchant_locations (
  id                  uuid primary key default gen_random_uuid(),
  merchant_id         uuid not null references merchants(id) on delete cascade,
  grid_lat            numeric(8,4) not null,   -- 4dp ~= 11m grid cell centre
  grid_lng            numeric(8,4) not null,
  geohash6            text not null,           -- ~1.2km bucket for map queries
  confirmation_count  int not null default 1,
  osm_matched         boolean not null default false,
  osm_ref             text,
  first_seen_on       date not null default current_date,
  last_confirmed_on   date not null default current_date,
  unique (merchant_id, grid_lat, grid_lng),
  -- Structural proof of grid snapping: reject anything finer than 4dp.
  constraint coords_are_grid_snapped check (
    grid_lat = round(grid_lat, 4) and grid_lng = round(grid_lng, 4)
  ),
  constraint coords_in_india_bbox check (
    grid_lat between 6.0 and 37.5 and grid_lng between 68.0 and 97.5
  )
);

-- Raw contributions. Deliberately has NO user FK, NO amount, NO exact time.
create table merchant_contributions (
  id                  uuid primary key default gen_random_uuid(),
  kind                contribution_kind not null,
  vpa                 citext,
  merchant_id         uuid references merchants(id) on delete cascade,
  reported_name       text,
  reported_mcc        char(4),
  reported_category_id uuid references spend_categories(id),
  grid_lat            numeric(8,4),
  grid_lng            numeric(8,4),
  device_hash         text not null,        -- salted rotating hash, not identity
  app_version         text,
  submitted_on        date not null default current_date,   -- DAY precision only
  is_counted          boolean not null default true,
  rejected_reason     text,
  constraint contribution_carries_no_amount check (true)     -- no column exists
);

create table acceptance_reports (         -- §6.1 dataset nobody else has
  id                  uuid primary key default gen_random_uuid(),
  merchant_id         uuid not null references merchants(id) on delete cascade,
  network             card_network not null,
  rail                txn_rail not null,
  result              acceptance_result not null,
  device_hash         text not null,
  submitted_on        date not null default current_date
);

create table acceptance_summary (
  merchant_id         uuid not null references merchants(id) on delete cascade,
  network             card_network not null,
  rail                txn_rail not null,
  accepted_count      int not null default 0,
  declined_count      int not null default 0,
  confidence_score    numeric(4,3) not null default 0,
  is_published        boolean not null default false,
  last_updated_on     date not null default current_date,
  primary key (merchant_id, network, rail)
);

-- Source B1 (admin-console-plan §4.2): empirical divergence detection.
-- Samples are aggregated from statement-reconciled transactions and stripped of
-- identity before insert. `device_hash` exists ONLY to enforce N>=3 distinct.
create table effective_rate_samples (
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  category_id         uuid references spend_categories(id),
  period_month        date not null,
  spend_bucket_inr    numeric(12,2) not null,   -- bucketed, not exact
  observed_reward_inr numeric(12,2) not null,
  observed_rate       numeric(8,4) not null,
  device_hash         text not null,
  submitted_on        date not null default current_date
);

create table effective_rate_summary (
  card_product_id     uuid not null references card_products(id) on delete cascade,
  category_id         uuid references spend_categories(id),
  period_month        date not null,
  sample_count        int not null default 0,
  distinct_devices    int not null default 0,
  observed_rate_mean  numeric(8,4),
  observed_rate_p50   numeric(8,4),
  published_rate      numeric(8,4),
  divergence_pct      numeric(8,4),
  observed_cap_ceiling numeric(12,2),      -- the ₹3000 -> ₹2000 detector
  published_cap_value numeric(12,2),
  is_divergent        boolean not null default false,
  alert_raised_at     timestamptz,
  primary key (card_product_id, category_id, period_month)
);

-- §6.3 abuse resistance: a poisoned merchant DB gives wrong financial advice.
create table contribution_quotas (
  device_hash         text not null,
  quota_date          date not null default current_date,
  submission_count    int not null default 0,
  rejected_count      int not null default 0,
  primary key (device_hash, quota_date)
);

create table abuse_signals (
  id                  uuid primary key default gen_random_uuid(),
  device_hash         text not null,
  signal              text not null,     -- 'burst','impossible_geography','conflict_rate'
  detail              jsonb not null default '{}'::jsonb,
  severity            int not null default 1,
  is_blocked          boolean not null default false,
  detected_at         timestamptz not null default now()
);


-- >>> MIGRATION 0008 — ADMIN CONSOLE + POLICY CHANGE DETECTION ================
-- Internal only. No public signup path exists to any of these tables.

create table admin_users (
  id                  uuid primary key references auth.users(id) on delete cascade,
  email               citext not null unique,
  role                text not null default 'operator'
                      check (role in ('owner','operator','reviewer','readonly')),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);

create table admin_audit_log (
  id                  bigserial primary key,
  admin_id            uuid references admin_users(id) on delete set null,
  action              text not null,
  entity              text not null,
  entity_id           uuid,
  before_value        jsonb,
  after_value         jsonb,
  reason              text,
  created_at          timestamptz not null default now()
);

create table sources (                    -- §5.1 two source types
  id                  uuid primary key default gen_random_uuid(),
  kind                source_kind not null,
  issuer_id           uuid references issuers(id) on delete set null,
  name                text not null,
  base_url            text not null,
  robots_allows       boolean,
  robots_checked_at   timestamptz,
  tos_reviewed        boolean not null default false,
  tos_note            text,
  crawl_frequency     interval not null default interval '7 days',
  is_enabled          boolean not null default false,   -- off until ToS reviewed
  created_at          timestamptz not null default now(),
  constraint enabled_requires_tos_review check (is_enabled = false or tos_reviewed = true)
);

create table source_pages (
  id                  uuid primary key default gen_random_uuid(),
  source_id           uuid not null references sources(id) on delete cascade,
  url                 text not null unique,
  page_role           text not null,   -- 'reward_tnc','fees','offers','news_index'
  card_product_id     uuid references card_products(id) on delete set null,
  selector_hint       text,            -- CSS selector for the content region
  last_crawled_at     timestamptz,
  last_changed_at     timestamptz,
  consecutive_failures int not null default 0,
  is_enabled          boolean not null default true
);

create table scrape_runs (
  id                  uuid primary key default gen_random_uuid(),
  source_id           uuid not null references sources(id) on delete cascade,
  triggered_by        text not null default 'schedule'
                      check (triggered_by in ('schedule','manual','retry')),
  status              scrape_status not null default 'queued',
  pages_fetched       int not null default 0,
  pages_changed       int not null default 0,
  started_at          timestamptz,
  finished_at         timestamptz,
  duration_ms         int,
  error_text          text
);

create table page_snapshots (
  id                  uuid primary key default gen_random_uuid(),
  source_page_id      uuid not null references source_pages(id) on delete cascade,
  scrape_run_id       uuid references scrape_runs(id) on delete set null,
  content_hash        text not null,
  extracted_text      text not null,
  http_status         int,
  captured_at         timestamptz not null default now(),
  unique (source_page_id, content_hash)
);

-- AI first pass. NEVER live. Always requires human approval. (R5)
create table extraction_proposals (
  id                  uuid primary key default gen_random_uuid(),
  snapshot_id         uuid references page_snapshots(id) on delete cascade,
  card_product_id     uuid references card_products(id) on delete cascade,
  model_name          text,
  proposed_fields     jsonb not null,      -- {cap_value: 2000, rate: 5.0, ...}
  model_confidence    numeric(4,3),
  evidence_excerpt    text,
  created_at          timestamptz not null default now()
);

-- ⭐ §4.4 THE UNIFIED POLICY CHANGE ALERT QUEUE.
-- One row per (card, field). Multiple signals corroborate the SAME row —
-- that agreement is the trust signal, so they must not fan out into 3 queues.
create table policy_change_alerts (
  id                  uuid primary key default gen_random_uuid(),
  card_product_id     uuid not null references card_products(id) on delete cascade,
  field_path          text not null,        -- 'cap_rules.groceries_5pct.cap_value'
  field_label         text not null,        -- 'Kiwi RuPay — cashback cap'
  current_value       jsonb,
  proposed_value      jsonb,
  signal_count        int not null default 0,
  distinct_signal_kinds int not null default 0,
  corroboration_score numeric(4,3) not null default 0,   -- drives queue ordering
  state               alert_state not null default 'open',
  decided_by          uuid references admin_users(id) on delete set null,
  decided_at          timestamptz,
  decision_note       text,
  published_change_id uuid references card_catalogue_changes(id) on delete set null,
  force_sync          boolean not null default false,    -- §4.5 urgent push
  first_signal_at     timestamptz not null default now(),
  last_signal_at      timestamptz not null default now(),
  unique (card_product_id, field_path, state) deferrable initially deferred
);

create table policy_alert_evidence (
  id                  uuid primary key default gen_random_uuid(),
  alert_id            uuid not null references policy_change_alerts(id) on delete cascade,
  signal              alert_signal not null,
  -- exactly one of these is populated depending on `signal`
  snapshot_id         uuid references page_snapshots(id) on delete set null,
  extraction_id       uuid references extraction_proposals(id) on delete set null,
  rate_summary_key    jsonb,                -- (card, category, month) for B1
  inbound_email_id    uuid references inbound_emails(id) on delete set null,
  data_error_report_id uuid,                -- FK added below
  excerpt             text not null,        -- verbatim evidence shown to operator
  weight              numeric(4,3) not null default 0.25,
  created_at          timestamptz not null default now()
);

-- Close the FK loop from 0003.
alter table card_catalogue_changes
  add constraint fk_catalogue_change_alert
  foreign key (policy_alert_id) references policy_change_alerts(id) on delete set null;

create table card_requests (              -- A8 / C8 -> §5.5
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid references profiles(id) on delete set null,
  issuer_name         text not null,
  product_name        text not null,
  network_guess       card_network,
  image_path          text,               -- card FACE only; policy-enforced in app
  request_count       int not null default 1,
  state               review_state not null default 'pending',
  fulfilled_card_id   uuid references card_products(id) on delete set null,
  created_at          timestamptz not null default now()
);

create table data_error_reports (         -- C7 -> §5.6, also a §4.4 signal
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid references profiles(id) on delete set null,
  card_product_id     uuid not null references card_products(id) on delete cascade,
  field_path          text not null,
  shown_value         text,
  claimed_value       text,
  source_url          text,
  attachment_path     text,
  state               review_state not null default 'pending',
  alert_id            uuid references policy_change_alerts(id) on delete set null,
  created_at          timestamptz not null default now()
);

alter table policy_alert_evidence
  add constraint fk_evidence_error_report
  foreign key (data_error_report_id) references data_error_reports(id) on delete set null;

-- §6.3 console conflict queue for crowdsourced disagreements.
create table merchant_conflicts (
  id                  uuid primary key default gen_random_uuid(),
  merchant_id         uuid not null references merchants(id) on delete cascade,
  field               text not null,       -- 'category_id','display_name'
  competing_values    jsonb not null,      -- [{value, count, last_seen_on}]
  auto_resolved       boolean not null default false,
  state               review_state not null default 'pending',
  resolved_value      jsonb,
  resolved_by         uuid references admin_users(id) on delete set null,
  resolved_at         timestamptz,
  detected_at         timestamptz not null default now()
);

-- §6.7 non-negotiable: proves the privacy promise in the data, not the docs.
create table anonymization_audit_runs (
  id                  uuid primary key default gen_random_uuid(),
  run_by              text not null default 'ci',
  checks_total        int not null,
  checks_failed       int not null,
  findings            jsonb not null default '[]'::jsonb,
  passed              boolean generated always as (checks_failed = 0) stored,
  git_sha             text,
  ran_at              timestamptz not null default now()
);


-- >>> MIGRATION 0009 — PLATFORM / OPS =========================================

create table feature_flags (              -- §9.2 remote control
  key                 text primary key,
  is_enabled          boolean not null default false,
  rollout_percent     int not null default 0 check (rollout_percent between 0 and 100),
  min_app_version     text,
  platforms           text[] not null default '{android,ios}',
  description         text,
  updated_by          uuid references admin_users(id) on delete set null,
  updated_at          timestamptz not null default now()
);

create table remote_config (
  key                 text primary key,
  value               jsonb not null,
  description         text,
  updated_at          timestamptz not null default now()
);

create table app_versions (               -- S5 forced upgrade
  platform            text not null check (platform in ('android','ios')),
  version             text not null,
  is_minimum_supported boolean not null default false,
  is_latest           boolean not null default false,
  release_notes       text,
  released_at         timestamptz not null default now(),
  primary key (platform, version)
);

create table kill_switches (              -- §9.2 server-side kill switch
  key                 text primary key,   -- 'recommendation_engine','geofence'
  is_killed           boolean not null default false,
  reason              text,
  killed_by           uuid references admin_users(id) on delete set null,
  killed_at           timestamptz
);

create table changelog_entries (          -- H10 What's New
  id                  uuid primary key default gen_random_uuid(),
  app_version         text not null,
  title               text not null,
  body_markdown       text not null,
  highlights_data_change boolean not null default false,
  published_at        timestamptz not null default now()
);

create table support_tickets (            -- H9
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid references profiles(id) on delete set null,
  kind                text not null check (kind in ('bug','wrong_card_data','card_request','general')),
  message             text not null,
  diagnostics         jsonb,              -- shown to user before sending (H9)
  app_version         text,
  state               review_state not null default 'pending',
  response            text,
  created_at          timestamptz not null default now()
);

create table backup_runs (                -- §9.3 / DB-8.2
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('full','wal','logical')),
  status              text not null check (status in ('success','failed')),
  size_bytes          bigint,
  location            text,
  error_text          text,
  ran_at              timestamptz not null default now()
);

create table restore_drills (             -- an untested backup is not a backup
  id                  uuid primary key default gen_random_uuid(),
  backup_run_id       uuid references backup_runs(id) on delete set null,
  restored_ok         boolean not null,
  row_count_delta     jsonb,
  duration_seconds    int,
  notes               text,
  ran_at              timestamptz not null default now()
);


-- >>> MIGRATION 0010 — FUNCTIONS AND VIEWS ====================================

-- Snap a raw coordinate to the ~50m publication grid. Called SERVER-SIDE on
-- ingest as a second line of defence — the client also snaps before upload.
create or replace function pandapay.snap_grid(lat numeric, lng numeric)
returns numeric[] language sql immutable as $$
  select array[round(lat, 4), round(lng, 4)];
$$;

-- §5.8 dedupe key. Date (not timestamp) + rounded amount + normalized merchant.
create or replace function pandapay.dedupe_hash(
  p_card uuid, p_amount numeric, p_merchant text, p_when timestamptz
) returns text language sql immutable as $$
  select encode(digest(
    coalesce(p_card::text,'-') || '|' ||
    to_char(round(p_amount, 0), 'FM9999999999') || '|' ||
    lower(regexp_replace(coalesce(p_merchant,''), '[^a-z0-9]', '', 'gi')) || '|' ||
    to_char(p_when at time zone 'Asia/Kolkata', 'YYYY-MM-DD'),
    'sha256'), 'hex');
$$;

create or replace function pandapay.set_dedupe_hash() returns trigger
language plpgsql as $$
begin
  new.dedupe_hash := pandapay.dedupe_hash(
    new.user_card_id, new.amount_inr, new.merchant_name, new.occurred_at);
  return new;
end $$;

create trigger trg_txn_dedupe before insert or update of
  amount_inr, merchant_name, occurred_at, user_card_id on transactions
  for each row execute function pandapay.set_dedupe_hash();

-- §6.3 publication gate: never publish below N independent agreements.
create or replace function pandapay.recompute_merchant_confidence(p_merchant uuid)
returns void language plpgsql as $$
declare
  v_devices int; v_total int; v_score numeric; v_recent int;
begin
  select count(distinct device_hash), count(*)
    into v_devices, v_total
    from merchant_contributions
   where merchant_id = p_merchant and is_counted;

  select count(distinct device_hash) into v_recent
    from merchant_contributions
   where merchant_id = p_merchant and is_counted
     and submitted_on > current_date - 180;

  -- Weighted toward recency, saturating at 5 distinct devices.
  v_score := least(1.0, (v_devices * 0.6 + v_recent * 0.4) / 5.0);

  update merchants
     set distinct_device_count = v_devices,
         confirmation_count    = v_total,
         confidence_score      = v_score,
         confidence = case
           when operator_locked      then 'operator_verified'
           when v_devices >= 5       then 'high'
           when v_devices >= 3       then 'medium'
           when v_devices >= 2       then 'low'
           else 'unverified' end,
         is_published = (v_devices >= 2) or operator_locked,
         last_confirmed_on = current_date,
         updated_at = now()
   where id = p_merchant;
end $$;

-- Source B1 detector. Raises/updates ONE alert row, adding evidence to it.
-- Requires N >= 3 distinct devices before surfacing (admin-console-plan §4.2).
create or replace function pandapay.detect_rate_divergence(p_threshold numeric default 0.15)
returns int language plpgsql as $$
declare r record; v_alert uuid; v_count int := 0;
begin
  for r in
    select * from effective_rate_summary
     where distinct_devices >= 3
       and published_rate is not null
       and abs(coalesce(divergence_pct, 0)) >= p_threshold
       and alert_raised_at is null
  loop
    insert into policy_change_alerts (
      card_product_id, field_path, field_label, current_value, proposed_value,
      signal_count, distinct_signal_kinds, corroboration_score)
    values (
      r.card_product_id,
      'reward_rules.' || coalesce(r.category_id::text, 'all') || '.rate',
      'Empirical rate divergence',
      to_jsonb(r.published_rate), to_jsonb(r.observed_rate_p50),
      1, 1, 0.35)
    on conflict do nothing
    returning id into v_alert;

    if v_alert is null then
      select id into v_alert from policy_change_alerts
       where card_product_id = r.card_product_id
         and field_path = 'reward_rules.' || coalesce(r.category_id::text,'all') || '.rate'
         and state in ('open','needs_more_evidence')
       limit 1;
      update policy_change_alerts
         set signal_count = signal_count + 1,
             corroboration_score = least(1.0, corroboration_score + 0.2),
             last_signal_at = now()
       where id = v_alert;
    end if;

    insert into policy_alert_evidence (alert_id, signal, rate_summary_key, excerpt, weight)
    values (v_alert, 'empirical_divergence',
            jsonb_build_object('card', r.card_product_id, 'category', r.category_id,
                               'month', r.period_month),
            format('%s devices show %s%% vs published %s%%',
                   r.distinct_devices, r.observed_rate_p50, r.published_rate),
            0.35);

    update effective_rate_summary set alert_raised_at = now(), is_divergent = true
     where card_product_id = r.card_product_id
       and coalesce(category_id, '00000000-0000-0000-0000-000000000000')
           = coalesce(r.category_id, '00000000-0000-0000-0000-000000000000')
       and period_month = r.period_month;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- §4.5 PROPAGATION. The ONLY sanctioned path from "alert" to "live for users".
-- Approve -> write catalogue -> bump data_version -> audit -> optional force-sync.
create or replace function pandapay.approve_policy_alert(
  p_alert uuid, p_admin uuid, p_apply jsonb, p_summary text, p_force_sync boolean default false
) returns uuid language plpgsql security definer as $$
declare v_card uuid; v_version bigint; v_change uuid; a record;
begin
  select * into a from policy_change_alerts where id = p_alert for update;
  if a is null then raise exception 'alert % not found', p_alert; end if;
  if a.state <> 'open' and a.state <> 'needs_more_evidence' then
    raise exception 'alert % already decided (%)', p_alert, a.state;
  end if;

  v_card := a.card_product_id;

  -- Caller supplies the concrete UPDATE payload; applied by the console's
  -- typed writer (see adminimplementation_plan AD-5.4). We bump + audit here
  -- so no code path can publish without leaving a record.
  update card_products
     set data_version = data_version + 1,
         verified_at  = now(),
         verified_by  = p_admin,
         updated_at   = now()
   where id = v_card
  returning data_version into v_version;

  insert into card_catalogue_changes (
    card_product_id, data_version_after, field_path, old_value, new_value,
    change_summary, approved_by, policy_alert_id)
  values (v_card, v_version, a.field_path, a.current_value, a.proposed_value,
          p_summary, p_admin, p_alert)
  returning id into v_change;

  update policy_change_alerts
     set state = 'approved', decided_by = p_admin, decided_at = now(),
         published_change_id = v_change, force_sync = p_force_sync
   where id = p_alert;

  insert into admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
  values (p_admin, 'approve_policy_alert', 'card_products', v_card,
          a.current_value, a.proposed_value, p_summary);

  if p_force_sync then
    insert into remote_config (key, value, description)
    values ('force_catalogue_sync_after',
            to_jsonb(extract(epoch from now())::bigint),
            'Set by urgent policy correction')
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;

  return v_change;
end $$;

-- DEVICE SYNC CONTRACT (DB-2.7). The app pulls rows where
-- data_version > catalogue_version_seen. Changing this view's shape is a
-- breaking change and requires an app-version gate.
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
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

-- Console: §6.6 Data Quality Dashboard, single query.
create or replace view v_data_quality_dashboard as
select
  (select count(*) from merchants)                                    as merchants_total,
  (select count(*) from merchants where is_published)                 as merchants_published,
  (select count(*) from merchants where confidence in ('high','operator_verified')) as merchants_high_conf,
  (select count(*) from merchant_locations)                           as locations_total,
  (select count(*) from policy_change_alerts where state='open')       as alerts_open,
  (select count(*) from data_error_reports where state='pending')      as error_reports_pending,
  (select count(*) from card_requests where state='pending')           as card_requests_pending,
  (select count(*) from merchant_conflicts where state='pending')      as conflicts_pending,
  (select count(*) from scrape_runs where status='failed'
     and started_at > now() - interval '7 days')                       as scrape_failures_7d,
  (select count(*) from card_products where status='published')        as cards_published,
  (select count(*) from card_products where status='published'
     and verified_at < now() - interval '180 days')                    as cards_stale_180d;

-- §6.7 automated anonymization audit. Runs in CI on every deploy (DB-8.3).
create or replace function pandapay.run_anonymization_audit(p_sha text default null)
returns uuid language plpgsql as $$
declare v_findings jsonb := '[]'::jsonb; v_failed int := 0; v_total int := 0; v_id uuid; v_n int;
begin
  -- Check 1: no crowdsource table may have a column referencing profiles.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions',
                        'acceptance_reports','acceptance_summary',
                        'effective_rate_samples','effective_rate_summary')
     and column_name in ('profile_id','user_id','email','device_id');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_identity_columns','violations',v_n);
  end if;

  -- Check 2: no coordinate finer than the 4dp grid.
  v_total := v_total + 1;
  select count(*) into v_n from merchant_locations
   where grid_lat <> round(grid_lat,4) or grid_lng <> round(grid_lng,4);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','grid_snapped_coords','violations',v_n);
  end if;

  -- Check 3: no amount columns in crowdsourced merchant tables.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions','acceptance_reports')
     and (column_name like '%amount%' or column_name like '%_inr');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_amount_columns','violations',v_n);
  end if;

  -- Check 4: contribution timestamps must be DATE precision, never timestamptz.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchant_contributions','acceptance_reports','effective_rate_samples')
     and data_type like 'timestamp%';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','day_precision_only','violations',v_n);
  end if;

  -- Check 5: parser failure telemetry must never contain digits.
  v_total := v_total + 1;
  select count(*) into v_n from parser_failures where redacted_shape ~ '[0-9]';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','redacted_parser_shapes','violations',v_n);
  end if;

  -- Check 6: RLS enabled on every user-domain table.
  v_total := v_total + 1;
  select count(*) into v_n from pg_tables t
   where t.schemaname='public'
     and t.tablename in ('profiles','user_cards','transactions','card_overrides',
                         'points_ledger','cap_states','milestone_states',
                         'fee_waiver_states','needs_review_items','monthly_reports')
     and not exists (select 1 from pg_class c
                      where c.relname=t.tablename and c.relrowsecurity);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','rls_enabled','violations',v_n);
  end if;

  insert into anonymization_audit_runs (run_by, checks_total, checks_failed, findings, git_sha)
  values ('ci', v_total, v_failed, v_findings, p_sha)
  returning id into v_id;
  return v_id;
end $$;

-- DPDP §8.2 right to erasure. Hard-deletes user rows; crowdsourced rows are
-- untouched because they never contained identity in the first place (R2).
create or replace function pandapay.execute_account_deletion(p_profile uuid)
returns void language plpgsql security definer as $$
begin
  delete from change_log         where profile_id = p_profile;
  delete from inbound_emails     where profile_id = p_profile;
  delete from forwarding_addresses where profile_id = p_profile;
  delete from transactions       where profile_id = p_profile;
  delete from user_cards         where profile_id = p_profile;
  delete from profiles           where id = p_profile;
  delete from auth.users         where id = p_profile;
  -- Backups purge on their own retention schedule; the stated window in the
  -- privacy policy MUST be >= that retention. See adminimplementation_plan AD-8.
end $$;


-- >>> MIGRATION 0011 — ROW LEVEL SECURITY =====================================
-- Default deny. A user can only ever read/write their own rows.

create or replace function pandapay.is_admin() returns boolean
language sql stable as $$
  select exists (select 1 from admin_users a where a.id = auth.uid() and a.is_active);
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_consents','user_devices','user_cards','card_overrides',
    'transactions','transaction_splits','points_ledger','cap_states',
    'milestone_states','fee_waiver_states','lounge_usage','needs_review_items',
    'duplicate_candidates','monthly_reports','change_log','sync_cursors',
    'sync_conflicts','forwarding_addresses','inbound_emails','statement_imports',
    'sms_import_batches','support_tickets','card_requests','data_error_reports'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- Owner policies for every table carrying profile_id.
do $$
declare t text;
begin
  foreach t in array array[
    'user_consents','user_devices','user_cards','card_overrides','transactions',
    'points_ledger','cap_states','milestone_states','fee_waiver_states',
    'lounge_usage','needs_review_items','duplicate_candidates','monthly_reports',
    'change_log','sync_cursors','sync_conflicts','forwarding_addresses',
    'inbound_emails','statement_imports','sms_import_batches'
  ] loop
    execute format($f$
      create policy %1$s_owner on %1$I
        for all to authenticated
        using (profile_id = auth.uid())
        with check (profile_id = auth.uid())
    $f$, t);
  end loop;
end $$;

create policy profiles_owner on profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy splits_owner on transaction_splits
  for all to authenticated
  using (exists (select 1 from transactions t
                  where t.id = transaction_id and t.profile_id = auth.uid()))
  with check (exists (select 1 from transactions t
                  where t.id = transaction_id and t.profile_id = auth.uid()));

-- Users may CREATE reports/requests and read their own; the console reads all.
create policy tickets_owner on support_tickets
  for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy card_requests_owner on card_requests
  for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy error_reports_owner on data_error_reports
  for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- Catalogue: world-readable when published (local-only users need it too).
do $$
declare t text;
begin
  foreach t in array array[
    'issuers','issuer_emergency_contacts','spend_categories','mcc_categories',
    'card_products','reward_rules','cap_rules','milestone_rules','fee_waiver_rules',
    'card_benefits','forex_rules','fuel_surcharge_rules','billing_cycle_rules',
    'redemption_options','parser_patterns','feature_flags','remote_config',
    'app_versions','kill_switches','changelog_entries','card_catalogue_changes'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %1$s_public_read on %1$I for select to anon, authenticated using (true)', t);
    execute format('create policy %1$s_admin_write on %1$I for all to authenticated using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;

-- Crowdsource: WRITE-ONLY for users (via SECURITY DEFINER RPC), read for admin.
-- No user may read the merchant graph directly — that is a scraping surface.
do $$
declare t text;
begin
  foreach t in array array[
    'merchants','merchant_locations','merchant_contributions','acceptance_reports',
    'acceptance_summary','effective_rate_samples','effective_rate_summary',
    'contribution_quotas','abuse_signals','merchant_conflicts'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy %1$s_admin_all on %1$I for all to authenticated using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;

-- Published merchant lookup is served through this view only (rate-limited at
-- the edge), never through direct table select.
create or replace view v_published_merchants as
  select m.vpa, m.display_name, m.mcc, m.category_id, m.confidence,
         l.geohash6, l.grid_lat, l.grid_lng
    from merchants m
    left join merchant_locations l on l.merchant_id = m.id
   where m.is_published;

-- Admin-only tables: default deny + admin policy.
do $$
declare t text;
begin
  foreach t in array array[
    'admin_users','admin_audit_log','sources','source_pages','scrape_runs',
    'page_snapshots','extraction_proposals','policy_change_alerts',
    'policy_alert_evidence','anonymization_audit_runs','backup_runs',
    'restore_drills','parser_failures'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy %1$s_admin_only on %1$I for all to authenticated using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;


-- >>> MIGRATION 0012 — INDEXES ================================================
-- Driven by the concrete query list in the two implementation plans.

-- Device catalogue sync: "give me everything newer than my version".
create index idx_card_products_version   on card_products (data_version) where status = 'published';
create index idx_card_products_issuer    on card_products (issuer_id, status);
create index idx_reward_rules_card_cat   on reward_rules (card_product_id, category_id);
create index idx_cap_rules_card          on cap_rules (card_product_id);
create index idx_milestone_rules_card    on milestone_rules (card_product_id);
create index idx_fee_waiver_rules_card   on fee_waiver_rules (card_product_id);
create index idx_benefits_card_kind      on card_benefits (card_product_id, kind);

-- D1 transaction list (reverse chronological, filtered).
create index idx_txn_profile_time        on transactions (profile_id, occurred_at desc);
create index idx_txn_profile_card_time   on transactions (profile_id, user_card_id, occurred_at desc);
create index idx_txn_dedupe              on transactions (profile_id, dedupe_hash);
create index idx_txn_needs_reconcile     on transactions (profile_id, reward_state)
                                         where reward_state = 'estimated';
create index idx_txn_suboptimal          on transactions (profile_id, occurred_at desc)
                                         where followed_recommendation = false;

-- Tracker recomputation.
create index idx_cap_states_lookup       on cap_states (profile_id, period_end desc);
create index idx_milestone_states_lookup on milestone_states (profile_id, period_end desc);
create index idx_fee_waiver_deadline     on fee_waiver_states (profile_id, period_end);
create index idx_points_expiry           on points_ledger (profile_id, expires_on) where expires_on is not null;

-- Queues.
create index idx_needs_review_pending    on needs_review_items (profile_id, state) where state = 'pending';
create index idx_dupes_pending           on duplicate_candidates (profile_id, state) where state = 'pending';

-- Sync.
create index idx_change_log_pull         on change_log (profile_id, server_seq);
create index idx_change_log_entity       on change_log (profile_id, entity, entity_id);

-- Ingest.
create index idx_inbound_purge           on inbound_emails (purge_after);
create index idx_inbound_keyword         on inbound_emails (policy_keyword_hit) where policy_keyword_hit;
create index idx_parser_active           on parser_patterns (channel, is_active);

-- Crowdsource / console map queries.
create index idx_merchants_vpa_trgm      on merchants using gin (vpa gin_trgm_ops);
create index idx_merchants_name_trgm     on merchants using gin (display_name gin_trgm_ops);
create index idx_merchants_published     on merchants (is_published, category_id);
create index idx_locations_geohash       on merchant_locations (geohash6);
create index idx_locations_bbox          on merchant_locations (grid_lat, grid_lng);
create index idx_contrib_merchant        on merchant_contributions (merchant_id, submitted_on desc);
create index idx_contrib_device_day      on merchant_contributions (device_hash, submitted_on);
create index idx_acceptance_merchant     on acceptance_reports (merchant_id, network);

-- Console queues.
create index idx_alerts_open_ranked      on policy_change_alerts (state, corroboration_score desc, last_signal_at desc);
create index idx_evidence_alert          on policy_alert_evidence (alert_id, signal);
create index idx_snapshots_page          on page_snapshots (source_page_id, captured_at desc);
create index idx_scrape_runs_source      on scrape_runs (source_id, started_at desc);
create index idx_error_reports_pending   on data_error_reports (state, created_at desc);


-- >>> MIGRATION 0013 — SCHEDULED JOBS =========================================

select cron.schedule('purge-inbound-emails', '0 3 * * *', $$
  delete from inbound_emails where purge_after < now() and policy_keyword_hit = false;
$$);

select cron.schedule('recompute-merchant-confidence', '30 3 * * *', $$
  select pandapay.recompute_merchant_confidence(id)
    from merchants
   where updated_at > now() - interval '2 days';
$$);

select cron.schedule('detect-rate-divergence', '0 4 * * *', $$
  select pandapay.detect_rate_divergence(0.15);
$$);

select cron.schedule('execute-due-deletions', '0 5 * * *', $$
  select pandapay.execute_account_deletion(id)
    from profiles where deletion_due_at is not null and deletion_due_at < now();
$$);

select cron.schedule('anonymization-audit', '0 6 * * *', $$
  select pandapay.run_anonymization_audit('cron');
$$);


-- >>> MIGRATION 0014 — SEED (idempotent) ======================================

insert into spend_categories (slug, name, is_primary_chip, sort_order) values
  ('groceries','Groceries', true, 10),
  ('fuel','Fuel',           true, 20),
  ('dining','Dining',       true, 30),
  ('online','Online Shopping', true, 40),
  ('travel','Travel',       true, 50),
  ('bills','Bills & Utilities', true, 60),
  ('rent','Rent',           false, 70),
  ('insurance','Insurance', false, 80),
  ('education','Education', false, 90),
  ('government','Government', false, 100),
  ('wallet','Wallet Load',  false, 110),
  ('entertainment','Entertainment', false, 120),
  ('health','Health & Pharmacy', false, 130),
  ('other','Other',         false, 999)
on conflict (slug) do nothing;

insert into mcc_categories (mcc, description, category_id) values
  ('5411','Grocery Stores, Supermarkets', (select id from spend_categories where slug='groceries')),
  ('5541','Service Stations',             (select id from spend_categories where slug='fuel')),
  ('5542','Automated Fuel Dispensers',    (select id from spend_categories where slug='fuel')),
  ('5812','Eating Places, Restaurants',   (select id from spend_categories where slug='dining')),
  ('5814','Fast Food Restaurants',        (select id from spend_categories where slug='dining')),
  ('5999','Miscellaneous Retail',         (select id from spend_categories where slug='other')),
  ('4900','Utilities',                    (select id from spend_categories where slug='bills')),
  ('4511','Airlines',                     (select id from spend_categories where slug='travel')),
  ('7011','Lodging, Hotels',              (select id from spend_categories where slug='travel'))
on conflict (mcc) do nothing;
-- Full ISO 18245 seed is generated by scripts/seed_mcc.sql (DB-1.3).

insert into kill_switches (key, is_killed, reason) values
  ('recommendation_engine', false, null),
  ('geofence_notifications', false, null),
  ('crowdsource_ingest', false, null)
on conflict (key) do nothing;

insert into remote_config (key, value, description) values
  ('min_contribution_confirmations', '2'::jsonb, 'Publish gate N (§6.3)'),
  ('divergence_threshold_pct',       '0.15'::jsonb, 'Source B1 trigger'),
  ('contribution_daily_quota',       '50'::jsonb, 'Per-device rate limit'),
  ('notification_daily_cap',         '3'::jsonb, 'H3 frequency cap'),
  ('geofence_dwell_seconds',         '45'::jsonb, 'Debounce before notifying')
on conflict (key) do nothing;


-- =============================================================================
--  APPENDIX A — ON-DEVICE SQLite SCHEMA (Flutter / drift)
-- =============================================================================
--  The device is the source of truth for the user's own data (product-plan §4.3).
--  This mirrors the Postgres user-domain tables with these deliberate deltas:
--    * ids are TEXT uuids; timestamps are INTEGER epoch millis
--    * every row carries `dirty` + `client_seq` for the sync push (DB-4)
--    * catalogue tables are read-only replicas keyed by `data_version`
--    * NO crowdsource tables — contributions are fire-and-forget outbound
--  Not executed by Postgres. Kept here so both halves stay in one document.
-- =============================================================================
/*
CREATE TABLE catalogue_meta (
  key TEXT PRIMARY KEY, value TEXT NOT NULL
);  -- 'max_data_version', 'last_sync_at', 'bundled_seed_version'

CREATE TABLE card_products (
  id TEXT PRIMARY KEY, issuer_slug TEXT NOT NULL, slug TEXT NOT NULL,
  name TEXT NOT NULL, network TEXT NOT NULL, card_type TEXT NOT NULL,
  annual_fee_inr REAL NOT NULL DEFAULT 0, joining_fee_inr REAL NOT NULL DEFAULT 0,
  is_upi_linkable INTEGER NOT NULL DEFAULT 0, art_asset TEXT,
  art_primary_color TEXT, point_value_inr REAL,
  data_version INTEGER NOT NULL, verified_at INTEGER,
  rules_json TEXT NOT NULL   -- reward/cap/milestone/fee/benefit blob from
);                            -- v_card_catalogue_export, parsed at load

CREATE TABLE user_cards (
  id TEXT PRIMARY KEY, card_product_id TEXT NOT NULL REFERENCES card_products(id),
  nickname TEXT, credit_limit_inr REAL, statement_day INTEGER, due_day INTEGER,
  opened_on INTEGER, anniversary_on INTEGER,
  points_balance REAL NOT NULL DEFAULT 0, points_balance_state TEXT NOT NULL DEFAULT 'estimated',
  sort_order INTEGER NOT NULL DEFAULT 0, is_default INTEGER NOT NULL DEFAULT 0,
  is_archived INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, client_seq INTEGER NOT NULL
);

CREATE TABLE transactions (
  id TEXT PRIMARY KEY, user_card_id TEXT REFERENCES user_cards(id),
  amount_inr REAL NOT NULL, occurred_at INTEGER NOT NULL,
  merchant_name TEXT, merchant_vpa TEXT, mcc TEXT, category_slug TEXT,
  rail TEXT NOT NULL DEFAULT 'unknown', source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active', reward_state TEXT NOT NULL DEFAULT 'estimated',
  expected_points REAL, expected_value_inr REAL,
  confirmed_points REAL, confirmed_value_inr REAL, reconciled_at INTEGER,
  recommended_card_id TEXT, optimal_value_inr REAL, followed_recommendation INTEGER,
  dedupe_hash TEXT, parent_txn_id TEXT, note TEXT,
  updated_at INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, client_seq INTEGER NOT NULL
);
CREATE INDEX idx_txn_time ON transactions(occurred_at DESC);
CREATE INDEX idx_txn_dedupe ON transactions(dedupe_hash);

CREATE TABLE card_overrides (
  id TEXT PRIMARY KEY, user_card_id TEXT NOT NULL, scope TEXT NOT NULL,
  vpa TEXT, merchant_name TEXT, category_slug TEXT, is_enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, client_seq INTEGER NOT NULL
);

CREATE TABLE cap_states (
  id TEXT PRIMARY KEY, user_card_id TEXT NOT NULL, cap_rule_id TEXT NOT NULL,
  period_start INTEGER NOT NULL, period_end INTEGER NOT NULL,
  consumed REAL NOT NULL DEFAULT 0, cap_value_snapshot REAL NOT NULL,
  state TEXT NOT NULL DEFAULT 'estimated', updated_at INTEGER NOT NULL
);
-- milestone_states, fee_waiver_states, lounge_usage, points_ledger: same shape.

CREATE TABLE needs_review_items (
  id TEXT PRIMARY KEY, source TEXT NOT NULL, raw_text TEXT NOT NULL,
  sender TEXT, received_at INTEGER NOT NULL, parse_error TEXT,
  suggested_amount REAL, suggested_merchant TEXT, suggested_card_id TEXT,
  state TEXT NOT NULL DEFAULT 'pending', resolved_txn_id TEXT
);

CREATE TABLE duplicate_candidates (
  id TEXT PRIMARY KEY, txn_a_id TEXT NOT NULL, txn_b_id TEXT NOT NULL,
  match_score REAL NOT NULL, match_reason TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending', resolution TEXT
);

-- Bundled, read-only, shipped in the APK (product-plan §11.1). ODbL attributed.
CREATE TABLE poi_bundle (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, category_slug TEXT NOT NULL,
  grid_lat REAL NOT NULL, grid_lng REAL NOT NULL, geohash6 TEXT NOT NULL,
  osm_ref TEXT
);
CREATE INDEX idx_poi_geohash ON poi_bundle(geohash6);

-- Known-VPA cache pulled from v_published_merchants; enables offline B3 hits.
CREATE TABLE merchant_cache (
  vpa TEXT PRIMARY KEY, display_name TEXT, mcc TEXT, category_slug TEXT,
  confidence TEXT, cached_at INTEGER NOT NULL
);

-- Outbound queue. Flushed opportunistically; grid-snapped BEFORE it lands here.
CREATE TABLE contribution_outbox (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sync_outbox (
  client_seq INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL,
  entity_id TEXT NOT NULL, op TEXT NOT NULL, payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
*/

-- =============================================================================
--  APPENDIX B — VERIFICATION CHECKLIST (run before declaring DB done)
-- =============================================================================
--  [ ] `supabase db reset` applies all migrations cleanly from empty.
--  [ ] pgTAP: user A cannot select any row belonging to user B (all 25 tables).
--  [ ] pgTAP: anon role can select v_card_catalogue_export, nothing else.
--  [ ] pgTAP: inserting a merchant_location with 6dp coords raises.
--  [ ] pgTAP: cap arithmetic — spend crossing a cap blends pre/post rate.
--  [ ] pgTAP: two identical txns from sms + email produce one duplicate_candidate.
--  [ ] `select * from pandapay.run_anonymization_audit()` returns passed = true.
--  [ ] Editing a cap_rule bumps the parent card_products.data_version.
--  [ ] approve_policy_alert writes catalogue_change + admin_audit_log + bump.
--  [ ] Restore drill: backup restored into a scratch DB, row counts match.
--  [ ] Every table in `public` has relrowsecurity = true.
-- =============================================================================
