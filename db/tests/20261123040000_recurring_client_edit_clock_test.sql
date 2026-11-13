-- WP-S4 (migration 20261123040000): recurring_series.client_edited_at exists and is nullable.
-- Run with `psql -v ON_ERROR_STOP=1` on a fully migrated scratch database.
\set ON_ERROR_STOP on
begin;
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'recurring_series'
                    and column_name = 'client_edited_at'
                    and data_type = 'timestamp with time zone' and is_nullable = 'YES') then
    raise exception 'recurring_series.client_edited_at missing or wrong type';
  end if;
end $$;
rollback;
