-- >>> MIGRATION 0018 — IMAP CONNECTIONS (Group F, Task F7) ====================
-- F7 IMAP Connection (fallback to F3 email forwarding). Per
-- implementation-plan-group-e-f-g.md's own finding: "No table for this
-- exists in any migration... a real schema gap, not just missing routes."
--
-- Security note (per this project's CLAUDE.md owasp-mobile-security-checker
-- guidance for a payments app touching credential storage): an IMAP app
-- password is a real, if scoped, credential. `app_password_encrypted` is
-- stored via pgcrypto's pgp_sym_encrypt (extension already enabled in
-- 0001_extensions_and_enums.sql), keyed off a server-side secret
-- (IMAP_ENCRYPTION_KEY env var, never committed, never logged) rather than
-- plaintext. This is a stopgap, not the real answer — see api/src/index.js's
-- POST /imap-connections doc-comment and the final chunk report for what a
-- production-grade answer (KMS-managed key, envelope encryption, key
-- rotation) would need instead of a single static symmetric key.
create table imap_connections (
  id                    uuid primary key default gen_random_uuid(),
  profile_id            uuid not null references profiles(id) on delete cascade,
  email                 citext not null,
  app_password_encrypted bytea not null,   -- pgp_sym_encrypt(app_password, key) — never plaintext
  imap_host             text not null,
  imap_port             int not null default 993,
  sender_filter         text,              -- e.g. restrict polling to bank-sender addresses only
  is_active             boolean not null default true,
  verified_at           timestamptz,       -- set once a (stubbed, format-only) test-connection passes
  last_poll_at          timestamptz,       -- populated once a real background poller exists (not built this pass)
  last_poll_status      text,
  created_at            timestamptz not null default now(),
  unique (profile_id, email)
);

-- Matches 0011_rls_policies.sql's real convention: identity is verified by
-- auth/ (this app's own JWT service), not Supabase auth, so ownership is
-- checked via pandapay.uid() (reads the app.user_id session var the backend
-- sets per-request), not the Supabase-specific auth.uid().
alter table imap_connections enable row level security;
alter table imap_connections force row level security;

create policy imap_connections_owner on imap_connections
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());
