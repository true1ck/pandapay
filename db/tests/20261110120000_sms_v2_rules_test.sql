-- SMS v2 rule service (WP-09). Disposable fully-migrated local PG fixture.
-- Synthetic ids only; every row is rolled back.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as admin_id, gen_random_uuid()::text as p1, gen_random_uuid()::text as p2,
       gen_random_uuid()::text as tester \gset
insert into profiles(id) values (:'admin_id'::uuid), (:'p1'::uuid), (:'p2'::uuid), (:'tester'::uuid);
insert into admin_users(id, is_active) values (:'admin_id'::uuid, true);

-- Admin writes rule data and a bundle; the tester is registered.
set local role app_user;
select set_config('app.user_id', :'admin_id', true);
insert into sms_v2_rules(rule_id, version, status, family, senders, body, created_by)
  values ('R-1', 1, 'active', 'card_spend', '{HDFCBK}', '{"id":"R-1"}', 'baseline');
insert into sms_v2_rule_cohorts(rule_id, version, cohort) values ('R-1', 1, 'all');
insert into sms_v2_bundles(bundle_version, manifest, sha256, signature, key_id, cohort, status, body)
  values (1, '{"R-1":1}', 'sha', 'sig', 'k', 'all', 'active', '{"bundleVersion":1}'),
         (2, '{"R-1":1}', 'sha', 'sig', 'k', 'testers', 'active', '{"bundleVersion":2}');
insert into sms_v2_testers(profile_id) values (:'tester'::uuid);
do $$ begin
  begin
    insert into sms_v2_rules(rule_id, version, status, family, body, created_by) values ('R-2', 1, 'bogus', 'f', '{}', 'x');
    raise exception 'status check missing';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_rule_cohorts(rule_id, version, cohort) values ('R-1', 1, 'everyone');
    raise exception 'cohort check missing';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_rule_cohorts(rule_id, version, cohort) values ('R-9', 1, 'all');
    raise exception 'foreign key missing';
  exception when foreign_key_violation then null; end;
end $$;

-- A normal profile cannot read or write any rule table.
select set_config('app.user_id', :'p1', true);
do $$ declare n int; begin
  foreach n in array array[1] loop
    if (select count(*) from sms_v2_rules) <> 0 then raise exception 'rules visible to non-admin'; end if;
    if (select count(*) from sms_v2_bundles) <> 0 then raise exception 'bundles visible to non-admin'; end if;
    if (select count(*) from sms_v2_testers) <> 0 then raise exception 'testers visible to non-admin'; end if;
    if (select count(*) from sms_v2_rule_cohorts) <> 0 then raise exception 'cohorts visible to non-admin'; end if;
  end loop;
  begin
    insert into sms_v2_rules(rule_id, version, status, family, body, created_by) values ('R-X', 1, 'draft', 'f', '{}', 'x');
    raise exception 'non-admin insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into sms_v2_rule_stats_daily(day, rule_id, rule_version, app_version) values (current_date, 'R-1', 1, '1');
    raise exception 'non-admin daily stats insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into sms_v2_rule_stats_profile_daily(day, profile_id, rule_id, rule_version, app_version)
      values (current_date, pandapay.uid(), 'R-1', 1, '1');
    raise exception 'direct profile stats insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform pandapay.sms_v2_rollup_rule_stats();
    raise exception 'rollup open to non-admin';
  exception when others then
    if sqlerrm = 'rollup open to non-admin' then raise; end if;
  end;
end $$;

-- Phone-facing functions work for a normal profile.
do $$ begin
  if pandapay.sms_v2_is_tester() then raise exception 'p1 is not a tester'; end if;
  if (select bundle_version from pandapay.sms_v2_latest_bundle('all')) <> 1 then raise exception 'latest bundle all'; end if;
  if (select bundle_version from pandapay.sms_v2_latest_bundle('testers')) <> 2 then raise exception 'latest bundle testers'; end if;
  if exists (select 1 from pandapay.sms_v2_latest_bundle('pct5')) then raise exception 'unexpected pct5 bundle'; end if;
end $$;
select set_config('app.user_id', :'tester', true);
do $$ begin
  if not pandapay.sms_v2_is_tester() then raise exception 'tester not recognised'; end if;
end $$;

-- Stats go in through the security-definer function, once per profile and key.
select set_config('app.user_id', :'p1', true);
select pandapay.sms_v2_record_rule_stats(current_date, '1.0.0',
  '[{"rule_id":"R-1","rule_version":1,"hits":5,"to_review":1,"corrected":0}]'::jsonb);
select pandapay.sms_v2_record_rule_stats(current_date, '1.0.0',
  '[{"rule_id":"R-1","rule_version":1,"hits":8,"to_review":2,"corrected":1}]'::jsonb);   -- replaces
select set_config('app.user_id', :'p2', true);
select pandapay.sms_v2_record_rule_stats(current_date, '1.0.0',
  '[{"rule_id":"R-1","rule_version":1,"hits":4,"to_review":0,"corrected":0}]'::jsonb);
do $$ begin
  -- a day outside the 48 hour window is ignored
  if pandapay.sms_v2_record_rule_stats(current_date - 5, '1.0.0',
       '[{"rule_id":"R-1","rule_version":1,"hits":99,"to_review":0,"corrected":0}]'::jsonb) <> 0 then
    raise exception 'old day accepted';
  end if;
end $$;

-- Rollup (admin): hits summed, distinct profiles counted, old profile rows trimmed.
select set_config('app.user_id', :'admin_id', true);
reset role;
insert into sms_v2_rule_stats_profile_daily(day, profile_id, rule_id, rule_version, app_version, hits)
  values (current_date - 4, :'p1'::uuid, 'R-1', 1, '1.0.0', 3);
set local role app_user;
select set_config('app.user_id', :'admin_id', true);
select pandapay.sms_v2_rollup_rule_stats();
select pandapay.sms_v2_rollup_rule_stats();   -- idempotent
do $$ declare r record; begin
  select * into r from sms_v2_rule_stats_daily where day = current_date and rule_id = 'R-1';
  if r.hits <> 12 or r.to_review <> 2 or r.corrected <> 1 or r.devices <> 2 then
    raise exception 'rollup wrong: % % % %', r.hits, r.to_review, r.corrected, r.devices;
  end if;
  if exists (select 1 from sms_v2_rule_stats_profile_daily where day < current_date - 2) then
    raise exception 'profile rows older than 48h kept';
  end if;
  if (select count(*) from sms_v2_rule_stats_profile_daily) <> 2 then raise exception 'recent profile rows lost'; end if;
end $$;

rollback;
