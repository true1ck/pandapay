-- >>> MIGRATION 0025 — PROFILE PHONE NUMBER =================================
--
-- Design 22 "Email & phone" shows both identifiers side by side, but only
-- the email was ever readable from the product database: the phone is
-- collected by login_screen.dart, sent to auth/'s verify-email-otp, and
-- stored in auth/'s own users table — a separate database this API cannot
-- join against. GET /profile therefore had nothing to return, and the
-- screen could only ever say "Not on file".
--
-- Storing a copy here is a denormalisation, deliberately: auth/ remains the
-- system of record for authentication, and this column is display/matching
-- data only. In particular it is NOT a credential and must never be used to
-- authenticate anything — see the `verified` note below.
--
-- No `phone_verified` column. auth/ has no verify-phone endpoint, so there
-- is no code path that could ever set it to true honestly, and a column
-- that is structurally always false is worse than no column: it invites a
-- future reader to treat "false" as a real negative signal rather than as
-- "never asked". The UI states "Unverified" from the absence of any
-- verification mechanism, not from a stored flag.

alter table profiles
  add column if not exists phone_number text;

comment on column profiles.phone_number is
  'Display/SMS-matching copy of the phone collected at sign-up. auth/ is the '
  'system of record. NEVER verified — auth/ has no verify-phone flow — so it '
  'must not be used as an authentication or account-recovery factor.';
