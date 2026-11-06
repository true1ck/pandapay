-- Managed PostgreSQL 16+ (Supabase): a migration login that has CREATEROLE but
-- is not a superuser cannot make a role it created own objects
-- (CREATE SCHEMA ... AUTHORIZATION, ALTER TABLE ... OWNER TO) unless it may
-- SET ROLE to that role. 20261112210000_shared_expenses_foundation.sql and the
-- later shared_expense migrations do exactly that with shared_expenses_owner,
-- so create the role here with the same attributes and let the migration login
-- act as it, as 20261028150000_account_data_reset.sql does for promotions_owner.
-- On a superuser database pg_has_role is already true and nothing is granted.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'shared_expenses_owner') THEN
    CREATE ROLE shared_expenses_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
  END IF;
  IF NOT pg_has_role(current_user, 'shared_expenses_owner', 'SET') THEN
    EXECUTE 'GRANT shared_expenses_owner TO current_user WITH SET TRUE';
  END IF;
END $$;
