-- >>> MIGRATION 0028 — ACCOUNT-LEVEL USER SETTINGS ===========================
--
-- Plan Phase 1.1 (docs/superpowers/plans/2026-08-11-backend-readiness-data-
-- capture-device-portability.md §1.3.2). Every display and first-run
-- preference in the app was SharedPreferences-only: theme mode, text scale,
-- number format, onboarding-complete, tutorial-seen, due-date reminders,
-- what's-new version. The practical consequence was that signing in on a new
-- phone re-ran onboarding for an existing user and reset every preference
-- they had chosen — the app looked like it had lost their data even though
-- every card and transaction came back correctly.
--
-- A single jsonb blob, not a column per preference. These are client display
-- preferences with no server-side semantics: nothing in api/, the console, or
-- any SQL function reads them, and nothing ever will — the server is a
-- synchronisation point, not a consumer. A column per preference would mean a
-- migration every time the app adds a toggle, and each one would be a column
-- no query ever filters on. The client owns the key namespace (see
-- app/lib/features/settings/settings_sync.dart's registry, which is the
-- authoritative list).
--
-- DELIBERATELY NOT SYNCED, and enforced on the client rather than here: the
-- biometric-app-lock flag. That one is a statement about a specific handset's
-- hardware and enrolled biometrics, so carrying it to a new device would
-- either silently disable a lock the user believes is on, or enable one the
-- new device cannot satisfy. It stays in SharedPreferences by design.
--
-- No device_id column and no per-device rows. This is explicitly the
-- account-level bucket — per-device state is what SharedPreferences already
-- is, and the whole point of this table is the values that should follow the
-- human rather than the handset.

create table if not exists user_settings (
  profile_id          uuid primary key references profiles(id) on delete cascade,
  settings            jsonb not null default '{}'::jsonb,
  -- Bumped server-side on every write. The client uses it only to detect
  -- "someone else changed this" for logging; it is NOT an optimistic-locking
  -- token, because the merge below is per-key and commutative, so a lost
  -- update can only happen when two devices write the SAME key at the same
  -- moment — for a display preference that is a genuine last-writer-wins, not
  -- a conflict worth surfacing to a user. Contrast transactions, where the
  -- opposite call is made (see 0005_sync.sql).
  revision            bigint not null default 1,
  updated_at          timestamptz not null default now()
);

alter table user_settings enable row level security;
alter table user_settings force row level security;

-- Same owner-policy shape as every other profile-scoped table in
-- 0011_rls_policies.sql. Written out rather than added to that migration's
-- loop so 0011 stays an accurate record of what existed when it ran.
drop policy if exists user_settings_owner on user_settings;
create policy user_settings_owner on user_settings
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

comment on table user_settings is
  'Account-level client display/first-run preferences, synced across a '
  'user''s devices (plan Phase 1.1). Opaque to the server: no api/ route, SQL '
  'function, or console screen reads individual keys. Per-device state stays '
  'in the client''s own SharedPreferences and never lands here — notably the '
  'biometric app-lock flag, which is a property of one handset.';

-- Erasure: the `on delete cascade` above already removes this row when
-- pandapay.execute_account_deletion() deletes the profile, so that function
-- needs no change. Stated explicitly because a reader auditing DPDP §8.2
-- coverage should not have to infer it from the FK.
