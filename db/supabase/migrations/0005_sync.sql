-- >>> MIGRATION 0005 — SYNC + CONFLICT ========================================
-- §7.3: silent data loss during sync is the fastest way to lose a finance user.

create table change_log (               -- append-only; never updated
  id                  bigserial primary key,
  profile_id          uuid not null references profiles(id) on delete cascade,
  device_id           uuid references user_devices(id) on delete set null,
  entity              text not null,        -- 'transactions','user_cards',...
  entity_id           uuid not null,
  op                  sync_op not null,
  payload             jsonb not null,       -- full row after change
  field_clocks        jsonb not null default '{}'::jsonb,  -- per-field LWW stamps
  client_seq          bigint not null,
  server_seq          bigint generated always as identity,
  created_at          timestamptz not null default now()
);

create table sync_cursors (
  device_id           uuid primary key references user_devices(id) on delete cascade,
  profile_id          uuid not null references profiles(id) on delete cascade,
  last_server_seq     bigint not null default 0,
  last_pushed_at      timestamptz,
  last_pulled_at      timestamptz
);

-- Every automatic resolution leaves a row. F5 renders this as the conflict log.
create table sync_conflicts (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  entity              text not null,
  entity_id           uuid not null,
  field               text not null,
  local_value         jsonb,
  server_value        jsonb,
  chosen_value        jsonb,
  strategy            conflict_strategy not null,
  device_id           uuid references user_devices(id) on delete set null,
  user_acknowledged   boolean not null default false,
  created_at          timestamptz not null default now()
);


