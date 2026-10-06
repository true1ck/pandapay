-- Keep local Postgres compatible with Supabase's extensions schema.
-- Older PandaPay volumes may have recorded migration 0001 before this
-- compatibility schema was added, so the later dedupe migrations need to
-- repair it before they reference extensions.digest(...).
create schema if not exists extensions;
create extension if not exists "pgcrypto";

do $$
begin
  if to_regprocedure('extensions.digest(text,text)') is null
     and to_regprocedure('public.digest(text,text)') is not null then
    execute $sql$
      create function extensions.digest(data text, type text)
      returns bytea
      language sql immutable strict
      as 'select public.digest($1, $2)'
    $sql$;
  end if;
end $$;
