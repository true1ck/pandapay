-- >>> MIGRATION 0040 — BUDGETS, NON-CARD SPEND, RECURRING SERIES ============
--
-- The data model behind the Insights build-out: budgets the user sets,
-- spend that doesn't run through a credit card, and subscriptions detected
-- from history.
--
-- All three are owner-scoped user data and get the same RLS treatment every
-- other profile_id-carrying table in 0011 gets — enabled, forced, and one
-- `profile_id = pandapay.uid()` policy. A new user-data table without those
-- three lines is a cross-account read, so they are not optional.

-- ---------------------------------------------------------------------------
-- 1. Budgets
-- ---------------------------------------------------------------------------
--
-- There was no budget concept anywhere in the product — not in the app, the
-- API, the domain package or this schema. Spending Overview said so in its
-- own doc-comment ("context, not a budgeting tool... deliberately no
-- progress bars toward any spending limit"). This reverses that decision
-- deliberately rather than by accident.
--
-- Advisory only, by design: nothing in this schema blocks or declines a
-- transaction, and nothing should. A budget is a line the user drew for
-- themselves and wants to be told about.

do $$ begin
  create type budget_scope as enum ('overall', 'category', 'card');
exception when duplicate_object then null; end $$;

do $$ begin
  create type budget_period as enum ('weekly', 'monthly', 'quarterly', 'yearly');
exception when duplicate_object then null; end $$;

create table if not exists budgets (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references profiles(id) on delete cascade,
  scope         budget_scope not null,
  -- spend_categories.id when scope='category', user_cards.id when
  -- scope='card', NULL when scope='overall'. Not a foreign key because it
  -- points at two different tables depending on `scope`; the CHECK below
  -- enforces presence, and the API validates the referent exists.
  scope_ref_id  uuid,
  period        budget_period not null,
  amount_inr    numeric(12,2) not null check (amount_inr > 0),
  -- The budget's own anchor, so a "weekly" budget can start on the day the
  -- user actually thinks of as their week's start rather than an imposed
  -- Monday.
  starts_on     date not null default current_date,
  -- Whether unspent budget carries into the next period. Off by default:
  -- rollover makes "am I over?" much harder to answer honestly, and most
  -- people asking for a budget want the simple version first.
  rollover      boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint budgets_scope_ref_matches_scope check (
    (scope = 'overall' and scope_ref_id is null) or
    (scope <> 'overall' and scope_ref_id is not null)
  )
);

-- One ACTIVE budget per target per period. Deactivating rather than
-- deleting is what preserves history (see budget_periods below), so the
-- uniqueness has to be partial on is_active or an edit would collide with
-- the row it replaces.
create unique index if not exists idx_budgets_one_active_per_target
  on budgets (profile_id, scope, coalesce(scope_ref_id, '00000000-0000-0000-0000-000000000000'::uuid), period)
  where is_active;

create trigger trg_budgets_touch before update on budgets
  for each row execute function pandapay.touch_updated_at();

-- Closed-out performance, written when a period ends.
--
-- Exists so "did I stay in budget in March?" survives the budget being
-- edited in April. Recomputing history against the CURRENT budget amount
-- would quietly rewrite the past every time someone adjusted a number, and
-- a budget history that changes when you edit the budget is worse than none.
create table if not exists budget_periods (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references profiles(id) on delete cascade,
  budget_id      uuid not null references budgets(id) on delete cascade,
  period_start   date not null,
  period_end     date not null,
  -- Snapshotted, not read through to budgets.amount_inr, for the reason above.
  budget_amount_inr numeric(12,2) not null,
  actual_spend_inr  numeric(12,2) not null default 0,
  closed_at      timestamptz,
  unique (budget_id, period_start)
);

-- ---------------------------------------------------------------------------
-- 2. Non-card spend, income and investments
-- ---------------------------------------------------------------------------
--
-- `transactions.user_card_id` has been nullable since 0004, but every write
-- path REQUIRED it, so cash, debit, UPI-straight-from-bank, income and
-- investments simply could not be recorded. That capped the app at "what my
-- credit cards did" when the data model was already capable of more.
--
-- The two columns below are what let a card-less row be interpreted
-- correctly rather than silently counted as card spend:
--
--   - `instrument` — what paid for it. Everything that isn't a credit card
--     must be excluded from cap, milestone, points and fee-waiver state:
--     those describe a specific card's cycle, and a cash purchase moves
--     none of them.
--   - `entry_kind` — whether it is spend at all. Income and investments
--     belong in a spending report as their own lines, never added into the
--     spend total, and a transfer between the user's own accounts is not
--     spend in either direction.
--
-- Defaults are chosen so every existing row keeps meaning exactly what it
-- meant before this migration: a credit-card spend.

do $$ begin
  create type txn_instrument as enum ('credit_card', 'debit_card', 'cash', 'upi_bank', 'wallet', 'other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type txn_entry_kind as enum ('spend', 'income', 'investment', 'transfer');
exception when duplicate_object then null; end $$;

alter table transactions add column if not exists instrument txn_instrument not null default 'credit_card';
alter table transactions add column if not exists entry_kind txn_entry_kind not null default 'spend';

comment on column transactions.instrument is
  'What paid for this. Only credit_card rows move cap/milestone/points/'
  'fee-waiver state — those describe one card''s cycle, and cash moves none '
  'of them.';
comment on column transactions.entry_kind is
  'Whether this is spend at all. Income and investments are reported on '
  'their own lines and never added into a spend total; a transfer between '
  'the user''s own accounts is not spend in either direction.';

-- A card-less row must not claim to be a credit-card transaction, and a
-- credit-card row must have a card. Enforced here rather than left to the
-- API so no future write path can reintroduce the inconsistency.
alter table transactions drop constraint if exists transactions_card_matches_instrument;
alter table transactions add constraint transactions_card_matches_instrument check (
  (instrument = 'credit_card' and user_card_id is not null) or
  (instrument <> 'credit_card')
);

-- Spend reports filter on both columns constantly and always within a date
-- range for one profile.
create index if not exists idx_txn_profile_kind_date
  on transactions (profile_id, entry_kind, occurred_at desc) where status = 'active';

-- ---------------------------------------------------------------------------
-- 3. Recurring series (subscriptions)
-- ---------------------------------------------------------------------------
--
-- Detected from the user's own history rather than declared: same merchant,
-- similar amount, regular cadence, enough repeats to not be a coincidence.
-- The detector lives in the API (src/recurring.js); this is only where its
-- conclusions are kept so they survive a restart and can be corrected.
create table if not exists recurring_series (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references profiles(id) on delete cascade,
  -- The normalized merchant name (lowercased, letters+digits only) — the
  -- same normalization dedupe_hash and both reward engines use, so
  -- 'NETFLIX.COM' and 'Netflix' are one series rather than two.
  merchant_key       text not null,
  display_name       text,
  category_id        uuid references spend_categories(id) on delete set null,
  user_card_id       uuid references user_cards(id) on delete set null,
  typical_amount_inr numeric(12,2) not null,
  -- Median gap between occurrences, in days. Not an enum of
  -- monthly/annual: real subscriptions bill on cycles that don't map
  -- cleanly onto either (28-day, quad-weekly, 4-monthly), and rounding
  -- them into a bucket produces a next-charge date that is visibly wrong.
  cadence_days       int not null check (cadence_days > 0),
  occurrence_count   int not null check (occurrence_count > 0),
  first_seen_on      date not null,
  last_seen_on       date not null,
  next_expected_on   date,
  -- Cleared when the user says "I cancelled this", so a dismissed series
  -- doesn't come straight back on the next detection run.
  is_active          boolean not null default true,
  dismissed_at       timestamptz,
  detected_at        timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (profile_id, merchant_key)
);

create trigger trg_recurring_series_touch before update on recurring_series
  for each row execute function pandapay.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 4. RLS — every one of these carries profile_id and holds user data.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['budgets', 'budget_periods', 'recurring_series'] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format($f$
      create policy %1$s_owner on %1$I
        for all to public
        using (profile_id = pandapay.uid())
        with check (profile_id = pandapay.uid())
    $f$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Notification categories for budgets.
-- ---------------------------------------------------------------------------
--
-- Two, not one. "Over budget" and "running ahead of pace" are different
-- events with different usefulness: the first is a post-mortem, the second
-- is something the user can still act on. Bundling them under one toggle
-- would force someone who wants the early warning to also accept the
-- after-the-fact one, and vice versa.
--
-- Both default ON. Unlike location and the monthly report (opt-in by
-- design), a budget is something the user explicitly asked for — having set
-- one and then not being told about it would be the surprising outcome.
alter table notification_preferences
  add column if not exists category_budget_warning boolean not null default true;
alter table notification_preferences
  add column if not exists category_budget_exceeded boolean not null default true;
