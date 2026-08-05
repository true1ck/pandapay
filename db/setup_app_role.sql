-- Creates the non-superuser role api/ (and the console) should actually
-- connect as. `postgres` is a superuser and BYPASSES ROW LEVEL SECURITY
-- ENTIRELY (rolbypassrls = true by default for superusers, regardless of
-- FORCE ROW LEVEL SECURITY on the tables) — connecting as `postgres` makes
-- every RLS policy in 0011_rls_policies.sql a no-op. This was discovered
-- partway through development: earlier "RLS isolation proven" testing was
-- actually only exercising the API's `WHERE id = $1` filter, not Postgres
-- RLS, because api/ was connecting as `postgres`. Run this once per
-- database, then point DATABASE_URL at `app_user`, not `postgres`.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'app_user') then
    create role app_user login password 'app_user_dev_pw' nosuperuser nobypassrls;
  end if;
end $$;

grant usage on schema public to app_user;
grant select, insert, update, delete on all tables in schema public to app_user;
grant usage, select on all sequences in schema public to app_user;
grant execute on all functions in schema pandapay to app_user;
grant execute on all functions in schema public to app_user;
alter default privileges in schema public grant select, insert, update, delete on tables to app_user;

-- Production: use a real generated password via your secrets manager, never
-- this literal. This file is for local/dev reproducibility only.
