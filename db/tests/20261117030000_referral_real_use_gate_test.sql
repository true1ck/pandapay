-- Disposable-DB test for the referral "reward only after real use" gate
-- (migration 20261117030000_referral_real_use_gate.sql). Run in a fresh migrated
-- database, after the permission and journey tests. Everything rolls back.
--
-- With campaign_versions.real_use_required_days = 0 (the default) a referee still
-- qualifies by opening the app on the required consecutive days. With it > 0 they
-- also need that many distinct local days with a live, parsed (sms or email)
-- spend entry that reached the server inside their window.
--
-- psql does not substitute :'variables' inside $$ bodies, so checks on psql
-- values go through pg_temp.expect() at the top level.
\set ON_ERROR_STOP on

begin;

select gen_random_uuid()::text as inviter_id,
       'fixture-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) as campaign_version
\gset
select set_config('test.campaign_version', :'campaign_version', true);
select set_config('test.invite_code',
       'PANDA-' || upper(substr(replace(:'inviter_id', '-', ''), 1, 12)), true);

create function pg_temp.expect(p_ok boolean, p_message text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception '%', p_message;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Structure: off by default, bounded, nothing shipped with it on, locked down.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from promotions.campaign_versions
              where real_use_required_days <> 0 and version_key not like 'fixture-%') then
    raise exception 'a campaign version came out of the migration with the real-use gate switched on';
  end if;

  begin
    insert into promotions.campaign_versions
      (version_key, calendar_zone, required_consecutive_days, qualification_window_days,
       receipt_lifetime_seconds, terms_version, prize_distribution, real_use_required_days)
    values ('fixture-too-many', 'Asia/Kolkata', 3, 30, 300, 't',
            '{"inviter":[{"id":"zero","amountPaise":"0","weight":100}],"referee":[{"id":"zero","amountPaise":"0","weight":100}]}',
            31);
    raise exception 'real_use_required_days = 31 was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into promotions.campaign_versions
      (version_key, calendar_zone, required_consecutive_days, qualification_window_days,
       receipt_lifetime_seconds, terms_version, prize_distribution, real_use_required_days)
    values ('fixture-negative', 'Asia/Kolkata', 3, 30, 300, 't',
            '{"inviter":[{"id":"zero","amountPaise":"0","weight":100}],"referee":[{"id":"zero","amountPaise":"0","weight":100}]}',
            -1);
    raise exception 'real_use_required_days = -1 was accepted';
  exception when check_violation then null;
  end;

  -- The counting helper is SECURITY DEFINER because promotions_owner
  -- deliberately has no grant on transactions, and is not open to PUBLIC.
  -- (db/setup_app_role.sql grants every pandapay function to app_user; that is
  -- safe because the helper has no profile argument and answers only for the
  -- caller, which the isolation check in section 5 asserts.)
  if not has_function_privilege('promotions_owner', 'pandapay.referral_real_use_days(timestamptz,timestamptz,text)', 'execute') then
    raise exception 'promotions_owner must be able to run the real-use helper';
  end if;
  if exists (
    select 1 from pg_proc p
     where p.oid = 'pandapay.referral_real_use_days(timestamptz,timestamptz,text)'::regprocedure
       and (p.proacl is null
            or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  ) then
    raise exception 'PUBLIC can execute the real-use helper';
  end if;
  if not (select prosecdef from pg_proc
           where oid = 'pandapay.referral_real_use_days(timestamptz,timestamptz,text)'::regprocedure) then
    raise exception 'the real-use helper must be SECURITY DEFINER';
  end if;
  if has_table_privilege('promotions_owner', 'public.transactions', 'select') then
    raise exception 'promotions_owner must not gain a direct grant on transactions';
  end if;
  if not has_function_privilege('app_user', 'promotions.record_engagement_day(text,text,timestamptz)', 'execute') then
    raise exception 'app_user lost execute on record_engagement_day';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: an inviter, a campaign that leaves the gate at its default (off),
-- and helpers that act as the API role would.
-- ---------------------------------------------------------------------------
insert into public.profiles (id, display_name, locale, currency, onboarding_completed_at)
values (:'inviter_id'::uuid, 'Fixture inviter', 'en-IN', 'INR', now());
insert into promotions.memberships (profile_id, state, admission_source)
values (:'inviter_id'::uuid, 'active', 'legacy');

insert into promotions.campaign_versions
  (version_key, calendar_zone, required_consecutive_days, qualification_window_days,
   receipt_lifetime_seconds, terms_version, prize_distribution)
values
  (:'campaign_version', 'Asia/Kolkata', 3, 30, 300, 'fixture-campaign-terms',
   '{"inviter":[{"id":"zero","amountPaise":"0","weight":5},{"id":"ten","amountPaise":"1000","weight":65},{"id":"fifty","amountPaise":"5000","weight":30}],'
   '"referee":[{"id":"zero","amountPaise":"0","weight":5},{"id":"ten","amountPaise":"1000","weight":65},{"id":"fifty","amountPaise":"5000","weight":30}]}');
insert into promotions.campaign_state
  (version_key, enrollment_open, fulfillment_paused, redemption_paused,
   total_budget_paise, enrollment_cap)
values (:'campaign_version', true, false, true, 100000, 10);

insert into promotions.invitation_codes (code, owner_profile_id)
values (current_setting('test.invite_code'), :'inviter_id'::uuid);
insert into public.referral_codes (profile_id, code)
values (:'inviter_id'::uuid, current_setting('test.invite_code'));
update promotions.access_settings
   set admission_mode = 'invite_only', active_campaign_version = :'campaign_version'
 where singleton;

select pg_temp.expect(
  (select real_use_required_days from promotions.campaign_versions where version_key = :'campaign_version') = 0,
  'a campaign version created without the setting must have the gate off (0)');

-- IST midnight today, as a timestamptz. All fixture dates hang off this so the
-- test gives the same answer at any time of day.
create function pg_temp.ist_midnight() returns timestamptz language sql stable as $$
  select date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
$$;

create function pg_temp.day_at(p_days_ago integer, p_hour integer) returns timestamptz language sql stable as $$
  select pg_temp.ist_midnight() - make_interval(days => p_days_ago) + make_interval(hours => p_hour)
$$;

create function pg_temp.new_referee(p_label text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  execute 'set local role app_user';
  perform set_config('app.user_id', v_id::text, true);
  perform promotions.activate_current_user(
    'Fixture ' || p_label, 'en-IN', 'INR', p_label || '@example.invalid', null,
    current_setting('test.invite_code'), current_setting('test.campaign_version'),
    'fixture-campaign-terms', true, false,
    jsonb_build_array(jsonb_build_object(
      'kind', 'email', 'keyVersion', 'test-v1',
      'fingerprint', md5(v_id::text) || md5(p_label || v_id::text))),
    'fixture-product-terms', true);
  execute 'reset role';
  -- joined at IST midnight three days ago, window open for 28 more days
  update promotions.referral_attributions
     set joined_at = pg_temp.ist_midnight() - interval '3 days',
         deadline_at = now() + interval '28 days'
   where referee_id = v_id;
  return v_id;
end
$$;

-- Two earlier app-open days (2 and 1 days ago); the third is recorded live.
create function pg_temp.seed_two_open_days(p_referee uuid) returns void language plpgsql as $$
declare
  v_version text := current_setting('test.campaign_version');
  v_a timestamptz := pg_temp.day_at(2, 12);
  v_b timestamptz := pg_temp.day_at(1, 12);
begin
  insert into promotions.engagement_days
    (profile_id, campaign_version, local_date, server_activity_at, source_action, receipt_id)
  values
    (p_referee, v_version, (v_a at time zone 'Asia/Kolkata')::date, v_a, 'home_summary', 'fixture-open-a-' || p_referee),
    (p_referee, v_version, (v_b at time zone 'Asia/Kolkata')::date, v_b, 'home_summary', 'fixture-open-b-' || p_referee);
end
$$;

-- What the app does on opening: POST /engagement/check-in as that member.
create function pg_temp.check_in(p_referee uuid, p_receipt text) returns jsonb language plpgsql as $$
declare
  v_result jsonb;
begin
  execute 'set local role app_user';
  perform set_config('app.user_id', p_referee::text, true);
  v_result := promotions.record_engagement_day(
    'fixture-check-in-' || p_receipt || '-' || p_referee, 'home_summary', now());
  execute 'reset role';
  return v_result;
end
$$;

-- A transaction row as the server would hold it. created_at is the server
-- arrival time, so the fixture sets it explicitly.
create function pg_temp.add_txn(
  p_profile uuid, p_source text, p_created timestamptz,
  p_kind text default 'spend', p_status text default 'active', p_backfill boolean default false
) returns void language plpgsql as $$
begin
  insert into public.transactions
    (profile_id, amount_inr, occurred_at, merchant_name, source, status, entry_kind, is_backfill, created_at)
  values
    (p_profile,
     100 + (select count(*) from public.transactions where profile_id = p_profile),
     p_created, 'Fixture shop',
     p_source::txn_source, p_status::txn_status, p_kind::txn_entry_kind, p_backfill, p_created);
end
$$;

create function pg_temp.qualified(p_referee uuid) returns boolean language sql stable as $$
  select qualified_at is not null from promotions.referral_attributions where referee_id = p_referee
$$;
create function pg_temp.entitlements(p_referee uuid) returns bigint language sql stable as $$
  select count(*) from promotions.reward_entitlements e
    join promotions.referral_attributions a on a.id = e.attribution_id
   where a.referee_id = p_referee
$$;
create function pg_temp.qualified_events(p_referee uuid) returns bigint language sql stable as $$
  select count(*) from promotions.reward_outbox o
    join promotions.referral_attributions a on o.event_key like ('referral:qualified:' || a.id || ':%')
   where a.referee_id = p_referee and o.event_type = 'referral.qualified'
$$;

-- ---------------------------------------------------------------------------
-- 1. Gate OFF (the default): opening the app three days in a row qualifies,
--    with no transactions at all, and the answer has exactly today's shape.
-- ---------------------------------------------------------------------------
select pg_temp.new_referee('off-open-only')::text as r1 \gset
select pg_temp.seed_two_open_days(:'r1'::uuid);
select pg_temp.check_in(:'r1'::uuid, 'off-1')::text as res \gset
select pg_temp.expect(
  (select array_agg(k order by k) from jsonb_object_keys(:'res'::jsonb) k) =
    array['activityDate', 'bestStreakDays', 'lastConfirmedAt', 'progressDays', 'qualified', 'recorded', 'requiredDays'],
  'gate off: the check-in answer changed shape: ' || :'res');
select pg_temp.expect(
  (:'res'::jsonb ->> 'qualified') = 'true' and (:'res'::jsonb ->> 'progressDays') = '3'
  and (:'res'::jsonb ->> 'bestStreakDays') = '3' and (:'res'::jsonb ->> 'recorded') = 'true',
  'gate off: three open days must still qualify, got ' || :'res');
select pg_temp.expect(
  pg_temp.qualified(:'r1'::uuid) and pg_temp.entitlements(:'r1'::uuid) = 2 and pg_temp.qualified_events(:'r1'::uuid) = 2,
  'gate off: qualification did not create two entitlements and two qualified events');

-- ---------------------------------------------------------------------------
-- 2. Gate ON (3 real-use days): the same open-only referee does NOT qualify.
-- ---------------------------------------------------------------------------
update promotions.campaign_versions set real_use_required_days = 3
 where version_key = :'campaign_version';

select pg_temp.new_referee('on-open-only')::text as r2 \gset
select pg_temp.seed_two_open_days(:'r2'::uuid);
select pg_temp.check_in(:'r2'::uuid, 'on-1')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'qualified') = 'false' and (:'res'::jsonb ->> 'progressDays') = '3'
  and (:'res'::jsonb ->> 'bestStreakDays') = '3',
  'gate on: the streak is complete but the answer must say not qualified, got ' || :'res');
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseRequiredDays') = '3' and (:'res'::jsonb ->> 'realUseDays') = '0'
  and (:'res'::jsonb ->> 'realUseMet') = 'false',
  'gate on: the answer must say what is missing, got ' || :'res');
select pg_temp.expect(
  not pg_temp.qualified(:'r2'::uuid) and pg_temp.entitlements(:'r2'::uuid) = 0 and pg_temp.qualified_events(:'r2'::uuid) = 0,
  'gate on: opening the app alone qualified a referee');
select pg_temp.expect(
  (select current_streak_days from promotions.referral_attributions where referee_id = :'r2'::uuid) = 3,
  'gate on: the streak itself must still be recorded');

-- ---------------------------------------------------------------------------
-- 3. Rows that must NOT count, in every way the rule excludes. The referee is
--    still held back and the answer reports 0 real-use days.
-- ---------------------------------------------------------------------------
-- typed in by hand, on three days
select pg_temp.add_txn(:'r2'::uuid, 'manual', pg_temp.day_at(2, 13));
select pg_temp.add_txn(:'r2'::uuid, 'manual', pg_temp.day_at(1, 13));
select pg_temp.add_txn(:'r2'::uuid, 'manual', pg_temp.day_at(0, 0));
-- statement, CSV and bulk imports
select pg_temp.add_txn(:'r2'::uuid, 'statement', pg_temp.day_at(2, 14));
select pg_temp.add_txn(:'r2'::uuid, 'imported', pg_temp.day_at(1, 14));
select pg_temp.add_txn(:'r2'::uuid, 'sms_bulk', pg_temp.day_at(0, 0));
-- a history scan flagged as backfill
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(2, 15), 'spend', 'active', true);
select pg_temp.add_txn(:'r2'::uuid, 'email', pg_temp.day_at(1, 15), 'spend', 'active', true);
-- parsed and live, but not spend
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(2, 16), 'income');
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(1, 16), 'transfer');
-- parsed and live, but ignored or deleted
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(2, 17), 'spend', 'ignored');
select pg_temp.add_txn(:'r2'::uuid, 'email', pg_temp.day_at(1, 17), 'spend', 'deleted');
-- parsed and live, but outside the window: just before joining, and at the deadline
select pg_temp.add_txn(:'r2'::uuid, 'sms',
  (select joined_at - interval '1 second' from promotions.referral_attributions where referee_id = :'r2'::uuid));
select pg_temp.add_txn(:'r2'::uuid, 'sms',
  (select deadline_at from promotions.referral_attributions where referee_id = :'r2'::uuid));
-- another member's live parsed rows (the gate-off referee's) never help this one
select pg_temp.add_txn(:'r1'::uuid, 'sms', pg_temp.day_at(2, 13));
select pg_temp.add_txn(:'r1'::uuid, 'sms', pg_temp.day_at(1, 13));
select pg_temp.add_txn(:'r1'::uuid, 'sms', pg_temp.day_at(0, 0));

select pg_temp.check_in(:'r2'::uuid, 'on-2')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '0' and (:'res'::jsonb ->> 'qualified') = 'false'
  and not pg_temp.qualified(:'r2'::uuid),
  'manual, import, backfill, non-spend, ignored, out-of-window or other users'' rows counted as real use: ' || :'res');

-- ---------------------------------------------------------------------------
-- 4. Rows that DO count. Distinct days, not rows: two on one day count once.
-- ---------------------------------------------------------------------------
-- exactly at joined_at counts (the window starts inclusive): 1 day
select pg_temp.add_txn(:'r2'::uuid, 'sms',
  (select joined_at from promotions.referral_attributions where referee_id = :'r2'::uuid));
select pg_temp.check_in(:'r2'::uuid, 'on-3')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '1' and (:'res'::jsonb ->> 'qualified') = 'false',
  'one live parsed day should read 1 and not qualify, got ' || :'res');

-- an email-import entry and a second sms entry on the SAME day: 2 days in all
select pg_temp.add_txn(:'r2'::uuid, 'email', pg_temp.day_at(1, 18));
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(1, 19));
select pg_temp.check_in(:'r2'::uuid, 'on-4')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '2' and (:'res'::jsonb ->> 'realUseMet') = 'false'
  and (:'res'::jsonb ->> 'qualified') = 'false' and not pg_temp.qualified(:'r2'::uuid),
  'two live parsed days (three rows) should read 2 and still hold back, got ' || :'res');

-- a third day (today, 00:00 IST) completes it: now the referee qualifies
select pg_temp.add_txn(:'r2'::uuid, 'sms', pg_temp.day_at(0, 0));
select pg_temp.check_in(:'r2'::uuid, 'on-5')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '3' and (:'res'::jsonb ->> 'realUseMet') = 'true'
  and (:'res'::jsonb ->> 'qualified') = 'true',
  'three live parsed days plus the streak must qualify, got ' || :'res');
select pg_temp.expect(
  pg_temp.qualified(:'r2'::uuid) and pg_temp.entitlements(:'r2'::uuid) = 2 and pg_temp.qualified_events(:'r2'::uuid) = 2,
  'real use plus streak did not create two entitlements and two qualified events');

-- ---------------------------------------------------------------------------
-- 5. Another member's real use never counts for me, and switching the gate off
--    again releases a referee who was held back (it is stateless, no cleanup).
-- ---------------------------------------------------------------------------
select pg_temp.new_referee('on-isolated')::text as r3 \gset
select pg_temp.seed_two_open_days(:'r3'::uuid);
select pg_temp.check_in(:'r3'::uuid, 'iso-1')::text as res \gset
-- the second referee above now has three live days; this one has none
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '0' and (:'res'::jsonb ->> 'qualified') = 'false'
  and not pg_temp.qualified(:'r3'::uuid),
  'a member with no real use was credited with someone else''s: ' || :'res');

-- The helper itself answers only for the caller: the same window (the first
-- referee's own), asked as the member with three live days and as the one with
-- none, gives 3 and 0.
create function pg_temp.helper_as(p_member uuid, p_from timestamptz, p_until timestamptz)
returns integer language plpgsql as $$
declare
  v_days integer;
begin
  execute 'set local role app_user';
  perform set_config('app.user_id', p_member::text, true);
  v_days := pandapay.referral_real_use_days(p_from, p_until, 'Asia/Kolkata');
  execute 'reset role';
  return v_days;
end
$$;
select a.joined_at::text as win_from, a.deadline_at::text as win_until
  from promotions.referral_attributions a where a.referee_id = :'r2'::uuid \gset
select pg_temp.expect(
  pg_temp.helper_as(:'r2'::uuid, :'win_from'::timestamptz, :'win_until'::timestamptz) = 3
  and pg_temp.helper_as(:'r3'::uuid, :'win_from'::timestamptz, :'win_until'::timestamptz) = 0,
  'the real-use helper must answer only for the calling member');

update promotions.campaign_versions set real_use_required_days = 0
 where version_key = :'campaign_version';
select pg_temp.check_in(:'r3'::uuid, 'iso-2')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'qualified') = 'true' and pg_temp.qualified(:'r3'::uuid) and pg_temp.entitlements(:'r3'::uuid) = 2,
  'switching the gate back off must release a held-back referee on the next check-in, got ' || :'res');
select pg_temp.expect(
  not (:'res'::jsonb ? 'realUseDays') and not (:'res'::jsonb ? 'realUseMet') and not (:'res'::jsonb ? 'realUseRequiredDays'),
  'gate off again: the answer must not carry real-use fields, got ' || :'res');

-- ---------------------------------------------------------------------------
-- 6. An entry the person ignores stops counting until it is active again.
-- ---------------------------------------------------------------------------
update promotions.campaign_versions set real_use_required_days = 3
 where version_key = :'campaign_version';
select pg_temp.new_referee('on-ignored')::text as r4 \gset
select pg_temp.seed_two_open_days(:'r4'::uuid);
select pg_temp.add_txn(:'r4'::uuid, 'sms', pg_temp.day_at(2, 13));
select pg_temp.add_txn(:'r4'::uuid, 'email', pg_temp.day_at(1, 13));
select pg_temp.add_txn(:'r4'::uuid, 'sms', pg_temp.day_at(0, 0), 'spend', 'ignored');
select pg_temp.check_in(:'r4'::uuid, 'ign-1')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '2' and not pg_temp.qualified(:'r4'::uuid),
  'an ignored entry counted as a real-use day: ' || :'res');
update public.transactions set status = 'active'
 where profile_id = :'r4'::uuid and status = 'ignored';
select pg_temp.check_in(:'r4'::uuid, 'ign-2')::text as res \gset
select pg_temp.expect(
  (:'res'::jsonb ->> 'realUseDays') = '3' and (:'res'::jsonb ->> 'qualified') = 'true' and pg_temp.qualified(:'r4'::uuid),
  'restoring the ignored entry should have qualified the referee, got ' || :'res');

-- ---------------------------------------------------------------------------
-- 7. Totals: four eligible referees, two entitlements each.
-- ---------------------------------------------------------------------------
select pg_temp.expect(
  (select count(*) from promotions.referral_attributions where reward_eligible) = 4,
  'expected four eligible attributions');
select pg_temp.expect(
  (select count(*) from promotions.reward_entitlements) = 8,
  'expected eight entitlements for four qualified referees');

rollback;
select 'referral real-use gate: OK (rolled back synthetic fixtures)' as result;
