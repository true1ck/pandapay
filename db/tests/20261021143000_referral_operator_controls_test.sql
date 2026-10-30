-- Exercises admin-only status and reason-required emergency holds. Use only
-- against a disposable fully migrated database; all fixtures roll back.
\set ON_ERROR_STOP on

begin;
select session_user as fixture_original_login \gset
do $$ begin
  if not exists(select 1 from pg_roles where rolname='admin_api_runtime') then
    create role admin_api_runtime login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end $$;
grant pandapay_admin_api to admin_api_runtime;
select gen_random_uuid()::text as admin_id,
       gen_random_uuid()::text as member_id,
       'operator-test-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) as campaign_version
\gset

insert into public.profiles (id, display_name, locale, currency)
values (:'admin_id'::uuid, 'Operator fixture', 'en-IN', 'INR'),
       (:'member_id'::uuid, 'Member fixture', 'en-IN', 'INR');
insert into public.admin_users (id, email, role, is_active)
values (:'admin_id'::uuid, 'referral-operator-fixture@example.invalid', 'owner', true);

insert into promotions.campaign_versions
  (version_key, calendar_zone, required_consecutive_days, qualification_window_days,
   receipt_lifetime_seconds, terms_version, prize_distribution)
values (:'campaign_version', 'Asia/Kolkata', 3, 30, 300, 'operator-test-terms',
  '{"inviter":[{"id":"ten","amountPaise":"1000","weight":100}],'
   '"referee":[{"id":"ten","amountPaise":"1000","weight":100}]}');
insert into promotions.campaign_state
  (version_key, enrollment_open, fulfillment_paused, redemption_paused,
   total_budget_paise, enrollment_cap)
values (:'campaign_version', true, false, false, 10000, 10);
update promotions.access_settings
   set admission_mode = 'invite_only', active_campaign_version = :'campaign_version'
 where singleton;

-- A regular member cannot inspect operator status or change a hold, even
-- though both RPCs are executable at the role level.
set local role app_user;
select set_config('app.user_id', :'member_id', true);
do $$
begin
  begin
    perform promotions.get_admin_referral_operations();
    raise exception 'ordinary member read operator status';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'admin_required' then raise; end if;
  end;
  begin
    perform promotions.set_admin_referral_hold('admission', true, 'incident test hold');
    raise exception 'ordinary member changed an operator hold';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'admin_required' then raise; end if;
  end;
end
$$;
reset role;

-- A customer connection cannot gain authority by adopting the owner's UUID.
set local role app_user;
select set_config('app.user_id', :'admin_id', true);
select set_config('pandapay.admin_actor', :'admin_id', true);
do $$ begin
  if pandapay.is_admin() then raise exception 'customer connection asserted administration'; end if;
end $$;
reset role;
set local session authorization admin_api_runtime;
set local role pandapay_admin_api;
select set_config('app.user_id', :'admin_id', true);
select set_config('pandapay.admin_actor', :'admin_id', true);
select set_config('pandapay.admin_permission', 'referrals.control', true);
do $$
declare
  v_status jsonb;
  v_result jsonb;
begin
  v_status := promotions.get_admin_referral_operations();
  if v_status->'access'->>'admissionMode' <> 'invite_only' then
    raise exception 'admin status did not report the current access mode';
  end if;

  v_result := promotions.set_admin_referral_hold('admission', true, 'pilot incident pause');
  if v_result->'after'->>'admissionMode' <> 'paused_new' then
    raise exception 'admission hold did not pause new admissions';
  end if;
  perform promotions.set_admin_referral_hold('enrollment', true, 'pilot incident pause');
  perform promotions.set_admin_referral_hold('fulfillment', true, 'pilot incident pause');
  perform promotions.set_admin_referral_hold('redemption', true, 'pilot incident pause');

  v_status := promotions.get_admin_referral_operations();
  if v_status->'access'->>'admissionMode' <> 'paused_new'
     or v_status->'campaign'->>'enrollmentOpen' <> 'false'
     or v_status->'campaign'->>'fulfillmentPaused' <> 'true'
     or v_status->'campaign'->>'redemptionPaused' <> 'true' then
    raise exception 'one or more emergency holds did not take effect';
  end if;

  perform promotions.set_admin_referral_hold('admission', false, 'pilot incident resolved');
  perform promotions.set_admin_referral_hold('enrollment', false, 'pilot incident resolved');
  perform promotions.set_admin_referral_hold('fulfillment', false, 'pilot incident resolved');
  perform promotions.set_admin_referral_hold('redemption', false, 'pilot incident resolved');

  v_status := promotions.get_admin_referral_operations();
  if v_status->'access'->>'admissionMode' <> 'invite_only'
     or v_status->'campaign'->>'enrollmentOpen' <> 'true'
     or v_status->'campaign'->>'fulfillmentPaused' <> 'false'
     or v_status->'campaign'->>'redemptionPaused' <> 'false' then
    raise exception 'hold release did not restore each exact prior state';
  end if;
  if jsonb_array_length(v_status->'recentAudit') <> 8 then
    raise exception 'hold apply/release did not create eight audit records';
  end if;
  if jsonb_array_length(v_status->'activeHolds') <> 0 then
    raise exception 'released holds remain active';
  end if;
end
$$;
reset role;
set local session authorization :"fixture_original_login";

do $$
begin
  if has_table_privilege('app_user', 'promotions.referral_operator_audit', 'SELECT')
     or has_table_privilege('rewards_worker', 'promotions.referral_operator_holds', 'SELECT') then
    raise exception 'operator audit/hold tables must not be directly readable';
  end if;
end
$$;

rollback;
select 'referral operator controls: OK (rolled back fixtures)' as result;
