-- Fresh-start release (decision D5): server-escrowed account recovery is
-- removed. The API routes (/account/recovery/*), the wrapping-key
-- configuration and the account_recovery schema created by
-- 20261023192644_account_recovery_escrow.sql and
-- 20261025140000_automatic_account_recovery.sql are gone. Nothing else in the
-- product reads or writes them: the account lifecycle functions never
-- referenced the schema, they only carried a trigger and a policy installed
-- by the recovery migrations, which are removed below.
--
-- The phone-side passphrase file export/import is unrelated and untouched.
--
-- Escrowed ciphertext and wrapped keys are deleted with the tables. The
-- release starts from an empty product database, and recovery was switched
-- off in every environment, so no live rows are expected.
--
-- No CASCADE: if anything unexpected still depends on these objects, the
-- migration fails instead of removing it silently.

-- Hooks the recovery migrations placed on the account lifecycle tombstones.
drop trigger if exists clear_deleted_automatic_consent on account_lifecycle.tombstones;
drop policy if exists lifecycle_recovery_read on account_lifecycle.tombstones;

-- Functions (every overload that migration created, none are used elsewhere).
drop function if exists account_recovery.clear_deleted_automatic_consent();
drop function if exists account_recovery.read_automatic_ciphertext(uuid, text, uuid);
drop function if exists account_recovery.put_automatic_snapshot(uuid, text, uuid, uuid, bytea, text, bytea, text, boolean, boolean, text);
drop function if exists account_recovery.get_automatic(uuid, text);
drop function if exists account_recovery.set_automatic(uuid, text, boolean, boolean);
drop function if exists account_recovery.remove_snapshots(uuid);
drop function if exists account_recovery.list_snapshots(uuid);
drop function if exists account_recovery.read_snapshot(uuid, uuid);
drop function if exists account_recovery.put_snapshot(uuid, uuid, bytea, text, bytea, text, boolean, boolean, text);
drop function if exists account_recovery.assert_account(uuid);

-- Tables, then the now empty schema.
drop table if exists account_recovery.automatic_devices;
drop table if exists account_recovery.snapshots;
drop table if exists account_recovery.control;
drop schema if exists account_recovery;

-- The private owner role and the grants it was given on shared objects.
do $$
begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'account_recovery_owner') then
    revoke select (profile_id) on account_lifecycle.tombstones from account_recovery_owner;
    revoke references (id) on public.profiles from account_recovery_owner;
    revoke usage on schema public, pandapay, account_lifecycle from account_recovery_owner;
    revoke execute on function pandapay.uid() from account_recovery_owner;
    execute pg_catalog.format('revoke connect on database %I from account_recovery_owner', pg_catalog.current_database());
    drop role account_recovery_owner;
  end if;
end $$;
