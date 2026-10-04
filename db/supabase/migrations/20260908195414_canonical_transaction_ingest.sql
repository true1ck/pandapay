-- One real-world purchase must have one canonical transactions row even when
-- it is observed through several channels (manual entry, SMS, email, or a
-- statement). The observations table preserves that provenance without
-- copying raw message bodies into the ledger.

begin;

alter table transactions
  add column if not exists state_applied boolean;

alter table transactions
  alter column state_applied set default false;

comment on column transactions.state_applied is
  'True only when this row has been applied to card cap/milestone/points/fee-waiver state. Null is a legacy row whose state predates this marker.';

alter table transactions
  add column if not exists is_backfill boolean not null default false;

comment on column transactions.is_backfill is
  'Historical imports remain visible in Activity/Insights but do not mutate current-cycle card state.';

create table if not exists transaction_observations (
  id              uuid primary key default gen_random_uuid(),
  profile_id      uuid not null references profiles(id) on delete cascade,
  transaction_id  uuid not null references transactions(id) on delete cascade,
  source          txn_source not null,
  source_key      text,
  external_ref    text,
  observed_at     timestamptz not null default now(),
  payload_hash    text,
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  constraint transaction_observations_metadata_object
    check (jsonb_typeof(metadata) = 'object')
);

comment on table transaction_observations is
  'Privacy-safe provenance for each channel that reported a canonical transaction. Raw SMS and email bodies are deliberately excluded.';

create unique index if not exists uq_transaction_observations_source_key
  on transaction_observations (profile_id, source, source_key)
  where source_key is not null;

create index if not exists idx_transaction_observations_transaction
  on transaction_observations (transaction_id);

create index if not exists idx_transaction_observations_profile_observed
  on transaction_observations (profile_id, observed_at desc);

-- Every pre-migration transaction is itself one observation. ON CONFLICT
-- keeps this rerunnable if a partially-applied migration is repaired.
insert into transaction_observations
  (profile_id, transaction_id, source, source_key, observed_at, metadata)
select profile_id, id, source, source_key, created_at, '{"legacy":true}'::jsonb
  from transactions
on conflict (profile_id, source, source_key) where source_key is not null
do nothing;

alter table duplicate_candidates
  add column if not exists suppressed_txn_id uuid references transactions(id) on delete set null;

alter table duplicate_candidates
  drop constraint if exists duplicate_candidates_suppressed_member;

alter table duplicate_candidates
  add constraint duplicate_candidates_suppressed_member
  check (suppressed_txn_id is null or suppressed_txn_id in (txn_a_id, txn_b_id));

comment on column duplicate_candidates.suppressed_txn_id is
  'Pending candidate excluded from active totals until the user merges it or explicitly keeps both.';

create index if not exists idx_duplicate_candidates_suppressed
  on duplicate_candidates (suppressed_txn_id)
  where suppressed_txn_id is not null;

-- Supports the bounded cross-source candidate lookup performed for every
-- spend ingest. The profile prefix also keeps owner-scoped reads efficient.
create index if not exists idx_transactions_active_dedupe_window
  on transactions (profile_id, occurred_at, amount_inr)
  where status = 'active' and entry_kind = 'spend';

alter table transaction_observations enable row level security;
alter table transaction_observations force row level security;

drop policy if exists transaction_observations_owner on transaction_observations;
create policy transaction_observations_owner on transaction_observations
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

-- Local/prod migrate.sh repeats setup_app_role.sql after migrations, but an
-- independently-run Supabase migration must also leave the API role usable.
grant select, insert, update, delete on transaction_observations to app_user;

commit;
