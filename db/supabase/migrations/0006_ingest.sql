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


