-- Creates the non-superuser role api/ (and the console) should actually
-- connect as. `postgres` is a superuser and BYPASSES ROW LEVEL SECURITY
-- ENTIRELY (rolbypassrls = true by default for superusers, regardless of
-- FORCE ROW LEVEL SECURITY on the tables) — connecting as `postgres` makes
-- every RLS policy in 0011_rls_policies.sql a no-op. This was discovered
-- partway through development: earlier "RLS isolation proven" testing was
-- actually only exercising the API's `WHERE id = $1` filter, not Postgres
-- RLS, because api/ was connecting as `postgres`. Run this once per
-- database, then point DATABASE_URL at `app_user`, not `postgres`.
-- Password comes from the APP_USER_PASSWORD environment variable this psql
-- process was started with, falling back to the dev literal only when unset —
-- so `docker compose up`'s existing invocation (which never sets it) is
-- unaffected, while db/scripts/migrate.sh (used for staging/prod) requires
-- the caller to set a real generated password before it will run at all. This
-- is the fix for the "production: use a real generated password" comment
-- below, which previously had no mechanism to act on it.
-- Deliberately NOT inside a `do $$ ... $$` block: psql only substitutes
-- `:'var'` in top-level statement text, not inside dollar-quoted bodies — an
-- earlier version of this file put the `create role` inside `do $$ ... $$`
-- and the substitution silently never happened, sending the literal text
-- `:'app_user_password'` to the server as a syntax error. `\if`/`\gset` keep
-- the conditional at the psql meta-command level instead, so the `create
-- role` statement itself stays a plain top-level statement.
\set app_user_password `echo "${APP_USER_PASSWORD:-app_user_dev_pw}"`

select exists (select 1 from pg_roles where rolname = 'app_user') as app_user_exists \gset
\if :app_user_exists
\echo 'app_user already exists, skipping create'
\else
create role app_user login password :'app_user_password' nosuperuser nobypassrls;
\endif

grant usage on schema public to app_user;
grant select, insert, update, delete on all tables in schema public to app_user;
grant usage, select on all sequences in schema public to app_user;
grant execute on all functions in schema public to app_user;
alter default privileges in schema public grant select, insert, update, delete on tables to app_user;

-- The `pandapay` schema is created by migration 0001, so on a brand-new
-- database this script necessarily runs BEFORE it exists — and the role has to
-- exist first, because migration 0024 ends with `grant ... to app_user`. That
-- ordering makes this script genuinely run twice: once to create the role,
-- once after the migrations to grant on what they created.
--
-- Guarded rather than unconditional because an ungated `grant usage on schema
-- pandapay` raises `schema "pandapay" does not exist` on that first run, which
-- under `psql -v ON_ERROR_STOP=1` is fatal. That is not hypothetical: it broke
-- `docker compose up` outright, and the CI workflow's first invocation had the
-- same flaw. Skipping quietly here is correct — the second run does the work,
-- and a fresh database legitimately has nothing to grant on yet.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'pandapay') then
    execute 'grant usage on schema pandapay to app_user';
    execute 'grant execute on all functions in schema pandapay to app_user';
  else
    raise notice 'schema "pandapay" not present yet — re-run this script after the migrations';
  end if;
end $$;

-- Production: use a real generated password via your secrets manager, never
-- this literal. This file is for local/dev reproducibility only.
