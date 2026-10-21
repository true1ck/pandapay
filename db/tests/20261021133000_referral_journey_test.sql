-- Disposable-DB integration journey. Run only after the permission test in a
-- fresh migrated database. All synthetic rows and settings roll back at end.
\set ON_ERROR_STOP on

begin;

select gen_random_uuid()::text as inviter_id,
       gen_random_uuid()::text as referee_id,
       gen_random_uuid()::text as legacy_id,
       'fixture-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) as campaign_version
\gset
select set_config('test.legacy_user_id', :'legacy_id', true);
select set_config('test.campaign_version', :'campaign_version', true);

insert into public.profiles (id, display_name, locale, currency, onboarding_completed_at)
values (:'inviter_id'::uuid, 'Fixture inviter', 'en-IN', 'INR', now());
insert into public.profiles (id, display_name, locale, currency)
values (:'legacy_id'::uuid, 'Fixture returning member', 'en-IN', 'INR');
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
values (:'campaign_version', true, false, true, 10000, 10);

insert into promotions.invitation_codes (code, owner_profile_id)
values ('PANDA-' || upper(substr(replace(:'inviter_id', '-', ''), 1, 12)), :'inviter_id'::uuid);
insert into public.referral_codes (profile_id, code)
values (:'inviter_id'::uuid, 'PANDA-' || upper(substr(replace(:'inviter_id', '-', ''), 1, 12)));
update promotions.access_settings
   set admission_mode = 'invite_only', active_campaign_version = :'campaign_version'
 where singleton;

set local role app_user;
select set_config('app.user_id', :'legacy_id', true);
do $$
begin
  if promotions.current_access_state() <> 'activation_pending' then
    raise exception 'existing profile should be offered trusted activation, not blocked as a new signup';
  end if;
end
$$;
select promotions.activate_current_user(
  'Fixture returning member', 'en-IN', 'INR', null, null, null,
  null, null, false, true, '[]'::jsonb, null, false
);
do $$
begin
  if promotions.current_access_state() <> 'active' then
    raise exception 'legacy activation did not restore active product access';
  end if;
end
$$;
reset role;

set local role app_user;
select set_config('app.user_id', :'referee_id', true);
select promotions.activate_current_user(
  'Fixture referee', 'en-IN', 'INR', 'fixture-referee@example.invalid', null,
  'PANDA-' || upper(substr(replace(:'inviter_id', '-', ''), 1, 12)),
  :'campaign_version', 'fixture-campaign-terms', true, false,
  jsonb_build_array(jsonb_build_object(
    'kind', 'email', 'keyVersion', 'test-v1',
    'fingerprint', repeat(substr(replace(:'referee_id', '-', ''), 1, 1), 64)
  )),
  'fixture-product-terms', true
);
reset role;

update promotions.referral_attributions
   set joined_at = now() - interval '2 days 5 minutes',
       deadline_at = now() + interval '28 days'
 where referee_id = :'referee_id'::uuid;
insert into promotions.engagement_days
  (profile_id, campaign_version, local_date, server_activity_at, source_action, receipt_id)
select :'referee_id'::uuid, :'campaign_version',
       ((now() - interval '2 days') at time zone 'Asia/Kolkata')::date,
       now() - interval '2 days', 'home_summary', 'fixture-day-one-' || :'referee_id';
insert into promotions.engagement_days
  (profile_id, campaign_version, local_date, server_activity_at, source_action, receipt_id)
select :'referee_id'::uuid, :'campaign_version',
       ((now() - interval '1 day') at time zone 'Asia/Kolkata')::date,
       now() - interval '1 day', 'home_summary', 'fixture-day-two-' || :'referee_id';

set local role app_user;
select set_config('app.user_id', :'referee_id', true);
select promotions.record_engagement_day(
  'fixture-day-three-' || :'referee_id', 'home_summary', now()
);
reset role;

do $$
begin
  if (select admission_source from promotions.memberships
       where profile_id = current_setting('test.legacy_user_id')::uuid) <> 'legacy' then
    raise exception 'verified returning profile was not grandfathered during invite-only activation';
  end if;
  if (select count(*) from promotions.referral_attributions where reward_eligible) <> 1 then
    raise exception 'fixture activation did not create exactly one eligible attribution';
  end if;
  if (select count(*) from promotions.reward_entitlements) <> 2 then
    raise exception 'third eligible date did not create exactly two entitlements';
  end if;
  if (select reserved_paise from promotions.campaign_state
       where version_key = current_setting('test.campaign_version')) <> 10000 then
    raise exception 'pair maximum reward liability was not reserved';
  end if;
end
$$;

select id::text as referee_entitlement_id from promotions.reward_entitlements
 where beneficiary_role = 'referee' limit 1 \gset
select id::text as inviter_entitlement_id from promotions.reward_entitlements
 where beneficiary_role = 'inviter' limit 1 \gset

set local role app_user;
select set_config('app.user_id', :'referee_id', true);
select promotions.get_spin_configuration(:'referee_entitlement_id'::uuid);
select promotions.commit_reward_spin(:'referee_entitlement_id'::uuid, 'zero', 0);
select promotions.commit_reward_spin(:'referee_entitlement_id'::uuid, 'fifty', 5000);
select promotions.get_credit_snapshot();
reset role;

set local role app_user;
select set_config('app.user_id', :'inviter_id', true);
select promotions.get_referrals_v2(extract(year from now() at time zone 'Asia/Kolkata')::integer);
select promotions.commit_reward_spin(:'inviter_entitlement_id'::uuid, 'fifty', 5000);
reset role;

do $$
begin
  if (select count(*) from promotions.reward_spins) <> 2 then
    raise exception 'each participant must have exactly one persisted spin';
  end if;
  if (select count(*) from promotions.credit_ledger where event_type = 'award') <> 1 then
    raise exception 'a zero spin must not create a zero-value ledger row';
  end if;
  if not exists (select 1 from promotions.reward_spins where amount_paise = 0)
     or exists (select 1 from promotions.credit_ledger l
                  join promotions.reward_spins s on s.id = l.source_id
                 where s.amount_paise = 0)
     or not exists (select 1 from promotions.reward_outbox
                     where event_type = 'reward.spin.completed') then
    raise exception 'zero spin completion was not recorded independently of wallet movement';
  end if;
  if exists (select 1 from promotions.credit_accounts where available_paise < 0 or reserved_paise < 0) then
    raise exception 'credit balance became negative';
  end if;
  if (select available_paise from promotions.credit_accounts c
       join promotions.reward_entitlements e on e.beneficiary_id = c.profile_id
      where e.beneficiary_role = 'referee' limit 1) <> 0 then
    raise exception 'zero spin must complete without changing the referee balance';
  end if;
  if (select issued_paise from promotions.campaign_state
       where version_key = current_setting('test.campaign_version')) <> 5000
     or (select reserved_paise from promotions.campaign_state
          where version_key = current_setting('test.campaign_version')) <> 0 then
    raise exception 'budget settlement does not match the two committed awards';
  end if;
  if exists (select 1 from promotions.credit_redemptions) then
    raise exception 'the test must not fabricate a subscription redemption';
  end if;
end
$$;

rollback;
select 'referral promotion journey: OK (rolled back synthetic fixtures)' as result;
