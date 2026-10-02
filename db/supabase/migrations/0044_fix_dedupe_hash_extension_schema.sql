-- >>> MIGRATION 0044 — QUALIFY PGCRYPTO DIGEST ================================
-- Supabase installs pgcrypto functions in the extensions schema.  The app
-- connection role does not include that schema in search_path, so an
-- unqualified digest() call fails when the transaction dedupe trigger runs.
create or replace function pandapay.dedupe_hash(
  p_card uuid, p_amount numeric, p_merchant text, p_when timestamptz
) returns text language sql immutable as $$
  select encode(extensions.digest(
    coalesce(p_card::text,'-') || '|' ||
    to_char(round(p_amount, 0), 'FM9999999999') || '|' ||
    lower(regexp_replace(coalesce(p_merchant,''), '[^a-z0-9]', '', 'gi')) || '|' ||
    to_char(p_when at time zone 'Asia/Kolkata', 'YYYY-MM-DD'),
    'sha256'), 'hex');
$$;
