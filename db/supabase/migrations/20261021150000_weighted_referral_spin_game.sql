-- Versioned odds for the interactive referral wheel. This creates an inactive,
-- zero-budget campaign version; it does not activate or fund a live promotion.

set role promotions_owner;

create or replace function promotions.distribution_is_valid(p_distribution jsonb)
returns boolean
language plpgsql immutable
set search_path = pg_catalog, public, promotions
as $$
declare
  v_role text;
  v_bucket jsonb;
  v_weight numeric;
  v_amount numeric;
  v_id text;
  v_seen text[];
  v_total numeric;
begin
  if jsonb_typeof(p_distribution) <> 'object' then return false; end if;
  foreach v_role in array array['inviter', 'referee'] loop
    if jsonb_typeof(p_distribution -> v_role) <> 'array'
       or jsonb_array_length(p_distribution -> v_role) = 0 then
      return false;
    end if;
    v_seen := array[]::text[];
    v_total := 0;
    for v_bucket in select value from jsonb_array_elements(p_distribution -> v_role) loop
      v_id := v_bucket ->> 'id';
      if v_id is null or length(v_id) not between 1 and 80
         or v_id = any(v_seen)
         or jsonb_typeof(v_bucket -> 'weight') <> 'number'
         or jsonb_typeof(v_bucket -> 'amountPaise') <> 'string'
         or (v_bucket ->> 'amountPaise') !~ '^(0|[1-9][0-9]{0,4})$' then
        return false;
      end if;
      v_weight := (v_bucket ->> 'weight')::numeric;
      v_amount := (v_bucket ->> 'amountPaise')::numeric;
      if v_weight <= 0 or trunc(v_weight) <> v_weight
         or v_amount < 0 or trunc(v_amount) <> v_amount or v_amount > 50000 then
        return false;
      end if;
      v_total := v_total + v_weight;
      if v_total > 2147483647 then return false; end if;
      v_seen := array_append(v_seen, v_id);
    end loop;
  end loop;
  return true;
exception when others then
  return false;
end
$$;

-- Re-check existing versions against the zero-to-₹500 rule when upgrading.
alter table promotions.campaign_versions
  drop constraint campaign_versions_distribution_valid;
alter table promotions.campaign_versions
  add constraint campaign_versions_distribution_valid
  check (promotions.distribution_is_valid(prize_distribution));

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
    'ledgerEntryId', l.id,
    'currency', 'INR',
    'committedAt', s.committed_at
  ) order by e.created_at desc, e.id desc), '[]'::jsonb)
    into v_items
    from promotions.reward_entitlements e
    left join promotions.reward_spins s on s.entitlement_id = e.id
    left join promotions.credit_ledger l
      on l.source_type = 'reward_spin' and l.source_id = s.id and l.event_type = 'award'
   where e.beneficiary_id = v_user_id;
  return jsonb_build_object('rewards', v_items, 'lastConfirmedAt', now());
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
    select id into v_ledger_id from promotions.credit_ledger
     where source_type = 'reward_spin' and source_id = v_spin.id and event_type = 'award';
    return jsonb_build_object(
      'entitlementId', v_entitlement.id,
      'spinId', v_spin.id,
      'outcomeId', v_spin.outcome_id,
      'amountPaise', v_spin.amount_paise::text,
      'currency', 'INR',
      'ledgerEntryId', v_ledger_id,
      'committedAt', v_spin.committed_at,
      'replayed', true
    );
  end if;
  if v_entitlement.state = 'held' or v_state.fulfillment_paused then
    raise exception using errcode = 'P0001', message = 'reward_held';
  end if;
  if v_entitlement.state <> 'ready' or v_attr.qualified_at is null then
    raise exception using errcode = 'P0001', message = 'reward_not_ready';
  end if;
  if p_outcome_id is null or p_amount_paise is null or p_amount_paise < 0
     or p_amount_paise > 50000 then
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
  if not found or v_reservation.state <> 'reserved'
     or p_amount_paise > v_reservation.reserved_paise then
    raise exception using errcode = 'P0001', message = 'reward_reservation_invalid';
  end if;

  -- A zero result completes the spin but is not a money movement. Do not
  -- fabricate an empty ledger row or mutate the available balance.
  if p_amount_paise > 0 then
    insert into promotions.credit_accounts (profile_id) values (v_user_id)
    on conflict (profile_id) do nothing;
    select * into v_account from promotions.credit_accounts
     where profile_id = v_user_id for update;
    update promotions.credit_accounts set
      available_paise = available_paise + p_amount_paise,
      version = version + 1,
      updated_at = now()
     where profile_id = v_user_id;
  end if;

  insert into promotions.reward_spins
    (entitlement_id, beneficiary_id, outcome_id, amount_paise, campaign_version)
  values (p_entitlement_id, v_user_id, p_outcome_id, p_amount_paise,
          v_entitlement.campaign_version)
  returning * into v_spin;

  if p_amount_paise > 0 then
    insert into promotions.credit_ledger
      (profile_id, event_type, available_delta_paise, source_type, source_id, idempotency_key)
    values (v_user_id, 'award', p_amount_paise, 'reward_spin', v_spin.id,
            'award:' || p_entitlement_id)
    returning id into v_ledger_id;
  end if;

  update promotions.reward_reservations set state = 'settled', awarded_paise = p_amount_paise,
    settled_at = now() where id = v_reservation.id;
  update promotions.campaign_state set
    reserved_paise = reserved_paise - v_reservation.reserved_paise,
    issued_paise = issued_paise + p_amount_paise,
    updated_at = now()
   where version_key = v_entitlement.campaign_version;
  update promotions.reward_entitlements set state = 'claimed', claimed_at = now()
   where id = p_entitlement_id;

  if p_amount_paise > 0 then
    insert into promotions.reward_outbox (event_key, event_type, beneficiary_id, payload)
    values ('reward:awarded:' || v_spin.id || ':' || v_user_id,
            'reward.awarded', v_user_id,
            jsonb_build_object('entitlementId', p_entitlement_id, 'spinId', v_spin.id))
    on conflict (event_key) do nothing;
  else
    insert into promotions.reward_outbox (event_key, event_type, beneficiary_id, payload)
    values ('reward:spin-completed:' || v_spin.id || ':' || v_user_id,
            'reward.spin.completed', v_user_id,
            jsonb_build_object('entitlementId', p_entitlement_id, 'spinId', v_spin.id))
    on conflict (event_key) do nothing;
  end if;

  return jsonb_build_object(
    'entitlementId', p_entitlement_id,
    'spinId', v_spin.id,
    'outcomeId', p_outcome_id,
    'amountPaise', p_amount_paise::text,
    'currency', 'INR',
    'ledgerEntryId', v_ledger_id,
    'committedAt', v_spin.committed_at,
    'replayed', v_replayed
  );
end
$$;

insert into promotions.campaign_versions (
  version_key,
  calendar_zone,
  required_consecutive_days,
  qualification_window_days,
  receipt_lifetime_seconds,
  terms_version,
  inviter_cap_enrollments,
  prize_distribution
) values (
  'bamboo-spin-v1-2026-10',
  'Asia/Kolkata',
  3,
  30,
  300,
  'referral-bamboo-v1',
  null,
  '{
    "inviter": [
      {"id":"zero","amountPaise":"0","weight":1000},
      {"id":"five","amountPaise":"500","weight":2500},
      {"id":"ten","amountPaise":"1000","weight":2500},
      {"id":"twenty-five","amountPaise":"2500","weight":2000},
      {"id":"fifty","amountPaise":"5000","weight":1000},
      {"id":"seventy-five","amountPaise":"7500","weight":500},
      {"id":"one-hundred","amountPaise":"10000","weight":300},
      {"id":"one-fifty","amountPaise":"15000","weight":100},
      {"id":"two-hundred","amountPaise":"20000","weight":50},
      {"id":"three-hundred","amountPaise":"30000","weight":30},
      {"id":"five-hundred","amountPaise":"50000","weight":20}
    ],
    "referee": [
      {"id":"zero","amountPaise":"0","weight":1000},
      {"id":"five","amountPaise":"500","weight":2500},
      {"id":"ten","amountPaise":"1000","weight":2500},
      {"id":"twenty-five","amountPaise":"2500","weight":2000},
      {"id":"fifty","amountPaise":"5000","weight":1000},
      {"id":"seventy-five","amountPaise":"7500","weight":500},
      {"id":"one-hundred","amountPaise":"10000","weight":300},
      {"id":"one-fifty","amountPaise":"15000","weight":100},
      {"id":"two-hundred","amountPaise":"20000","weight":50},
      {"id":"three-hundred","amountPaise":"30000","weight":30},
      {"id":"five-hundred","amountPaise":"50000","weight":20}
    ]
  }'::jsonb
)
on conflict (version_key) do nothing;

insert into promotions.campaign_state (
  version_key,
  enrollment_open,
  fulfillment_paused,
  redemption_paused,
  platform_benefit_available,
  total_budget_paise
) values (
  'bamboo-spin-v1-2026-10',
  false,
  true,
  true,
  false,
  0
)
on conflict (version_key) do nothing;
