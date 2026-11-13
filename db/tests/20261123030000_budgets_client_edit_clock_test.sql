-- WP-S3 (migration 20261123030000): budgets.client_edited_at exists, is nullable,
-- and the one-active-per-target index still holds. Synthetic data only.
-- Run with `psql -v ON_ERROR_STOP=1` on a fully migrated scratch database.
\set ON_ERROR_STOP on
begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'budgets'
                    and column_name = 'client_edited_at'
                    and data_type = 'timestamp with time zone' and is_nullable = 'YES') then
    raise exception 'budgets.client_edited_at missing or wrong type';
  end if;
  if not exists (select 1 from pg_indexes where indexname = 'idx_budgets_one_active_per_target') then
    raise exception 'idx_budgets_one_active_per_target missing';
  end if;
end $$;

-- Two ACTIVE budgets for one target still collide; an inactive history row does not.
do $$
declare
  v_profile uuid := '11110000-0000-0000-0000-0000000000b1';
begin
  insert into profiles (id) values (v_profile) on conflict do nothing;
  insert into budgets (profile_id, scope, period, amount_inr, client_edited_at)
    values (v_profile, 'overall', 'monthly', 100, '2026-11-02T10:00:00Z');
  insert into budgets (profile_id, scope, period, amount_inr, is_active, client_edited_at)
    values (v_profile, 'overall', 'monthly', 50, false, '2026-11-01T10:00:00Z');
  begin
    insert into budgets (profile_id, scope, period, amount_inr)
      values (v_profile, 'overall', 'monthly', 70);
    raise exception 'second active budget was accepted';
  exception when unique_violation then null;
  end;
end $$;

rollback;
