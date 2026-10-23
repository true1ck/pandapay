-- Additive central domain projections for typed SMS facts.
--
-- The source/fact tables remain immutable evidence. This table is a rebuildable
-- projection keyed by a stable domain identity. It deliberately keeps mandate
-- authorization and subscription service decisions as separate rows, so a
-- mandate limit cannot be displayed as paid or recurring subscription money.

begin;

-- A durable checkpoint makes historical fact projection lazy and bounded.
-- Existing sources start at zero; replayed sources advance only after their
-- resolved facts and user overrides have been projected successfully.
alter table sms_sources
  add column if not exists projection_version integer not null default 0;

create index if not exists idx_sms_sources_projection_backfill
  on sms_sources (profile_id, projection_version, first_seen_at);

create table if not exists financial_projections (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references profiles(id) on delete cascade,
  projection_kind    text not null,
  projection_key     text not null,
  status             text not null,
  projection         jsonb not null default '{}'::jsonb,
  source_id          uuid references sms_sources(id) on delete set null,
  source_key         text,
  source_fact_ids    uuid[] not null default '{}'::uuid[],
  projection_version integer not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint financial_projections_kind_check
    check (projection_kind in (
      'movement', 'account_observation', 'bill_obligation', 'bill_payment',
      'mandate', 'subscription'
    )),
  constraint financial_projections_status_check
    check (status in (
      'posted', 'observed', 'open', 'active', 'paused', 'cancelled',
      'payment_issue', 'candidate', 'renewal_unverified', 'ended', 'unknown'
    )),
  constraint financial_projections_payload_object
    check (jsonb_typeof(projection) = 'object'),
  constraint financial_projections_version_positive
    check (projection_version >= 1)
);

create unique index if not exists uq_financial_projections_identity
  on financial_projections (profile_id, projection_kind, projection_key);

create index if not exists idx_financial_projections_profile_kind_status
  on financial_projections (profile_id, projection_kind, status, updated_at desc);

create index if not exists idx_financial_projections_source
  on financial_projections (profile_id, source_id);

drop trigger if exists trg_financial_projections_touch on financial_projections;
create trigger trg_financial_projections_touch before update on financial_projections
  for each row execute function pandapay.touch_updated_at();

alter table financial_projections enable row level security;
alter table financial_projections force row level security;
drop policy if exists financial_projections_owner on financial_projections;
create policy financial_projections_owner on financial_projections
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

grant select, insert, update, delete on financial_projections to app_user;

comment on table financial_projections is
  'Rebuildable profile-scoped domain decisions derived from typed SMS facts. Mandate limits and subscription amounts remain separate roles.';

commit;
