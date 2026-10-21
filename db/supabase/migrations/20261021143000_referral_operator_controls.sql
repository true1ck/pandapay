-- Narrow, audited emergency holds and privacy-safe operational status for
-- the referral pilot. This does not expose campaign creation, prize editing,
-- manual award writes, or unreviewed budget changes to the console.

-- The owner needs REFERENCES to create the audit foreign keys below.
grant references on public.profiles to promotions_owner;

set role promotions_owner;

create table promotions.referral_operator_holds (
  scope text not null check (scope in ('admission', 'enrollment', 'fulfillment', 'redemption')),
  target_key text not null,
  original_state jsonb not null check (jsonb_typeof(original_state) = 'object'),
  active boolean not null default true,
  changed_by uuid not null references public.profiles(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 10 and 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (scope, target_key)
);

create table promotions.referral_operator_audit (
  id uuid primary key default gen_random_uuid(),
  actor_profile_id uuid not null references public.profiles(id) on delete restrict,
  action text not null check (action in ('hold_applied', 'hold_released')),
  scope text not null check (scope in ('admission', 'enrollment', 'fulfillment', 'redemption')),
  target_key text not null,
  reason text not null check (length(btrim(reason)) between 10 and 500),
  before_state jsonb not null check (jsonb_typeof(before_state) = 'object'),
  after_state jsonb not null check (jsonb_typeof(after_state) = 'object'),
  occurred_at timestamptz not null default now()
);
create index referral_operator_audit_recent_idx
  on promotions.referral_operator_audit (occurred_at desc, id desc);

alter table promotions.referral_operator_holds enable row level security;
alter table promotions.referral_operator_holds force row level security;
create policy referral_operator_holds_owner
  on promotions.referral_operator_holds
  for all to promotions_owner using (true) with check (true);
alter table promotions.referral_operator_audit enable row level security;
alter table promotions.referral_operator_audit force row level security;
create policy referral_operator_audit_owner
  on promotions.referral_operator_audit
  for all to promotions_owner using (true) with check (true);

create or replace function promotions.get_admin_referral_operations()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_access jsonb;
  v_campaign jsonb;
  v_workers jsonb;
  v_outbox jsonb;
  v_holds jsonb;
  v_audit jsonb;
begin
  if pandapay.uid() is null or not coalesce(pandapay.is_admin(), false) then
    raise exception using errcode = 'P0001', message = 'admin_required';
  end if;

  select jsonb_build_object(
    'admissionMode', s.admission_mode,
    'minimumClientCapability', s.minimum_client_capability,
    'revision', s.revision,
    'activeCampaignVersion', s.active_campaign_version,
    'updatedAt', s.updated_at
  ) into v_access
    from promotions.access_settings s where s.singleton;

  select case when v.version_key is null then null else jsonb_build_object(
    'version', v.version_key,
    'enrollmentOpen', c.enrollment_open,
    'fulfillmentPaused', c.fulfillment_paused,
    'redemptionPaused', c.redemption_paused,
    'budgetPaise', c.total_budget_paise::text,
    'issuedPaise', c.issued_paise::text,
    'reservedPaise', c.reserved_paise::text,
    'enrollmentCap', c.enrollment_cap,
    'enrollmentCount', c.enrollment_count,
    'updatedAt', c.updated_at
  ) end into v_campaign
    from promotions.access_settings s
    left join promotions.campaign_versions v on v.version_key = s.active_campaign_version
    left join promotions.campaign_state c on c.version_key = v.version_key
   where s.singleton;

  select coalesce(jsonb_agg(jsonb_build_object(
    'workerId', h.worker_id,
    'heartbeatAt', h.heartbeat_at,
    'heartbeatAgeSeconds', greatest(0, floor(extract(epoch from (now() - h.heartbeat_at))))::bigint,
    'polls', h.polls,
    'claimedEvents', h.claimed_events,
    'completedEvents', h.completed_events,
    'lastErrorCode', h.last_error_code
  ) order by h.heartbeat_at desc), '[]'::jsonb) into v_workers
    from promotions.reward_worker_heartbeats h;

  select jsonb_build_object(
    'countsByState', coalesce((
      select jsonb_object_agg(q.state, q.event_count)
        from (select o.state, count(*)::bigint as event_count
                from promotions.reward_outbox o group by o.state) q
    ), '{}'::jsonb),
    'oldestPendingAt', min(o.available_at) filter (where o.state = 'pending'),
    'oldestPendingAgeSeconds', coalesce((
      select greatest(0, floor(extract(epoch from (now() - min(p.available_at)))))::bigint
        from promotions.reward_outbox p where p.state = 'pending'
    ), 0)
  ) into v_outbox from promotions.reward_outbox o;

  select coalesce(jsonb_agg(jsonb_build_object(
    'scope', h.scope, 'targetKey', h.target_key, 'reason', h.reason,
    'changedBy', h.changed_by, 'updatedAt', h.updated_at
  ) order by h.scope, h.target_key), '[]'::jsonb) into v_holds
    from promotions.referral_operator_holds h where h.active;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'action', a.action, 'scope', a.scope,
    'targetKey', a.target_key, 'reason', a.reason,
    'before', a.before_state, 'after', a.after_state, 'occurredAt', a.occurred_at
  ) order by a.occurred_at desc, a.id desc), '[]'::jsonb) into v_audit
    from (select * from promotions.referral_operator_audit
           order by occurred_at desc, id desc limit 25) a;

  return jsonb_build_object(
    'access', coalesce(v_access, '{}'::jsonb),
    'campaign', v_campaign,
    'workers', v_workers,
    'outbox', coalesce(v_outbox, '{}'::jsonb),
    'activeHolds', v_holds,
    'recentAudit', v_audit
  );
end
$$;

create or replace function promotions.set_admin_referral_hold(
  p_scope text,
  p_paused boolean,
  p_reason text
)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, public, pandapay, promotions
as $$
declare
  v_actor uuid := pandapay.uid();
  v_target text;
  v_current jsonb;
  v_original jsonb;
  v_after jsonb;
  v_active boolean;
  v_audit_id uuid;
  v_campaign_version text;
begin
  if v_actor is null or not coalesce(pandapay.is_admin(), false) then
    raise exception using errcode = 'P0001', message = 'admin_required';
  end if;
  if p_scope not in ('admission', 'enrollment', 'fulfillment', 'redemption')
     or p_paused is null or p_reason is null
     or length(btrim(p_reason)) not between 10 and 500 then
    raise exception using errcode = '22023', message = 'invalid_referral_hold';
  end if;

  if p_scope = 'admission' then
    select jsonb_build_object('admissionMode', s.admission_mode)
      into v_current from promotions.access_settings s
     where s.singleton for update;
    v_target := 'global';
  else
    select active_campaign_version into v_campaign_version
      from promotions.access_settings where singleton for update;
    if v_campaign_version is null then
      raise exception using errcode = 'P0001', message = 'campaign_unavailable';
    end if;
    v_target := v_campaign_version;
    select case p_scope
      when 'enrollment' then jsonb_build_object('enrollmentOpen', c.enrollment_open)
      when 'fulfillment' then jsonb_build_object('fulfillmentPaused', c.fulfillment_paused)
      else jsonb_build_object('redemptionPaused', c.redemption_paused)
    end into v_current
      from promotions.campaign_state c
     where c.version_key = v_campaign_version for update;
    if v_current is null then
      raise exception using errcode = 'P0001', message = 'campaign_unavailable';
    end if;
  end if;

  select h.active, h.original_state into v_active, v_original
    from promotions.referral_operator_holds h
   where h.scope = p_scope and h.target_key = v_target for update;

  if p_paused then
    if coalesce(v_active, false) then
      update promotions.referral_operator_holds
         set reason = btrim(p_reason), changed_by = v_actor, updated_at = now()
       where scope = p_scope and target_key = v_target;
    else
      insert into promotions.referral_operator_holds
        (scope, target_key, original_state, active, changed_by, reason)
      values (p_scope, v_target, v_current, true, v_actor, btrim(p_reason))
      on conflict (scope, target_key) do update set
        original_state = excluded.original_state, active = true,
        changed_by = excluded.changed_by, reason = excluded.reason, updated_at = now();
    end if;

    if p_scope = 'admission' then
      update promotions.access_settings set admission_mode = 'paused_new',
             revision = revision + 1, updated_at = now() where singleton;
      v_after := jsonb_build_object('admissionMode', 'paused_new');
    else
      update promotions.campaign_state set
        enrollment_open = case when p_scope = 'enrollment' then false else enrollment_open end,
        fulfillment_paused = case when p_scope = 'fulfillment' then true else fulfillment_paused end,
        redemption_paused = case when p_scope = 'redemption' then true else redemption_paused end,
        updated_at = now()
       where version_key = v_target;
      v_after := case p_scope
        when 'enrollment' then jsonb_build_object('enrollmentOpen', false)
        when 'fulfillment' then jsonb_build_object('fulfillmentPaused', true)
        else jsonb_build_object('redemptionPaused', true)
      end;
    end if;
  else
    if not coalesce(v_active, false) or v_original is null then
      raise exception using errcode = 'P0001', message = 'referral_hold_not_active';
    end if;
    if p_scope = 'admission' then
      update promotions.access_settings set
        admission_mode = v_original->>'admissionMode',
        revision = revision + 1, updated_at = now()
       where singleton;
      v_after := v_original;
    else
      update promotions.campaign_state set
        enrollment_open = case when p_scope = 'enrollment'
          then (v_original->>'enrollmentOpen')::boolean else enrollment_open end,
        fulfillment_paused = case when p_scope = 'fulfillment'
          then (v_original->>'fulfillmentPaused')::boolean else fulfillment_paused end,
        redemption_paused = case when p_scope = 'redemption'
          then (v_original->>'redemptionPaused')::boolean else redemption_paused end,
        updated_at = now()
       where version_key = v_target;
      v_after := v_original;
    end if;
    update promotions.referral_operator_holds
       set active = false, changed_by = v_actor, reason = btrim(p_reason), updated_at = now()
     where scope = p_scope and target_key = v_target;
  end if;

  insert into promotions.referral_operator_audit
    (actor_profile_id, action, scope, target_key, reason, before_state, after_state)
  values (v_actor, case when p_paused then 'hold_applied' else 'hold_released' end,
          p_scope, v_target, btrim(p_reason), v_current, v_after)
  returning id into v_audit_id;

  return jsonb_build_object(
    'scope', p_scope, 'targetKey', v_target, 'paused', p_paused,
    'before', v_current, 'after', v_after, 'auditId', v_audit_id
  );
end
$$;

reset role;

alter table promotions.referral_operator_holds owner to promotions_owner;
alter table promotions.referral_operator_audit owner to promotions_owner;
revoke all on table promotions.referral_operator_holds, promotions.referral_operator_audit
  from public, app_user, rewards_worker, rewards_worker_login;
alter function promotions.get_admin_referral_operations() owner to promotions_owner;
alter function promotions.set_admin_referral_hold(text, boolean, text) owner to promotions_owner;
revoke execute on function promotions.get_admin_referral_operations() from public;
revoke execute on function promotions.set_admin_referral_hold(text, boolean, text) from public;
grant execute on function promotions.get_admin_referral_operations() to app_user;
grant execute on function promotions.set_admin_referral_hold(text, boolean, text) to app_user;

comment on table promotions.referral_operator_audit is
  'Append-only-by-contract log for admin referral holds; no member-facing mutation or read grant.';
comment on function promotions.set_admin_referral_hold(text, boolean, text) is
  'Reason-required, admin-only hold/release. Restores the captured prior switch value; never edits rewards, budgets, spins or credits.';
