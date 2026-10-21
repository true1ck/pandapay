-- Persisted engagement, qualification, independent spins and subscription
-- credit accounting. Prize values are selected by the API's secure RNG and
-- are revalidated against the frozen campaign version in the write routine.

set role promotions_owner;

create or replace function promotions.get_referrals_v2(p_year integer default null)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_year integer := coalesce(p_year, extract(year from now() at time zone 'Asia/Kolkata')::integer);
  v_from timestamptz;
  v_until timestamptz;
  v_code text;
  v_referrals jsonb;
  v_joined integer;
  v_qualified integer;
  v_awarded bigint;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  if v_year not between 2000 and 2200 then
    raise exception using errcode = 'P0001', message = 'invalid_year';
  end if;
  v_from := make_timestamp(v_year, 1, 1, 0, 0, 0) at time zone 'Asia/Kolkata';
  v_until := make_timestamp(v_year + 1, 1, 1, 0, 0, 0) at time zone 'Asia/Kolkata';
  v_code := promotions.ensure_current_invitation_code();

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'alias', coalesce(nullif(btrim(p.display_name), ''), 'Friend'),
    'joinedAt', a.joined_at,
    'deadlineAt', a.deadline_at,
    'rewardEligible', a.reward_eligible,
    'ineligibleReason', a.ineligible_reason,
    'qualifiedAt', a.qualified_at,
    'currentStreakDays', a.current_streak_days,
    'bestStreakDays', a.best_streak_days,
    'requiredConsecutiveDays', v.required_consecutive_days,
    'entitlementState', e.state,
    'spinAmountPaise', case when s.amount_paise is null then null else s.amount_paise::text end
  ) order by a.joined_at desc, a.id desc), '[]'::jsonb)
    into v_referrals
    from promotions.referral_attributions a
    left join public.profiles p on p.id = a.referee_id
    left join promotions.campaign_versions v on v.version_key = a.campaign_version
    left join promotions.reward_entitlements e
      on e.attribution_id = a.id and e.beneficiary_id = v_user_id and e.beneficiary_role = 'inviter'
    left join promotions.reward_spins s on s.entitlement_id = e.id
   where a.inviter_id = v_user_id;

  select count(*)::integer,
         count(*) filter (where qualified_at is not null)::integer
    into v_joined, v_qualified
    from promotions.referral_attributions
   where inviter_id = v_user_id and joined_at >= v_from and joined_at < v_until;

  select coalesce(sum(available_delta_paise), 0)::bigint into v_awarded
    from promotions.credit_ledger
   where profile_id = v_user_id and event_type = 'award'
     and occurred_at >= v_from and occurred_at < v_until;

  return jsonb_build_object(
    'code', v_code,
    'shareLink', 'https://pandapay.app/i/' || v_code,
    'year', v_year,
    'joinedThisYear', v_joined,
    'qualifiedThisYear', v_qualified,
    'awardedThisYearPaise', v_awarded::text,
    'referrals', v_referrals,
    'lastConfirmedAt', now()
  );
end
$$;

create or replace function promotions.get_my_referral()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_result jsonb;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  select jsonb_build_object(
    'id', a.id,
    'inviterAlias', coalesce(nullif(btrim(p.display_name), ''), 'Friend'),
    'joinedAt', a.joined_at,
    'deadlineAt', a.deadline_at,
    'rewardEligible', a.reward_eligible,
    'ineligibleReason', a.ineligible_reason,
    'qualifiedAt', a.qualified_at,
    'currentStreakDays', a.current_streak_days,
    'bestStreakDays', a.best_streak_days,
    'requiredConsecutiveDays', v.required_consecutive_days,
    'calendarZone', v.calendar_zone,
    'entitlementState', e.state,
    'spinAmountPaise', case when s.amount_paise is null then null else s.amount_paise::text end
  ) into v_result
    from promotions.referral_attributions a
    join public.profiles p on p.id = a.inviter_id
    left join promotions.campaign_versions v on v.version_key = a.campaign_version
    left join promotions.reward_entitlements e
      on e.attribution_id = a.id and e.beneficiary_id = v_user_id and e.beneficiary_role = 'referee'
    left join promotions.reward_spins s on s.entitlement_id = e.id
   where a.referee_id = v_user_id;
  return coalesce(v_result, jsonb_build_object('referral', null));
end
$$;

create or replace function promotions.get_my_rewards()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_items jsonb;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'entitlementId', e.id,
    'attributionId', e.attribution_id,
    'role', e.beneficiary_role,
    'state', e.state,
    'createdAt', e.created_at,
    'claimedAt', e.claimed_at,
    'spinId', s.id,
    'outcomeId', s.outcome_id,
    'amountPaise', case when s.amount_paise is null then null else s.amount_paise::text end,
    'currency', 'INR',
    'committedAt', s.committed_at
  ) order by e.created_at desc, e.id desc), '[]'::jsonb)
    into v_items
    from promotions.reward_entitlements e
    left join promotions.reward_spins s on s.entitlement_id = e.id
   where e.beneficiary_id = v_user_id;
  return jsonb_build_object('rewards', v_items, 'lastConfirmedAt', now());
end
$$;

create or replace function promotions.get_credit_snapshot()
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_account promotions.credit_accounts%rowtype;
  v_available boolean;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  insert into promotions.credit_accounts (profile_id) values (v_user_id)
  on conflict (profile_id) do nothing;
  select * into v_account from promotions.credit_accounts where profile_id = v_user_id;
  select coalesce(not s.redemption_paused and s.platform_benefit_available, false) into v_available
    from promotions.access_settings a
    left join promotions.campaign_state s on s.version_key = a.active_campaign_version
   where a.singleton;
  return jsonb_build_object(
    'currency', 'INR',
    'availablePaise', v_account.available_paise::text,
    'reservedPaise', v_account.reserved_paise::text,
    'version', v_account.version,
    'redemptionAvailable', coalesce(v_available, false),
    'redemptionUnavailableReason', case when coalesce(v_available, false) then null else 'platform_benefit_not_configured' end,
    'lastConfirmedAt', now()
  );
end
$$;

create or replace function promotions.get_credit_ledger(
  p_before_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_items jsonb;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception using errcode = 'P0001', message = 'invalid_limit';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', page.id,
    'eventType', page.event_type,
    'availableDeltaPaise', page.available_delta_paise::text,
    'reservedDeltaPaise', page.reserved_delta_paise::text,
    'sourceType', page.source_type,
    'occurredAt', page.occurred_at,
    'reason', page.reason
  ) order by page.occurred_at desc, page.id desc), '[]'::jsonb)
    into v_items
    from (
      select * from promotions.credit_ledger l
       where l.profile_id = v_user_id
         and (p_before_at is null or (l.occurred_at, l.id) < (p_before_at, p_before_id))
       order by l.occurred_at desc, l.id desc limit p_limit
    ) page;
  return jsonb_build_object('entries', v_items, 'lastConfirmedAt', now());
end
$$;

create or replace function promotions.get_spin_configuration(p_entitlement_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_result jsonb;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  select jsonb_build_object(
    'entitlementId', e.id,
    'state', e.state,
    'campaignVersion', e.campaign_version,
    'role', e.beneficiary_role,
    'distribution', v.prize_distribution -> e.beneficiary_role
  ) into v_result
    from promotions.reward_entitlements e
    join promotions.campaign_versions v on v.version_key = e.campaign_version
   where e.id = p_entitlement_id and e.beneficiary_id = v_user_id;
  return v_result;
end
$$;

create or replace function promotions.record_engagement_day(
  p_receipt_id text,
  p_source_action text,
  p_server_activity_at timestamptz
)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_attr promotions.referral_attributions%rowtype;
  v_version promotions.campaign_versions%rowtype;
  v_state promotions.campaign_state%rowtype;
  v_day date;
  v_previous date;
  v_run integer := 0;
  v_best integer := 0;
  v_current integer := 0;
  v_last_date date;
  v_inserted boolean := false;
  v_rows integer := 0;
  v_action_date date;
  v_existing_profile uuid;
  v_entitlement_state text;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  if p_receipt_id is null or length(p_receipt_id) not between 16 and 120
     or p_source_action not in ('home_summary', 'card_action', 'transaction_action')
     or p_server_activity_at is null or p_server_activity_at > now() + interval '30 seconds' then
    raise exception using errcode = 'P0001', message = 'activity_receipt_invalid';
  end if;

  select a.* into v_attr
    from promotions.referral_attributions a
   where a.referee_id = v_user_id and a.reward_eligible and a.qualified_at is null
     and a.disqualified_at is null;
  if not found then
    return jsonb_build_object('recorded', false, 'progressDays', 0, 'requiredDays', 3,
                              'qualified', false, 'reason', 'no_active_referral');
  end if;
  select * into v_version from promotions.campaign_versions where version_key = v_attr.campaign_version;
  select * into v_state from promotions.campaign_state where version_key = v_attr.campaign_version for update;
  select * into v_attr from promotions.referral_attributions where id = v_attr.id for update;
  if p_server_activity_at < v_attr.joined_at or p_server_activity_at >= v_attr.deadline_at then
    raise exception using errcode = 'P0001', message = 'activity_outside_window';
  end if;
  v_action_date := (p_server_activity_at at time zone v_version.calendar_zone)::date;
  select profile_id into v_existing_profile from promotions.engagement_days
   where receipt_id = p_receipt_id;
  if found then
    if v_existing_profile <> v_user_id then
      raise exception using errcode = 'P0001', message = 'activity_receipt_invalid';
    end if;
    return jsonb_build_object('recorded', false, 'activityDate', v_action_date,
      'progressDays', v_attr.current_streak_days, 'requiredDays', v_version.required_consecutive_days,
      'qualified', v_attr.qualified_at is not null, 'replayed', true, 'lastConfirmedAt', now());
  end if;

  insert into promotions.engagement_days
    (profile_id, campaign_version, local_date, server_activity_at, source_action, receipt_id)
  values (v_user_id, v_attr.campaign_version, v_action_date, p_server_activity_at, p_source_action, p_receipt_id)
  on conflict do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_rows > 0;

  -- Recompute from server-dated facts so an allowed receipt submitted out of
  -- order around midnight converges to the same consecutive-day result.
  v_previous := null;
  for v_day in
    select distinct local_date from promotions.engagement_days
     where profile_id = v_user_id and campaign_version = v_attr.campaign_version
       and server_activity_at >= v_attr.joined_at and server_activity_at < v_attr.deadline_at
     order by local_date
  loop
    if v_previous is null or v_day <> v_previous + 1 then v_run := 1;
    else v_run := v_run + 1;
    end if;
    v_best := greatest(v_best, v_run);
    v_previous := v_day;
    v_last_date := v_day;
  end loop;
  if v_last_date >= (now() at time zone v_version.calendar_zone)::date - 1 then
    v_current := v_run;
  end if;

  update promotions.referral_attributions set
    current_streak_days = v_current,
    best_streak_days = greatest(best_streak_days, v_best)
   where id = v_attr.id;

  if v_best >= v_version.required_consecutive_days and v_attr.qualified_at is null then
    v_entitlement_state := case when v_state.fulfillment_paused then 'held' else 'ready' end;
    update promotions.referral_attributions set qualified_at = p_server_activity_at
     where id = v_attr.id and qualified_at is null;
    insert into promotions.reward_entitlements
      (attribution_id, beneficiary_id, beneficiary_role, campaign_version, state)
    values
      (v_attr.id, v_attr.inviter_id, 'inviter', v_attr.campaign_version, v_entitlement_state),
      (v_attr.id, v_attr.referee_id, 'referee', v_attr.campaign_version, v_entitlement_state)
    on conflict (attribution_id, beneficiary_role) do nothing;
    insert into promotions.reward_outbox (event_key, event_type, beneficiary_id, payload)
    values
      ('referral:qualified:' || v_attr.id || ':' || v_attr.inviter_id,
       'referral.qualified', v_attr.inviter_id, jsonb_build_object('attributionId', v_attr.id)),
      ('referral:qualified:' || v_attr.id || ':' || v_attr.referee_id,
       'referral.qualified', v_attr.referee_id, jsonb_build_object('attributionId', v_attr.id))
    on conflict (event_key) do nothing;
  end if;

  return jsonb_build_object(
    'recorded', v_inserted,
    'activityDate', v_action_date,
    'progressDays', case when v_best >= v_version.required_consecutive_days then v_version.required_consecutive_days else v_current end,
    'bestStreakDays', v_best,
    'requiredDays', v_version.required_consecutive_days,
    'qualified', v_best >= v_version.required_consecutive_days,
    'lastConfirmedAt', now()
  );
end
$$;

create or replace function promotions.commit_reward_spin(
  p_entitlement_id uuid,
  p_outcome_id text,
  p_amount_paise bigint
)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_entitlement promotions.reward_entitlements%rowtype;
  v_spin promotions.reward_spins%rowtype;
  v_reservation promotions.reward_reservations%rowtype;
  v_state promotions.campaign_state%rowtype;
  v_attr promotions.referral_attributions%rowtype;
  v_account promotions.credit_accounts%rowtype;
  v_prize jsonb;
  v_replayed boolean := false;
  v_ledger_id uuid;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;

  select * into v_entitlement from promotions.reward_entitlements
   where id = p_entitlement_id and beneficiary_id = v_user_id;
  if not found then return null; end if;
  select * into v_state from promotions.campaign_state
   where version_key = v_entitlement.campaign_version for update;
  select * into v_attr from promotions.referral_attributions
   where id = v_entitlement.attribution_id for update;
  select * into v_entitlement from promotions.reward_entitlements
   where id = p_entitlement_id and beneficiary_id = v_user_id for update;
  select * into v_spin from promotions.reward_spins where entitlement_id = p_entitlement_id;
  if found then
    return jsonb_build_object('entitlementId', v_entitlement.id, 'spinId', v_spin.id,
      'outcomeId', v_spin.outcome_id, 'amountPaise', v_spin.amount_paise::text,
      'currency', 'INR', 'committedAt', v_spin.committed_at, 'replayed', true);
  end if;
  if v_entitlement.state = 'held' or v_state.fulfillment_paused then
    raise exception using errcode = 'P0001', message = 'reward_held';
  end if;
  if v_entitlement.state <> 'ready' or v_attr.qualified_at is null then
    raise exception using errcode = 'P0001', message = 'reward_not_ready';
  end if;
  if p_outcome_id is null or p_amount_paise is null or p_amount_paise <= 0 then
    raise exception using errcode = 'P0001', message = 'invalid_reward_outcome';
  end if;

  select prize into v_prize
    from promotions.campaign_versions v,
         lateral jsonb_array_elements(v.prize_distribution -> v_entitlement.beneficiary_role) prize
   where v.version_key = v_entitlement.campaign_version
     and prize ->> 'id' = p_outcome_id
     and (prize ->> 'amountPaise')::bigint = p_amount_paise;
  if v_prize is null then
    raise exception using errcode = 'P0001', message = 'invalid_reward_outcome';
  end if;

  select * into v_reservation from promotions.reward_reservations
   where attribution_id = v_entitlement.attribution_id
     and beneficiary_role = v_entitlement.beneficiary_role for update;
  if not found or v_reservation.state <> 'reserved' or p_amount_paise > v_reservation.reserved_paise then
    raise exception using errcode = 'P0001', message = 'reward_reservation_invalid';
  end if;

  insert into promotions.credit_accounts (profile_id) values (v_user_id)
  on conflict (profile_id) do nothing;
  select * into v_account from promotions.credit_accounts where profile_id = v_user_id for update;
  update promotions.credit_accounts set
    available_paise = available_paise + p_amount_paise,
    version = version + 1,
    updated_at = now()
   where profile_id = v_user_id;

  insert into promotions.reward_spins
    (entitlement_id, beneficiary_id, outcome_id, amount_paise, campaign_version)
  values (p_entitlement_id, v_user_id, p_outcome_id, p_amount_paise, v_entitlement.campaign_version)
  returning * into v_spin;
  insert into promotions.credit_ledger
    (profile_id, event_type, available_delta_paise, source_type, source_id, idempotency_key)
  values (v_user_id, 'award', p_amount_paise, 'reward_spin', v_spin.id,
          'award:' || p_entitlement_id)
  returning id into v_ledger_id;

  update promotions.reward_reservations set state = 'settled', awarded_paise = p_amount_paise,
    settled_at = now() where id = v_reservation.id;
  update promotions.campaign_state set
    reserved_paise = reserved_paise - v_reservation.reserved_paise,
    issued_paise = issued_paise + p_amount_paise,
    updated_at = now()
   where version_key = v_entitlement.campaign_version;
  update promotions.reward_entitlements set state = 'claimed', claimed_at = now()
   where id = p_entitlement_id;
  insert into promotions.reward_outbox (event_key, event_type, beneficiary_id, payload)
  values ('reward:awarded:' || v_spin.id || ':' || v_user_id,
          'reward.awarded', v_user_id,
          jsonb_build_object('entitlementId', p_entitlement_id, 'spinId', v_spin.id))
  on conflict (event_key) do nothing;

  return jsonb_build_object('entitlementId', p_entitlement_id, 'spinId', v_spin.id,
    'outcomeId', p_outcome_id, 'amountPaise', p_amount_paise::text,
    'currency', 'INR', 'ledgerEntryId', v_ledger_id,
    'committedAt', v_spin.committed_at, 'replayed', v_replayed);
end
$$;

reset role;

-- Also remove PostgreSQL's default PUBLIC execute grant from functions added
-- in this migration (and any earlier promotion helper) before allowlisting.
revoke execute on all functions in schema promotions from public;
grant execute on function promotions.get_referrals_v2(integer) to app_user;
grant execute on function promotions.get_my_referral() to app_user;
grant execute on function promotions.get_my_rewards() to app_user;
grant execute on function promotions.get_credit_snapshot() to app_user;
grant execute on function promotions.get_credit_ledger(timestamptz, uuid, integer) to app_user;
grant execute on function promotions.get_spin_configuration(uuid) to app_user;
grant execute on function promotions.record_engagement_day(text, text, timestamptz) to app_user;
grant execute on function promotions.commit_reward_spin(uuid, text, bigint) to app_user;
