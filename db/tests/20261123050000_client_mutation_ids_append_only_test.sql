-- WP-S5 (migration 20261123050000): client_mutation_id makes append-only inserts
-- idempotent. Synthetic data only. Run with `psql -v ON_ERROR_STOP=1` on a fully
-- migrated scratch database; everything is rolled back.
\set ON_ERROR_STOP on
begin;

insert into profiles (id) values ('11110000-0000-0000-0000-0000000000c1') on conflict do nothing;

-- Columns and partial unique indexes exist.
do $$
declare t text;
begin
  foreach t in array array['notifications', 'user_consents', 'sms_import_batches'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t
                      and column_name = 'client_mutation_id' and data_type = 'uuid' and is_nullable = 'YES') then
      raise exception '% .client_mutation_id missing', t;
    end if;
  end loop;
  if (select count(*) from pg_indexes where indexname in
        ('idx_notifications_client_mutation', 'idx_user_consents_client_mutation',
         'idx_sms_import_batches_client_mutation')) <> 3 then
    raise exception 'client mutation indexes missing';
  end if;
end $$;

-- Consents: rows without an id are never deduplicated; the same id inserts once
-- and ON CONFLICT DO NOTHING returns no row on the replay.
do $$
declare
  p uuid := '11110000-0000-0000-0000-0000000000c1';
  m uuid := '66666666-6666-4666-8666-666666666666';
  n int;
begin
  insert into user_consents (profile_id, purpose, policy_version, granted) values (p, 'terms', 'v1', true);
  insert into user_consents (profile_id, purpose, policy_version, granted) values (p, 'terms', 'v1', true);
  select count(*) into n from user_consents where profile_id = p; if n <> 2 then raise exception 'null ids must not dedupe'; end if;

  insert into user_consents (profile_id, purpose, policy_version, granted, client_mutation_id) values (p, 'terms', 'v1', true, m);
  insert into user_consents (profile_id, purpose, policy_version, granted, client_mutation_id) values (p, 'terms', 'v1', true, m)
    on conflict (profile_id, client_mutation_id) where client_mutation_id is not null do nothing;
  select count(*) into n from user_consents where profile_id = p and client_mutation_id = m;
  if n <> 1 then raise exception 'replayed consent inserted twice'; end if;
end $$;

-- Notifications: a replay with the same mutation id must not reset read_at / created_at.
do $$
declare
  p uuid := '11110000-0000-0000-0000-0000000000c1';
  m uuid := '77777777-7777-4777-8777-777777777777';
  r timestamptz;
  c timestamptz;
begin
  insert into notifications (profile_id, category, severity, title, client_mutation_id, created_at)
    values (p, 'caps', 'info', 'T', m, now() - interval '1 day');
  update notifications set read_at = now() where profile_id = p and client_mutation_id = m;
  insert into notifications (profile_id, category, severity, title, client_mutation_id)
    values (p, 'caps', 'info', 'T', m) on conflict do nothing;
  select read_at, created_at into r, c from notifications where profile_id = p and client_mutation_id = m;
  if r is null then raise exception 'replay reset read_at'; end if;
  if c > now() - interval '23 hours' then raise exception 'replay reset created_at'; end if;
end $$;

-- Import batches dedupe on the same key.
do $$
declare
  p uuid := '11110000-0000-0000-0000-0000000000c1';
  m uuid := '88888888-8888-4888-8888-888888888888';
  n int;
begin
  insert into sms_import_batches (profile_id, message_count, client_mutation_id) values (p, 1, m);
  insert into sms_import_batches (profile_id, message_count, client_mutation_id) values (p, 1, m) on conflict do nothing;
  select count(*) into n from sms_import_batches where profile_id = p and client_mutation_id = m;
  if n <> 1 then raise exception 'replayed batch inserted twice'; end if;
end $$;

rollback;
