-- Trusted routines for admission, invitation preview and activation. The
-- application role can execute these functions but cannot read or mutate the
-- promotions tables directly.

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
         or (v_bucket ->> 'amountPaise') !~ '^[0-9]{1,18}$' then
        return false;
      end if;
      v_weight := (v_bucket ->> 'weight')::numeric;
      v_amount := (v_bucket ->> 'amountPaise')::numeric;
      if v_weight <= 0 or trunc(v_weight) <> v_weight or v_amount <= 0
         or trunc(v_amount) <> v_amount or v_amount > 9223372036854775807 then
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

create or replace function promotions.max_prize_paise(p_distribution jsonb, p_role text)
returns bigint
language sql immutable strict
set search_path = pg_catalog, promotions
as $$
  select max((bucket ->> 'amountPaise')::bigint)
    from jsonb_array_elements(p_distribution -> p_role) as prize(bucket)
$$;

alter table promotions.campaign_versions
  add constraint campaign_versions_distribution_valid
  check (promotions.distribution_is_valid(prize_distribution));

create or replace function promotions.current_access_state()
returns text
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_mode text;
  v_state text;
begin
  if v_user_id is null then return 'unauthenticated'; end if;
  select admission_mode into v_mode from promotions.access_settings where singleton;
  select state into v_state from promotions.memberships where profile_id = v_user_id;
  if v_state = 'suspended' then return 'suspended'; end if;
  if v_state = 'active' then return 'active'; end if;
  -- A verified returning user with a product profile but no promotion
  -- membership must be allowed to complete the trusted, idempotent legacy
  -- activation path even after invite-only admission is enabled.
  if exists (select 1 from public.profiles where id = v_user_id) then
    if v_mode = 'open' then return 'active'; end if;
    return 'activation_pending';
  end if;
  if not exists (select 1 from public.profiles where id = v_user_id)
     and v_mode = 'paused_new' then
    return 'paused';
  end if;
  return 'requires_invite';
end
$$;

create or replace function promotions.current_user_is_member()
returns boolean
language sql stable security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
  select promotions.current_access_state() = 'active'
$$;

create or replace function promotions.get_access_policy()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, promotions
as $$
  select jsonb_build_object(
    'admissionMode', a.admission_mode,
    'minimumClientCapability', a.minimum_client_capability,
    'revision', a.revision,
    'campaign', case when v.version_key is null then null else jsonb_build_object(
      'version', v.version_key,
      'calendarZone', v.calendar_zone,
      'requiredConsecutiveDays', v.required_consecutive_days,
      'qualificationWindowDays', v.qualification_window_days,
      'receiptLifetimeSeconds', v.receipt_lifetime_seconds,
      'termsVersion', v.terms_version,
      'enrollmentOpen', s.enrollment_open,
      'fulfillmentPaused', s.fulfillment_paused,
      'redemptionPaused', s.redemption_paused,
      'distribution', v.prize_distribution
    ) end
  )
  from promotions.access_settings a
  left join promotions.campaign_versions v on v.version_key = a.active_campaign_version
  left join promotions.campaign_state s on s.version_key = v.version_key
  where a.singleton
$$;

create or replace function promotions.validate_invitation(p_code text)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_settings promotions.access_settings%rowtype;
  v_version promotions.campaign_versions%rowtype;
  v_state promotions.campaign_state%rowtype;
begin
  select * into v_settings from promotions.access_settings where singleton;
  if length(v_code) < 6 or length(v_code) > 32
     or not exists (select 1 from promotions.invitation_codes c where c.code = v_code and c.active) then
    return jsonb_build_object('valid', false, 'error', 'invitation_unavailable');
  end if;
  if v_settings.active_campaign_version is not null then
    select * into v_version from promotions.campaign_versions
     where version_key = v_settings.active_campaign_version;
    select * into v_state from promotions.campaign_state
     where version_key = v_settings.active_campaign_version;
  end if;
  return jsonb_build_object(
    'valid', true,
    'code', v_code,
    'accessMode', v_settings.admission_mode,
    'accessRevision', v_settings.revision,
    'campaignVersion', v_version.version_key,
    'rewardAvailable', coalesce(v_state.enrollment_open, false)
      and coalesce(v_state.enrollment_cap is null or v_state.enrollment_count < v_state.enrollment_cap, false),
    'termsVersion', coalesce(v_version.terms_version, 'invite-access-v1'),
    'requiredConsecutiveDays', v_version.required_consecutive_days,
    'qualificationWindowDays', v_version.qualification_window_days,
    'calendarZone', v_version.calendar_zone,
    'distribution', v_version.prize_distribution
  );
end
$$;

create or replace function promotions.ensure_current_invitation_code()
returns text
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_code text;
  v_candidate text;
  v_attempt integer;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;

  select code into v_code from promotions.invitation_codes
   where owner_profile_id = v_user_id and active;
  if v_code is not null then return v_code; end if;

  -- Recover a legacy code if it was excluded from the initial copy due to a
  -- historical case collision. No existing public code is changed here.
  select upper(code) into v_code from public.referral_codes where profile_id = v_user_id;
  if v_code is not null then
    insert into promotions.invitation_codes (code, owner_profile_id)
    values (v_code, v_user_id) on conflict (code) do nothing;
    if exists (select 1 from promotions.invitation_codes where code = v_code and owner_profile_id = v_user_id and active) then
      return v_code;
    end if;
  end if;

  for v_attempt in 1..8 loop
    v_candidate := 'PANDA-' || upper(encode(gen_random_bytes(6), 'hex'));
    begin
      insert into promotions.invitation_codes (code, owner_profile_id)
      values (v_candidate, v_user_id);
      insert into public.referral_codes (profile_id, code)
      values (v_user_id, v_candidate)
      on conflict (profile_id) do nothing;
      select upper(code) into v_code from public.referral_codes where profile_id = v_user_id;
      return coalesce(v_code, v_candidate);
    exception when unique_violation then
      delete from promotions.invitation_codes
       where code = v_candidate and owner_profile_id = v_user_id;
    end;
  end loop;
  raise exception using errcode = 'P0001', message = 'referral_code_unavailable';
end
$$;

create or replace function promotions.activate_current_user(
  p_display_name text,
  p_locale text,
  p_currency text,
  p_verified_email text,
  p_verified_phone text,
  p_invitation_code text,
  p_expected_campaign_version text,
  p_terms_version text,
  p_accept_reward_terms boolean,
  p_accept_access_only boolean,
  p_identity_claims jsonb default '[]'::jsonb,
  p_product_terms_version text default null,
  p_accept_product_terms boolean default false
)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_settings promotions.access_settings%rowtype;
  v_member promotions.memberships%rowtype;
  v_version promotions.campaign_versions%rowtype;
  v_state promotions.campaign_state%rowtype;
  v_inviter uuid;
  v_code text := upper(btrim(coalesce(p_invitation_code, '')));
  v_has_profile boolean;
  v_reward_eligible boolean := false;
  v_ineligible_reason text := 'access_only';
  v_attribution_id uuid;
  v_deadline timestamptz;
  v_max_inviter bigint;
  v_max_referee bigint;
  v_pair_max bigint;
  v_quota integer;
  v_claim jsonb;
  v_claim_inserted integer := 0;
  v_claim_expected integer := 0;
  v_duplicate_claim boolean := false;
  v_terms text := coalesce(nullif(btrim(p_terms_version), ''), 'invite-access-v1');
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'session_invalid';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select * into v_settings from promotions.access_settings where singleton for update;
  if not found then raise exception using errcode = 'P0001', message = 'access_unavailable'; end if;

  select * into v_member from promotions.memberships where profile_id = v_user_id;
  if v_member.state = 'suspended' then
    raise exception using errcode = 'P0001', message = 'account_suspended';
  end if;
  select exists (select 1 from public.profiles where id = v_user_id) into v_has_profile;

  -- Existing product accounts are grandfathered only after the API's trusted
  -- auth-service check; a client-supplied subject/contact is never sufficient.
  if v_member.state = 'active' or (v_has_profile and v_member.profile_id is null) then
    insert into promotions.memberships (profile_id, state, admission_source)
    values (v_user_id, 'active', 'legacy')
    on conflict (profile_id) do nothing;
    update public.profiles set
      display_name = coalesce(nullif(btrim(p_display_name), ''), display_name),
      email = coalesce(nullif(lower(btrim(p_verified_email)), ''), email),
      phone_number = coalesce(nullif(btrim(p_verified_phone), ''), phone_number),
      locale = coalesce(nullif(p_locale, ''), locale),
      currency = coalesce(nullif(p_currency, ''), currency),
      updated_at = now()
    where id = v_user_id;
    insert into promotions.credit_accounts (profile_id) values (v_user_id)
    on conflict (profile_id) do nothing;
    return jsonb_build_object('state', 'active', 'source', coalesce(v_member.admission_source, 'legacy'),
                              'profileId', v_user_id, 'referral', null);
  end if;

  if v_settings.admission_mode = 'paused_new' then
    raise exception using errcode = 'P0001', message = 'admission_paused';
  end if;
  if v_settings.admission_mode = 'invite_only' and v_code = '' then
    raise exception using errcode = 'P0001', message = 'invitation_required';
  end if;
  if (v_settings.admission_mode = 'invite_only' or v_code <> '')
     and (not coalesce(p_accept_product_terms, false)
          or nullif(btrim(p_product_terms_version), '') is null) then
    raise exception using errcode = 'P0001', message = 'required_terms_missing';
  end if;

  if v_code <> '' then
    select owner_profile_id into v_inviter
      from promotions.invitation_codes where code = v_code and active;
    if v_inviter is null or v_inviter = v_user_id then
      raise exception using errcode = 'P0001', message = 'invitation_unavailable';
    end if;
    if not exists (
      select 1 from promotions.memberships m
       where m.profile_id = v_inviter and m.state = 'active'
    ) and not (
      v_settings.admission_mode = 'open'
      and exists (select 1 from public.profiles p where p.id = v_inviter)
    ) then
      raise exception using errcode = 'P0001', message = 'invitation_unavailable';
    end if;
    if not exists (select 1 from public.profiles p where p.id = v_inviter and p.onboarding_completed_at is not null) then
      raise exception using errcode = 'P0001', message = 'inviter_not_eligible';
    end if;

    if v_settings.active_campaign_version is not null and p_accept_reward_terms then
      if p_expected_campaign_version is distinct from v_settings.active_campaign_version then
        if not coalesce(p_accept_access_only, false) then
          raise exception using errcode = 'P0001', message = 'offer_changed';
        end if;
      else
        select * into v_version from promotions.campaign_versions
         where version_key = v_settings.active_campaign_version;
        select * into v_state from promotions.campaign_state
         where version_key = v_version.version_key for update;
        if not found or not v_state.enrollment_open or v_terms <> v_version.terms_version then
          if not coalesce(p_accept_access_only, false) then
            raise exception using errcode = 'P0001', message = 'offer_changed';
          end if;
        else
          v_max_inviter := promotions.max_prize_paise(v_version.prize_distribution, 'inviter');
          v_max_referee := promotions.max_prize_paise(v_version.prize_distribution, 'referee');
          v_pair_max := v_max_inviter + v_max_referee;

          insert into promotions.inviter_campaign_caps (campaign_version, inviter_id)
          values (v_version.version_key, v_inviter) on conflict do nothing;
          select enrolled_count into v_quota from promotions.inviter_campaign_caps
           where campaign_version = v_version.version_key and inviter_id = v_inviter for update;

          if (v_state.enrollment_cap is not null and v_state.enrollment_count >= v_state.enrollment_cap)
             or (v_state.total_budget_paise - v_state.issued_paise - v_state.reserved_paise < v_pair_max)
             or (v_version.inviter_cap_enrollments is not null and v_quota >= v_version.inviter_cap_enrollments) then
            if not coalesce(p_accept_access_only, false) then
              raise exception using errcode = 'P0001', message = 'offer_changed';
            end if;
          elsif jsonb_typeof(coalesce(p_identity_claims, '[]'::jsonb)) <> 'array' then
            raise exception using errcode = 'P0001', message = 'identity_proof_invalid';
          else
            for v_claim in select value from jsonb_array_elements(coalesce(p_identity_claims, '[]'::jsonb)) loop
              if v_claim ->> 'kind' not in ('email', 'phone')
                 or coalesce(v_claim ->> 'keyVersion', '') = ''
                 or coalesce(v_claim ->> 'fingerprint', '') !~ '^[a-f0-9]{64}$' then
                raise exception using errcode = 'P0001', message = 'identity_proof_invalid';
              end if;
              v_claim_expected := v_claim_expected + 1;
              if exists (
                select 1 from promotions.eligibility_claims c
                 where c.campaign_version = v_version.version_key
                   and c.identity_kind = v_claim ->> 'kind'
                   and c.fingerprint_key_version = v_claim ->> 'keyVersion'
                   and c.fingerprint = v_claim ->> 'fingerprint'
              ) then
                v_duplicate_claim := true;
              end if;
            end loop;
            if v_claim_expected = 0 then v_duplicate_claim := true; end if;
            if not v_duplicate_claim then
              for v_claim in select value from jsonb_array_elements(coalesce(p_identity_claims, '[]'::jsonb)) loop
                insert into promotions.eligibility_claims
                  (campaign_version, identity_kind, fingerprint_key_version, fingerprint, profile_id)
                values (v_version.version_key, v_claim ->> 'kind', v_claim ->> 'keyVersion',
                        v_claim ->> 'fingerprint', v_user_id)
                on conflict do nothing;
                if found then v_claim_inserted := v_claim_inserted + 1; end if;
              end loop;
              if v_claim_inserted = v_claim_expected then
                v_reward_eligible := true;
                v_ineligible_reason := null;
              else
                v_duplicate_claim := true;
              end if;
            end if;
            if v_duplicate_claim and not coalesce(p_accept_access_only, false) then
              raise exception using errcode = 'P0001', message = 'reward_identity_already_used';
            end if;
            if v_duplicate_claim then
              delete from promotions.eligibility_claims where profile_id = v_user_id
                and campaign_version = v_version.version_key;
              v_claim_inserted := 0;
            end if;
          end if;
        end if;
      end if;
    elsif not coalesce(p_accept_access_only, false) then
      raise exception using errcode = 'P0001', message = 'offer_changed';
    end if;
  end if;

  -- No profile or membership is created until invitation, current terms,
  -- capacity and the caller's explicit reward/access-only choice are valid.
  insert into public.profiles (id, display_name, locale, currency, email, phone_number)
  values (v_user_id, nullif(btrim(p_display_name), ''), coalesce(nullif(p_locale, ''), 'en-IN'),
          coalesce(nullif(p_currency, ''), 'INR'), nullif(lower(btrim(p_verified_email)), ''),
          nullif(btrim(p_verified_phone), ''));
  insert into promotions.memberships (profile_id, state, admission_source)
  values (v_user_id, 'active', case when v_inviter is null then 'open' else 'invite' end);
  insert into promotions.credit_accounts (profile_id) values (v_user_id)
  on conflict (profile_id) do nothing;

  if coalesce(p_accept_product_terms, false) then
    insert into public.user_consents (profile_id, purpose, policy_version, granted, source_screen)
    select v_user_id, 'terms', btrim(p_product_terms_version), true, 'product_activation'
     where not exists (
       select 1 from (
         select distinct on (c.purpose) c.policy_version, c.granted, c.revoked_at
           from public.user_consents c
          where c.profile_id = v_user_id and c.purpose = 'terms'
          order by c.purpose, c.granted_at desc, c.id desc
       ) latest
        where latest.policy_version = btrim(p_product_terms_version)
          and latest.granted and latest.revoked_at is null
     );
  end if;

  if v_inviter is not null then
    if v_reward_eligible then
      v_deadline := now() + make_interval(days => v_version.qualification_window_days);
      update promotions.campaign_state set
        reserved_paise = reserved_paise + v_pair_max,
        enrollment_count = enrollment_count + 1,
        updated_at = now()
      where version_key = v_version.version_key;
      update promotions.inviter_campaign_caps set enrolled_count = enrolled_count + 1
       where campaign_version = v_version.version_key and inviter_id = v_inviter;
    end if;

    insert into promotions.referral_attributions
      (inviter_id, referee_id, invitation_code, campaign_version, reward_eligible,
       ineligible_reason, deadline_at)
    values (v_inviter, v_user_id, v_code,
            case when v_reward_eligible then v_version.version_key else null end,
            v_reward_eligible, case when v_reward_eligible then null else v_ineligible_reason end,
            v_deadline)
    returning id into v_attribution_id;

    if v_reward_eligible then
      insert into promotions.reward_reservations
        (attribution_id, beneficiary_id, beneficiary_role, campaign_version, reserved_paise)
      values
        (v_attribution_id, v_inviter, 'inviter', v_version.version_key, v_max_inviter),
        (v_attribution_id, v_user_id, 'referee', v_version.version_key, v_max_referee);
    end if;

    insert into promotions.terms_acceptances (profile_id, purpose, policy_version, source)
    values (v_user_id, 'referral_terms', v_terms, 'invite_activation')
    on conflict (profile_id, purpose, policy_version) do nothing;

    insert into promotions.reward_outbox (event_key, event_type, beneficiary_id, payload)
    values ('referral:joined:' || v_attribution_id || ':' || v_inviter,
            'referral.joined', v_inviter,
            jsonb_build_object('attributionId', v_attribution_id))
    on conflict (event_key) do nothing;
  end if;

  return jsonb_build_object(
    'state', 'active',
    'source', case when v_inviter is null then 'open' else 'invite' end,
    'profileId', v_user_id,
    'referral', case when v_attribution_id is null then null else jsonb_build_object(
      'id', v_attribution_id,
      'rewardEligible', v_reward_eligible,
      'campaignVersion', case when v_reward_eligible then v_version.version_key else null end,
      'deadlineAt', v_deadline,
      'requiredConsecutiveDays', case when v_reward_eligible then v_version.required_consecutive_days else null end,
      'calendarZone', case when v_reward_eligible then v_version.calendar_zone else null end
    ) end
  );
end
$$;

create or replace function promotions.complete_current_user_onboarding()
returns timestamptz
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_user_id uuid := pandapay.uid();
  v_completed timestamptz;
begin
  if v_user_id is null or not promotions.current_user_is_member() then
    raise exception using errcode = 'P0001', message = 'membership_required';
  end if;
  if not exists (
    select 1 from (
      select distinct on (c.purpose) c.granted, c.revoked_at
        from public.user_consents c
       where c.profile_id = v_user_id and c.purpose = 'terms'
       order by c.purpose, c.granted_at desc, c.id desc
    ) latest where latest.granted and latest.revoked_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'required_terms_missing';
  end if;
  update public.profiles set onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = v_user_id returning onboarding_completed_at into v_completed;
  return v_completed;
end
$$;

reset role;

-- PostgreSQL grants EXECUTE on newly-created functions to PUBLIC by default.
-- Revoke it across this schema before exposing only the app-facing routines
-- listed below; the security-definer helpers must never inherit public access.
revoke execute on all functions in schema promotions from public;
grant usage on schema promotions to app_user;
grant execute on function promotions.distribution_is_valid(jsonb) to app_user;
grant execute on function promotions.max_prize_paise(jsonb, text) to app_user;
grant execute on function promotions.current_access_state() to app_user;
grant execute on function promotions.current_user_is_member() to app_user;
grant execute on function promotions.get_access_policy() to app_user;
grant execute on function promotions.validate_invitation(text) to app_user;
grant execute on function promotions.ensure_current_invitation_code() to app_user;
grant execute on function promotions.activate_current_user(text, text, text, text, text, text, text, text, boolean, boolean, jsonb, text, boolean) to app_user;
grant execute on function promotions.complete_current_user_onboarding() to app_user;
