-- SMS pipeline v2 / WP-08: instruments, facts, events and ledger entries.
-- The phone is the interpreter; these tables only store what it uploads
-- (Contracts -> Storage). Evidence spans and raw tokens never reach them.
-- Every table is owner-scoped with forced RLS, exactly as in 0011.
--
-- updated_at on the sync tables is written explicitly by the API with
-- clock_timestamp() after it takes the per-profile ingest lock, so (updated_at,
-- id) is a monotonic cursor per profile. There is deliberately no touch trigger.

create table sms_v2_instruments (
  instrument_id        uuid        primary key,
  profile_id           uuid        not null references profiles (id) on delete cascade,
  kind                 text        not null check (kind in ('bank_account','credit_card','debit_card','prepaid_card','wallet','broker','loan','pay_later')),
  issuer_slug          text        not null check (issuer_slug ~ '^[a-z0-9_]+$'),
  mask_digits          text        check (mask_digits is null or mask_digits ~ '^[0-9]{2,6}$'),
  mask_length          integer     check (mask_length is null or mask_length between 2 and 32),
  display_name         text        not null,
  status               text        not null check (status in ('detected','confirmed','rejected','archived')),
  user_card_id         uuid        references user_cards (id) on delete set null,
  parent_instrument_id uuid,
  aliases              jsonb       not null default '{"senders":[],"vpas":[],"productNames":[]}'::jsonb,
  credit_limit_minor   bigint      check (credit_limit_minor is null or credit_limit_minor >= 0),
  credit_limit_source  text        check (credit_limit_source is null or credit_limit_source in ('sms','user')),
  credit_limit_at      timestamptz,
  available_minor      bigint      check (available_minor is null or available_minor >= 0),
  available_at         timestamptz,
  points_balance       bigint      check (points_balance is null or points_balance >= 0),
  points_at            timestamptz,
  first_seen_at        timestamptz not null,
  last_seen_at         timestamptz not null,
  evidence_count       integer     not null default 0 check (evidence_count >= 0),
  updated_at           timestamptz not null default clock_timestamp()
);
-- Identity key (profile, kind, issuer, mask). Two instruments without a mask
-- share a key, so the mask is coalesced.
create unique index sms_v2_instruments_key_uq
  on sms_v2_instruments (profile_id, kind, issuer_slug, (coalesce(mask_digits, '')));
create index sms_v2_instruments_sync_idx on sms_v2_instruments (profile_id, updated_at, instrument_id);

create table sms_v2_facts (
  fact_id           text        primary key check (fact_id ~ '^[0-9a-f]{64}$'),
  profile_id        uuid        not null references profiles (id) on delete cascade,
  source_key        text        not null,
  fact_type         text        not null check (fact_type in ('movement','attempt','hold','balance_snapshot','limit_change','bill_due','mandate','reward','instrument_hint')),
  contract_version  text        not null,
  observed_at       timestamptz not null,
  occurred_at       timestamptz,
  instrument_id     uuid,
  payload           jsonb       not null,   -- the fact without evidence spans or raw tokens
  provenance        jsonb       not null,
  created_at        timestamptz not null default now()
);
create index sms_v2_facts_profile_observed_idx on sms_v2_facts (profile_id, observed_at);
create index sms_v2_facts_profile_source_idx on sms_v2_facts (profile_id, source_key);

create table sms_v2_events (
  event_id      text        primary key check (event_id ~ '^[0-9a-f]{64}$'),
  profile_id    uuid        not null references profiles (id) on delete cascade,
  type          text        not null check (type in ('purchase','refund','cashback','income','p2p_out','p2p_in','own_transfer','card_bill_payment','wallet_topup','investment','ipo_application','investment_withdrawal','dividend','atm_withdrawal','fee','emi','bill_payment','subscription_charge','unknown')),
  status        text        not null check (status in ('complete','awaiting_leg','ambiguous','user_confirmed')),
  legs          jsonb       not null check (jsonb_typeof(legs) = 'array' and jsonb_array_length(legs) >= 1),
  link_rule_id  text,
  confidence    double precision not null check (confidence between 0 and 1),
  occurred_at   timestamptz not null,
  amount_minor  bigint      not null check (amount_minor >= 0),
  updated_at    timestamptz not null default clock_timestamp()
);
create index sms_v2_events_sync_idx on sms_v2_events (profile_id, updated_at, event_id);

create table sms_v2_ledger_entries (
  entry_id               text        primary key check (entry_id ~ '^[0-9a-f]{64}$'),
  profile_id             uuid        not null references profiles (id) on delete cascade,
  event_id               text        not null,
  from_instrument_id     uuid,
  from_external          text,
  from_own_unresolved    text,
  to_instrument_id       uuid,
  to_external            text,
  to_own_unresolved      text,
  amount_minor           bigint      not null check (amount_minor > 0),
  unit                   text        not null check (unit in ('INR','POINTS')),
  occurred_at            timestamptz not null,
  category_slug          text,
  category_source        text        check (category_source is null or category_source in ('user','shared','catalogue','mcc','history_confirmed','ai','default')),
  counts_as_transaction  boolean     not null,
  is_spend               boolean     not null,
  is_income              boolean     not null,
  is_investment          boolean     not null,
  updated_at             timestamptz not null default clock_timestamp(),
  -- exactly one of instrument / external / ownUnresolved on each side
  check (num_nonnulls(from_instrument_id, from_external, from_own_unresolved) = 1),
  check (num_nonnulls(to_instrument_id, to_external, to_own_unresolved) = 1)
);
create index sms_v2_ledger_event_idx on sms_v2_ledger_entries (profile_id, event_id);
create index sms_v2_ledger_sync_idx on sms_v2_ledger_entries (profile_id, updated_at, entry_id);

-- RLS: default deny, owner-only, forced (same pattern as 0011).
do $$
declare t text;
begin
  foreach t in array array['sms_v2_instruments','sms_v2_facts','sms_v2_events','sms_v2_ledger_entries'] loop
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

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    grant select, insert, update, delete on
      sms_v2_instruments, sms_v2_facts, sms_v2_events, sms_v2_ledger_entries to app_user;
  end if;
end $$;

-- transactions: v2 rows carry the event they project and a pipeline marker.
alter table transactions add column if not exists event_id text;
alter table transactions add column if not exists pipeline_version smallint not null default 1;
comment on column transactions.event_id is
  'SMS pipeline v2: sms_v2_events.event_id this row projects. NULL for every v1 row.';
comment on column transactions.pipeline_version is
  '1 = written by the v1 pipeline or by hand; 2 = projected from a v2 event.';
create unique index if not exists uq_transactions_profile_event
  on transactions (profile_id, event_id) where event_id is not null;

-- entry_kind is an enum; v2 adds refund (Contracts -> Totals and counts).
alter type txn_entry_kind add value if not exists 'refund';
