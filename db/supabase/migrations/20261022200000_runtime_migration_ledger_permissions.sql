-- Runtime requests have no reason to read or modify migration history.
-- The canonical role bootstrap repeats this restriction after broad grants.
do $$
begin
  -- The canonical Node migration runner creates the ledger before applying
  -- this file. Raw migration audits apply SQL files directly, though, so the
  -- ledger may not exist yet on their clean database.
  if to_regclass('public.schema_migrations') is not null then
    execute 'revoke all on table public.schema_migrations from public';
    if exists (select 1 from pg_roles where rolname = 'app_user') then
      execute 'revoke all on table public.schema_migrations from app_user';
    end if;
  end if;
end $$;
