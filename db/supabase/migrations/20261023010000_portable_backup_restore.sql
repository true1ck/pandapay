-- Portable backup restore staging. The tables hold untrusted, client-uploaded
-- rows until one guarded commit transaction applies them to live tables.
create table if not exists portable_restore_sessions (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references profiles(id) on delete cascade,
  backup_id          uuid not null,
  idempotency_key    text not null check (length(btrim(idempotency_key)) between 1 and 200),
  format_version     integer not null,
  schema_version     text not null,
  manifest           jsonb not null,
  snapshot_revision  text not null,
  snapshot_at        timestamptz,
  state              text not null default 'staging'
                     check (state in ('staging', 'conflict', 'committed', 'cancelled', 'expired')),
  preview_revision   text,
  result             jsonb,
  expires_at         timestamptz not null default (now() + interval '24 hours'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, profile_id),
  unique (profile_id, backup_id),
  unique (profile_id, idempotency_key)
);

create index if not exists idx_portable_restore_sessions_expiry
  on portable_restore_sessions (expires_at)
  where state = 'staging';

create table if not exists portable_restore_sections (
  session_id         uuid not null references portable_restore_sessions(id) on delete cascade,
  profile_id         uuid not null references profiles(id) on delete cascade,
  section_name       text not null,
  declared_count     bigint not null check (declared_count >= 0),
  declared_bytes     bigint not null check (declared_bytes >= 0),
  declared_sha256    text not null check (declared_sha256 ~ '^[0-9a-f]{64}$'),
  received_count     bigint not null default 0 check (received_count >= 0),
  received_bytes     bigint not null default 0 check (received_bytes >= 0),
  received_sha256    text not null check (received_sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_at        timestamptz not null default now(),
  primary key (session_id, section_name),
  foreign key (session_id, profile_id)
    references portable_restore_sessions(id, profile_id) on delete cascade
);

create table if not exists portable_restore_records (
  session_id         uuid not null,
  profile_id         uuid not null references profiles(id) on delete cascade,
  section_name       text not null,
  ordinal            bigint not null check (ordinal >= 0),
  stable_id          text not null,
  record             jsonb not null check (jsonb_typeof(record) = 'object'),
  canonical_sha256   text not null check (canonical_sha256 ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz not null default now(),
  primary key (session_id, section_name, ordinal),
  foreign key (session_id, profile_id)
    references portable_restore_sessions(id, profile_id) on delete cascade
);

create index if not exists idx_portable_restore_records_lookup
  on portable_restore_records (session_id, section_name, stable_id);

create table if not exists portable_backup_ledger (
  profile_id         uuid not null references profiles(id) on delete cascade,
  backup_id          uuid not null,
  session_id         uuid not null references portable_restore_sessions(id),
  result             jsonb not null,
  committed_at       timestamptz not null default now(),
  primary key (profile_id, backup_id),
  unique (session_id)
);

alter table portable_restore_sessions enable row level security;
alter table portable_restore_sessions force row level security;
alter table portable_restore_sections enable row level security;
alter table portable_restore_sections force row level security;
alter table portable_restore_records enable row level security;
alter table portable_restore_records force row level security;
alter table portable_backup_ledger enable row level security;
alter table portable_backup_ledger force row level security;

drop policy if exists portable_restore_sessions_owner on portable_restore_sessions;
create policy portable_restore_sessions_owner on portable_restore_sessions
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
drop policy if exists portable_restore_sections_owner on portable_restore_sections;
create policy portable_restore_sections_owner on portable_restore_sections
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
drop policy if exists portable_restore_records_owner on portable_restore_records;
create policy portable_restore_records_owner on portable_restore_records
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
drop policy if exists portable_backup_ledger_owner on portable_backup_ledger;
create policy portable_backup_ledger_owner on portable_backup_ledger
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

grant select, insert, update, delete on
  portable_restore_sessions,
  portable_restore_sections,
  portable_restore_records,
  portable_backup_ledger to app_user;

comment on table portable_restore_records is
  'Untrusted portable backup rows. Never read as live state; only the guarded restore commit applies them.';
