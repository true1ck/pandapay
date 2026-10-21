-- Typed source/fact contract (SMS intelligence Phase 1).
--
-- Today the SMS pipeline collapses every message into at most one canonical
-- transaction plus ad-hoc resolvers, so money facts that are not purchases
-- (balance snapshots, bills, mandate ceilings) are thrown away or acked
-- locally before the server ever sees them. This migration adds an additive,
-- replay-safe record of ONE source producing SEVERAL typed facts:
--
--   sms_sources       one row per (profile, source_key) — the source envelope.
--   sms_source_facts  the facts a source yielded, deterministically indexed
--                     so replaying the same message recreates the same fact
--                     set and never mints new row identities.
--   fact_overrides    user corrections. Read paths apply them over the base
--                     payload; the upserting re-player never touches this
--                     table, so a correction survives every future replay.
--
-- Raw message text is still banned here (same privacy stance as
-- transaction_observations): sender + normalized-body hash only. Legacy
-- /transactions/from-sms, its source keys and receipts continue unchanged;
-- this contract is additive and nullable everywhere it meets old data.

begin;

create table if not exists sms_sources (
  id               uuid primary key default gen_random_uuid(),
  profile_id       uuid not null references profiles(id) on delete cascade,
  source_key       text not null,
  sender           text,
  body_hash        text not null,
  channel          text not null default 'sms',
  contract_version integer not null default 1,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sms_sources_channel_known
    check (channel in ('sms')),
  constraint sms_sources_contract_version_positive
    check (contract_version >= 1),
  constraint sms_sources_sender_no_body
    check (sender is null or length(sender) <= 32)
);

comment on table sms_sources is
  'Envelope for one ingested financial message identified by the legacy source
key (profile + normalized sender + body hash). Deliberately stores no raw
body: the SHA-256 body hash proves identity while keeping text off the server.';

create unique index if not exists uq_sms_sources_identity
  on sms_sources (profile_id, source_key);

create index if not exists idx_sms_sources_profile_seen
  on sms_sources (profile_id, updated_at desc);

create table if not exists sms_source_facts (
  id              uuid primary key default gen_random_uuid(),
  source_id       uuid not null references sms_sources(id) on delete cascade,
  profile_id      uuid not null references profiles(id) on delete cascade,
  fact_index      integer not null,
  fact_type       text not null,
  payload         jsonb not null default '{}'::jsonb,
  provenance      jsonb not null default '{}'::jsonb,
  status          text not null default 'active',
  contract_version integer not null default 1,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint sms_source_facts_payload_object
    check (jsonb_typeof(payload) = 'object' and jsonb_typeof(provenance) = 'object'),
  constraint sms_source_facts_type_known
    check (fact_type in (
      'posted_movement',
      'pending_or_failed_attempt',
      'balance_snapshot',
      'bill_obligation',
      'bill_payment',
      'mandate_lifecycle',
      'card_identity_hint',
      'security_or_service_alert',
      'promotion'
    )),
  constraint sms_source_facts_status_known
    check (status in ('active', 'superseded', 'discarded')),
  constraint sms_source_facts_version_positive
    check (contract_version >= 1)
);

comment on table sms_source_facts is
  'One typed financial fact (spend, bill due, balance snapshot, mandate
ceiling, …) extracted from one source. fact_index comes from a deterministic
order so an upload replay upserts the same rows instead of duplicating them.';

create unique index if not exists uq_sms_source_facts_slot
  on sms_source_facts (source_id, fact_index);

create index if not exists idx_sms_source_facts_profile_type
  on sms_source_facts (profile_id, fact_type, status);

-- User corrections live apart from the replayed facts by design: re-uploading
-- the same source upserts facts with filed payloads but must never resurrect
-- an amount the user fixed by hand.
create table if not exists fact_overrides (
  id              uuid primary key default gen_random_uuid(),
  source_id       uuid not null references sms_sources(id) on delete cascade,
  profile_id      uuid not null references profiles(id) on delete cascade,
  fact_index      integer not null,
  patch           jsonb not null,
  reason          text,
  applied_at      timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  constraint fact_overrides_patch_object
    check (jsonb_typeof(patch) = 'object'),
  constraint fact_overrides_slot_positive
    check (fact_index >= 0)
);

comment on table fact_overrides is
  'User corrections for one fact of one source. When resolving a fact for
consumption, the patch is merged over the base payload and always wins.';

create unique index if not exists uq_fact_overrides_slot
  on fact_overrides (source_id, fact_index);

create index if not exists idx_fact_overrides_profile
  on fact_overrides (profile_id, applied_at desc);

alter table sms_sources enable row level security;
alter table sms_sources force row level security;
drop policy if exists sms_sources_owner on sms_sources;
create policy sms_sources_owner on sms_sources
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

alter table sms_source_facts enable row level security;
alter table sms_source_facts force row level security;
drop policy if exists sms_source_facts_owner on sms_source_facts;
create policy sms_source_facts_owner on sms_source_facts
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

alter table fact_overrides enable row level security;
alter table fact_overrides force row level security;
drop policy if exists fact_overrides_owner on fact_overrides;
create policy fact_overrides_owner on fact_overrides
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

-- Local/prod migrate.sh repeats setup_app_role.sql after migrations, but an
-- independently-run Supabase migration must also leave the API role usable.
grant select, insert, update, delete on sms_sources, sms_source_facts, fact_overrides to app_user;

commit;
