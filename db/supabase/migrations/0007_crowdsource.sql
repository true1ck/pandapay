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


