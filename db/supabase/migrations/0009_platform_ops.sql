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


