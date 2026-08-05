-- >>> MIGRATION 0004 — USER DOMAIN ============================================
-- Every table here is RLS-protected. Local-only users never appear at all.

-- id is NOT a Postgres FK to auth.users (that was Supabase-specific). This
-- product DB and the PandaPay auth service (auth/) are separate databases;
-- cross-database FKs don't exist in Postgres. The app backend is responsible
-- for only inserting a profiles row for a user id that exists in the auth
-- service's `users` table, and for calling pandapay.execute_account_deletion()
-- (0010) whenever it deletes the corresponding auth-service user.
create table profiles (
  id                  uuid primary key,
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


