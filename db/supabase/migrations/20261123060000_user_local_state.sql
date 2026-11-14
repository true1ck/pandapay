-- WP-S7: per-person state that used to live only on the phone (bill-to-card
-- assignments, typed bank balances, subscription overrides), synced so it
-- survives a phone change. One generic table; last writer wins per
-- (profile, kind, key) by the phone's edit clock. A delete keeps a tombstone so
-- an offline phone cannot bring a removed choice back.
-- Typed bank balances are sensitive: the API stores them ONLY as ciphertext in
-- payload_enc (payload stays null). Other kinds use plain jsonb in payload.
create sequence if not exists user_local_state_seq;

create table if not exists user_local_state (
  profile_id       uuid not null references profiles(id) on delete cascade,
  kind             text not null check (kind in ('bill_card_assignment','bank_balance','subscription_override')),
  state_key        text not null check (char_length(state_key) between 1 and 200),
  payload          jsonb check (payload is null or (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 4096)),
  payload_enc      text check (payload_enc is null or char_length(payload_enc) <= 8192),
  client_edited_at timestamptz not null,
  deleted          boolean not null default false,
  updated_at       timestamptz not null default now(),
  server_seq       bigint not null default nextval('user_local_state_seq'),
  primary key (profile_id, kind, state_key),
  -- A balance can never be stored in the clear, and a row holds one form only.
  check (not (kind = 'bank_balance' and payload is not null)),
  check (not (payload is not null and payload_enc is not null))
);

create index if not exists idx_user_local_state_seq
  on user_local_state(profile_id, server_seq);

alter table user_local_state enable row level security;
alter table user_local_state force row level security;
drop policy if exists user_local_state_owner on user_local_state;
create policy user_local_state_owner on user_local_state
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

do $$ begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='app_user') then
    execute 'grant select, insert, update, delete on user_local_state to app_user';
    execute 'grant usage on sequence user_local_state_seq to app_user';
  end if;
end $$;

comment on table user_local_state is
  'Per-person local state synced between phones (bill-card assignments, bank balances (ciphertext only), subscription overrides). Last writer wins by client_edited_at.';
