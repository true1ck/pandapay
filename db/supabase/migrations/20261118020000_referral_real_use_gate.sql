-- Referral reward only after real use (row 5 of docs/EMAIL_PHONE_LOCK_PLAN_2026-11-09.md).
--
-- Today a referee qualifies after N consecutive local days of "engagement", and
-- opening the home screen is an engagement day, so an account that does nothing
-- but open the app N days in a row earns the reward. This migration adds an
-- OPTIONAL second condition, per campaign version, that is OFF by default:
--
--   promotions.campaign_versions.real_use_required_days
--     0   (default)  off. record_engagement_day behaves exactly as before.
--     1..30          the referee must also have that many distinct local days,
--                    inside their qualification window, on which a spend entry
--                    that was PARSED (SMS or email import) reached the server.
--
-- What counts as one real-use day is decided in pandapay.referral_real_use_days:
--   * source in ('sms', 'email'). Typed-in ('manual'), statement and CSV imports
--     do not count. POST /transactions hard-codes 'manual', and the sync allowlist
--     does not let a client write source, created_at or is_backfill.
--   * not a history scan (is_backfill = false). A bulk inbox scan arrives in one
--     burst on one day and is flagged by the phone.
--   * status 'active' and entry_kind 'spend'. An entry the person later ignores
--     stops counting; qualification is re-checked on every check-in until it is
--     recorded, and is never undone once recorded.
--   * the day is the SERVER arrival day (created_at) in the campaign calendar
--     zone, never the transaction's own date, which the phone chooses.
--   * only days from joined_at up to (not including) deadline_at count.
--
-- Nothing here switches the requirement on. No existing campaign version changes.

set role promotions_owner;

alter table promotions.campaign_versions
  add column if not exists real_use_required_days smallint not null default 0
    check (real_use_required_days between 0 and 30);

comment on column promotions.campaign_versions.real_use_required_days is
  '0 = off (qualification is the consecutive-days rule alone). 1..30 = the referee also needs this many distinct local days with a parsed (sms or email) live spend entry inside the qualification window. See pandapay.referral_real_use_days.';

reset role;

-- Counts the CALLER's real-use days. It reads public.transactions as its owner
-- (the migration role), which is why promotions_owner, which has no grant on
-- that table, only receives EXECUTE here. It takes no profile id: it can only
-- ever answer for pandapay.uid(), and the forced row security policy on
-- transactions agrees. db/setup_app_role.sql grants EXECUTE on every function in
-- the pandapay schema to app_user on each run, so app_user can call it too; that
-- reveals nothing the caller cannot already read from their own transactions.
create or replace function pandapay.referral_real_use_days(
  p_from timestamptz,
  p_until timestamptz,
  p_zone text
)
returns integer
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_days integer;
begin
  if v_user_id is null or p_from is null or p_until is null or p_zone is null then
    return 0;
  end if;
  select count(distinct (t.created_at at time zone p_zone)::date)::integer
    into v_days
    from public.transactions t
   where t.profile_id = v_user_id
     and t.status = 'active'
     and t.entry_kind = 'spend'
     and t.source in ('sms', 'email')
     and t.is_backfill = false
     and t.created_at >= p_from
     and t.created_at < p_until;
  return coalesce(v_days, 0);
end
$$;

revoke all on function pandapay.referral_real_use_days(timestamptz, timestamptz, text) from public;
grant execute on function pandapay.referral_real_use_days(timestamptz, timestamptz, text) to promotions_owner;

set role promotions_owner;

-- Same function as 20261021130000_referral_progress_rewards.sql, with only the
-- real-use additions marked "real-use gate" below. With
-- real_use_required_days = 0 every added branch is skipped and the result is
-- the same as before.
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
  v_real_days integer := 0;      -- real-use gate
  v_real_met boolean := true;    -- real-use gate
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

  -- real-use gate: only when this campaign version asks for it.
  if v_version.real_use_required_days > 0 then
    v_real_days := pandapay.referral_real_use_days(
      v_attr.joined_at, v_attr.deadline_at, v_version.calendar_zone);
    v_real_met := v_real_days >= v_version.real_use_required_days;
  end if;

  if v_best >= v_version.required_consecutive_days and v_attr.qualified_at is null
     and v_real_met then                                   -- real-use gate
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
    'qualified', v_best >= v_version.required_consecutive_days and v_real_met,   -- real-use gate
    'lastConfirmedAt', now()
  ) || case                                                                      -- real-use gate
    when v_version.real_use_required_days > 0 then jsonb_build_object(
      'realUseRequiredDays', v_version.real_use_required_days,
      'realUseDays', v_real_days,
      'realUseMet', v_real_met)
    else '{}'::jsonb
  end;
end
$$;

reset role;

-- CREATE OR REPLACE keeps the existing privileges; state them again so this
-- file stands on its own.
revoke execute on function promotions.record_engagement_day(text, text, timestamptz) from public;
grant execute on function promotions.record_engagement_day(text, text, timestamptz) to app_user;
