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


