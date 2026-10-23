-- Runtime requests have no reason to read or modify migration history.
-- The canonical role bootstrap repeats this restriction after broad grants.
revoke all on table public.schema_migrations from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    revoke all on table public.schema_migrations from app_user;
  end if;
end $$;
