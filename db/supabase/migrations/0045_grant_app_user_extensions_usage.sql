-- >>> MIGRATION 0045 — ALLOW APP ROLE TO CALL PGCRYPTO ========================
-- The transaction dedupe trigger calls pgcrypto's digest() explicitly from
-- the extensions schema.  app_user already has EXECUTE on the function, but
-- PostgreSQL also requires USAGE on the schema before a non-owner can resolve
-- a qualified function name.
grant usage on schema extensions to app_user;
