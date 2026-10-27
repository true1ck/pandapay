-- Creates the non-superuser roles used by api/, the isolated rewards worker,
-- and the autonomous SMS learner. `postgres` is a superuser and BYPASSES ROW LEVEL SECURITY
-- ENTIRELY (rolbypassrls = true by default for superusers, regardless of
-- FORCE ROW LEVEL SECURITY on the tables) — connecting as `postgres` makes
-- every RLS policy in 0011_rls_policies.sql a no-op. This was discovered
-- partway through development: earlier "RLS isolation proven" testing was
-- actually only exercising the API's `WHERE id = $1` filter, not Postgres
-- RLS, because api/ was connecting as `postgres`. Run this once per
-- database, then point api/ at `app_user`, not `postgres`; rewards-worker
-- uses its separate `rewards_worker_login` credential.
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
\set rewards_worker_password `echo "${REWARD_WORKER_DB_PASSWORD:-reward_worker_dev_pw}"`
-- The autonomous SMS learner is opt-in: when SMS_LEARNING_WORKER_DB_PASSWORD
-- is unset the dedicated login is neither created nor rotated (a blank password
-- must never become a role credential), and the grants to it below are skipped.
-- Dev and CI compose always set the variable; a production host sets it when
-- actually enabling the sms-learning worker profile.
\set sms_learning_worker_password `echo "${SMS_LEARNING_WORKER_DB_PASSWORD:-}"`

select exists (select 1 from pg_roles where rolname = 'app_user') as app_user_exists \gset
\if :app_user_exists
\echo 'app_user already exists, skipping create'
\else
create role app_user login password :'app_user_password' nosuperuser nobypassrls;
\endif

select exists (select 1 from pg_roles where rolname = 'rewards_worker_login') as rewards_worker_login_exists \gset
\if :rewards_worker_login_exists
-- The role already exists, so only the credential is rotated here. Restating
-- the security attributes ("nosuperuser", "nobypassrls") is refused with
-- "permission denied to alter role" for a deploy admin that has CREATEROLE
-- but not SUPERUSER — "Only roles with the SUPERUSER attribute may change the
-- SUPERUSER attribute" — which failed every deploy after the role's first
-- creation. The attributes are already the ones this file creates, and only a
-- superuser can change them anyway. The password is passed through a session
-- setting because psql does not substitute variables inside a dollar-quoted
-- body.
select set_config('pandapay.rewards_worker_password', :'rewards_worker_password', false);
do $$
begin
  begin
    execute format(
      'alter role rewards_worker_login login password %L',
      current_setting('pandapay.rewards_worker_password')
    );
  exception when insufficient_privilege then
    raise notice 'rewards_worker_login exists; this admin role cannot rotate its password (that needs SUPERUSER). Keeping the existing credentials — rotate them with a superuser if the host password changed.';
  end;
end $$;
\else
create role rewards_worker_login login password :'rewards_worker_password'
  nosuperuser nocreatedb nocreaterole inherit noreplication nobypassrls;
\endif

select exists (select 1 from pg_roles where rolname = 'sms_learning_worker') as sms_learning_worker_exists \gset
select length(:'sms_learning_worker_password') > 0 as sms_learning_worker_password_set \gset
\if :sms_learning_worker_password_set
-- Keep the deployment idempotent and rotate the dedicated login credential
-- when the administering role owns it. Managed Postgres deploy roles may have
-- CREATEROLE without being allowed to alter a role created by a superuser, so
-- retain the same safe retry behavior as rewards_worker_login above.
\if :sms_learning_worker_exists
select set_config('pandapay.sms_learning_worker_password', :'sms_learning_worker_password', false);
do $$
begin
  begin
    execute format(
      'alter role sms_learning_worker login password %L',
      current_setting('pandapay.sms_learning_worker_password')
    );
  exception when insufficient_privilege then
    raise notice 'sms_learning_worker exists; this admin role cannot rotate its password. Keeping the existing credential; rotate it with the role owner if the host password changed.';
  end;
end $$;
\else
create role sms_learning_worker login password :'sms_learning_worker_password'
  nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
\endif
\else
\echo 'SMS_LEARNING_WORKER_DB_PASSWORD not set; skipping sms_learning_worker bootstrap (learner disabled)'
\endif

\if :sms_learning_worker_exists
grant usage on schema public to sms_learning_worker;
\endif

grant usage on schema public to app_user;
grant select, insert, update, delete on all tables in schema public to app_user;
grant usage, select on all sequences in schema public to app_user;
grant execute on all functions in schema public to app_user;
alter default privileges in schema public grant select, insert, update, delete on tables to app_user;

-- Profile creation and identity fields must go through the trusted auth /
-- promotion bootstrap routine. A blanket public-schema grant above would
-- otherwise restore direct profile insertion every time this script runs.
do $$
begin
  if to_regclass('public.profiles') is not null then
    execute 'revoke insert, update, delete on table public.profiles from app_user';
    execute 'grant update (contributions_opt_in, deletion_requested_at, deletion_due_at) on table public.profiles to app_user';
  end if;

  -- Existing referral endpoints retain read compatibility; creating a code,
  -- attribution or qualification is now done through narrowly granted
  -- promotions SECURITY DEFINER routines.
  if to_regclass('public.referral_codes') is not null then
    execute 'revoke insert, update, delete on table public.referral_codes from app_user';
    execute 'grant select on table public.referral_codes to app_user';
  end if;
  if to_regclass('public.referrals') is not null then
    execute 'revoke insert, update, delete on table public.referrals from app_user';
    execute 'grant select on table public.referrals to app_user';
  end if;
  if to_regclass('public.referral_program') is not null then
    execute 'revoke insert, update, delete on table public.referral_program from app_user';
    execute 'grant select on table public.referral_program to app_user';
  end if;

  -- Autonomous SMS learner health history is written only by its dedicated
  -- worker login; the blanket public-schema grant above would otherwise give
  -- the app role write access that the worker-health migration narrowed to
  -- read-only. Mirrors that migration's `grant select ... to app_user`.
  if to_regclass('public.sms_learning_worker_runs') is not null then
    execute 'revoke insert, update, delete on table public.sms_learning_worker_runs from app_user';
    execute 'grant select on table public.sms_learning_worker_runs to app_user';
  end if;
end $$;

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
declare
  -- Newer plans may run with the learner disabled (no dedicated login);
  -- granting to an absent role would be fatal, so gate every sms_learning_worker
  -- grant on its existence while keeping the app_user side unconditional.
  worker_role_exists boolean := exists (select 1 from pg_roles where rolname = 'sms_learning_worker');
begin
  if exists (select 1 from pg_namespace where nspname = 'pandapay') then
    execute 'grant usage on schema pandapay to app_user';
    execute 'grant execute on all functions in schema pandapay to app_user';
    if worker_role_exists then
      execute 'grant usage on schema pandapay to sms_learning_worker';
    end if;

    -- Publishing and autonomous rollback are reserved for the authenticated
    -- admin API. This script is re-run AFTER the migrations by
    -- db/scripts/migrate.sh, so it must converge on the same policy that
    -- 20261027160000_sms_category_rule_approval.sql revokes: granting these
    -- back to the worker here both re-opened the global publication gate and
    -- made sms_autonomous_worker's own capability check refuse to start (it
    -- requires can_publish and can_rollback to be false).
    if to_regprocedure('pandapay.sms_publish_bundle(integer,jsonb,text,text)') is not null then
      execute 'revoke execute on function pandapay.sms_publish_bundle(integer, jsonb, text, text) from app_user';
      if worker_role_exists then
        execute 'revoke execute on function pandapay.sms_publish_bundle(integer, jsonb, text, text) from sms_learning_worker';
      end if;
    end if;
    if to_regprocedure('pandapay.sms_rollback_bundle(integer)') is not null then
      execute 'revoke execute on function pandapay.sms_rollback_bundle(integer) from app_user';
      if worker_role_exists then
        execute 'revoke execute on function pandapay.sms_rollback_bundle(integer) from sms_learning_worker';
      end if;
    end if;
  else
    raise notice 'schema "pandapay" not present yet — re-run this script after the migrations';
  end if;
end $$;

-- These objects arrive in the later SMS-learning migrations. Keeping their
-- grants in the rerunnable role setup repairs an installation where a prior
-- conditional migration ran before the worker role existed. When the learner
-- is disabled (no password), re-running this script after enabling it does
-- the same repair.
do $$
begin
  -- No dedicated login -> nothing to grant to; granting to an absent role is
  -- fatal, so bail out early.
  if not exists (select 1 from pg_roles where rolname = 'sms_learning_worker') then
    return;
  end if;
  if to_regclass('public.sms_learning_examples') is not null then
    execute 'grant select on table public.sms_learning_examples to sms_learning_worker';
  end if;
  if to_regclass('public.sms_rule_candidates') is not null then
    execute 'grant select, insert, update on table public.sms_rule_candidates to sms_learning_worker';
  end if;
  if to_regclass('public.sms_rule_candidate_exposures') is not null then
    execute 'grant select on table public.sms_rule_candidate_exposures to sms_learning_worker';
  end if;
  if to_regclass('public.sms_rule_bundles') is not null then
    execute 'grant select on table public.sms_rule_bundles to sms_learning_worker';
  end if;
  if to_regclass('public.sms_learning_worker_runs') is not null then
    execute 'grant select, insert on table public.sms_learning_worker_runs to sms_learning_worker';
  end if;
end $$;

-- Production: use a real generated password via your secrets manager, never
-- this literal. This file is for local/dev reproducibility only.
