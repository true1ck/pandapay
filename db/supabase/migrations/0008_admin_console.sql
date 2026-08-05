-- >>> MIGRATION 0008 — ADMIN CONSOLE + POLICY CHANGE DETECTION ================
-- Internal only. No public signup path exists to any of these tables.

-- id is the auth service's users.id for an operator account (role checked
-- there too); no cross-database FK, see note on profiles in 0004.
create table admin_users (
  id                  uuid primary key,
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


