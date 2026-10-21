-- Durable, lease-fenced processing for referral event outbox rows.
-- This worker records event handling outcomes only. It does not issue payouts,
-- change subscription state, or redeem credits.

do $$
declare
  v_can_login boolean;
  v_is_superuser boolean;
  v_bypass_rls boolean;
begin
  if not exists (select 1 from pg_roles where rolname = 'rewards_worker') then
    create role rewards_worker nologin nosuperuser nobypassrls;
  end if;
  select rolcanlogin, rolsuper, rolbypassrls
    into v_can_login, v_is_superuser, v_bypass_rls
    from pg_roles where rolname = 'rewards_worker';
  if v_can_login or v_is_superuser or v_bypass_rls then
    raise exception 'rewards_worker must remain NOLOGIN, NOSUPERUSER and NOBYPASSRLS';
  end if;
end
$$;

grant usage on schema promotions to rewards_worker;

alter table promotions.reward_outbox
  add column if not exists lease_token uuid,
  add column if not exists lease_owner text,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists expires_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists result jsonb;

-- Any pre-worker lease was never owned by this lease-token protocol. Return it
-- to the queue so it can be safely processed under the new fencing rules.
update promotions.reward_outbox
   set state = 'pending', lease_until = null
 where state = 'leased' and lease_token is null;

update promotions.reward_outbox
   set expires_at = created_at + interval '30 days'
 where expires_at is null;

alter table promotions.reward_outbox
  alter column expires_at set default (now() + interval '30 days'),
  alter column expires_at set not null;

alter table promotions.reward_outbox
  drop constraint if exists reward_outbox_state_check;
alter table promotions.reward_outbox
  add constraint reward_outbox_state_check
  check (state in ('pending', 'leased', 'delivered', 'dead', 'expired'));

alter table promotions.reward_outbox
  add constraint reward_outbox_lease_consistency_check
  check (
    (state = 'leased' and lease_until is not null and lease_token is not null
      and lease_owner is not null and length(lease_owner) between 1 and 120)
    or
    (state <> 'leased' and lease_until is null and lease_token is null and lease_owner is null)
  );

alter table promotions.reward_outbox
  add constraint reward_outbox_terminal_result_check
  check (
    (state in ('delivered', 'dead', 'expired')
      and completed_at is not null and result is not null)
    or
    (state not in ('delivered', 'dead', 'expired')
      and completed_at is null and result is null)
  );

create index if not exists reward_outbox_expiry_idx
  on promotions.reward_outbox (expires_at, lease_until)
  where state in ('pending', 'leased');

create table promotions.reward_outbox_attempts (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references promotions.reward_outbox(id) on delete restrict,
  attempt_number integer not null check (attempt_number > 0),
  lease_token uuid not null unique,
  worker_id text not null check (length(worker_id) between 1 and 120),
  status text not null default 'leased'
    check (status in ('leased', 'delivered', 'retry', 'dead', 'expired')),
  claimed_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  result jsonb,
  unique (outbox_id, attempt_number),
  check ((status = 'leased') = (finished_at is null))
);

create index reward_outbox_attempts_event_idx
  on promotions.reward_outbox_attempts (outbox_id, attempt_number desc);

alter table promotions.reward_outbox_attempts enable row level security;
alter table promotions.reward_outbox_attempts force row level security;
create policy reward_outbox_attempts_owner
  on promotions.reward_outbox_attempts
  for all to promotions_owner using (true) with check (true);

create table promotions.reward_worker_heartbeats (
  worker_id text primary key check (length(worker_id) between 1 and 120),
  started_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now(),
  polls bigint not null default 0 check (polls >= 0),
  claimed_events bigint not null default 0 check (claimed_events >= 0),
  completed_events bigint not null default 0 check (completed_events >= 0),
  last_error_code text check (last_error_code is null or last_error_code ~ '^[a-z][a-z0-9_]{0,63}$')
);
alter table promotions.reward_worker_heartbeats enable row level security;
alter table promotions.reward_worker_heartbeats force row level security;
create policy reward_worker_heartbeats_owner
  on promotions.reward_worker_heartbeats
  for all to promotions_owner using (true) with check (true);

-- Worker DB credentials are separate from the API app_user connection. The
-- dedicated login can assume only this restricted role; app_user cannot.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'rewards_worker_login') then
    raise exception 'rewards_worker_login must be provisioned by db/setup_app_role.sql';
  end if;
end
$$;
revoke rewards_worker from app_user;
grant rewards_worker to rewards_worker_login;

set role promotions_owner;

create or replace function promotions.claim_reward_outbox(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 90
)
returns table (
  id uuid,
  event_key text,
  event_type text,
  beneficiary_id uuid,
  payload jsonb,
  attempt_number integer,
  lease_token uuid,
  lease_until timestamptz,
  expires_at timestamptz,
  within_expiry_grace boolean
)
language plpgsql volatile security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_expired_ids uuid[];
  v_dead_ids uuid[];
begin
  if p_worker_id is null or length(p_worker_id) not between 1 and 120
     or p_worker_id ~ '[^a-zA-Z0-9._:-]'
     or p_limit is null or p_limit not between 1 and 100
     or p_lease_seconds is null or p_lease_seconds not between 15 and 900 then
    raise exception using errcode = '22023', message = 'invalid_worker_claim';
  end if;

  -- A 24-hour grace window lets transient outages recover shortly after the
  -- nominal 30-day event expiry; the underlying referral/credit records are
  -- never deleted or changed by this expiry path.
  with expired as (
    update promotions.reward_outbox o
       set state = 'expired', lease_until = null, lease_token = null,
           lease_owner = null, completed_at = v_now,
           last_error_code = 'event_expired',
           result = jsonb_build_object(
             'status', 'expired', 'reason', 'event_expired',
             'expiresAt', o.expires_at, 'graceSeconds', 86400
           )
     where o.state in ('pending', 'leased')
       and (o.lease_until is null or o.lease_until <= v_now)
       and o.expires_at + interval '24 hours' <= v_now
    returning o.id
  )
  select coalesce(array_agg(expired.id), array[]::uuid[])
    into v_expired_ids from expired;

  if cardinality(v_expired_ids) > 0 then
    update promotions.reward_outbox_attempts a
       set status = 'expired', finished_at = v_now, error_code = 'event_expired'
     where a.outbox_id = any(v_expired_ids) and a.status = 'leased';
  end if;

  -- Crashed jobs that used their final permitted attempt become terminal once
  -- their lease expires. A running lease is never stolen or finalized here.
  with dead_jobs as (
    update promotions.reward_outbox o
       set state = 'dead', lease_until = null, lease_token = null,
           lease_owner = null, completed_at = v_now,
           last_error_code = coalesce(o.last_error_code, 'attempt_limit'),
           result = jsonb_build_object(
             'status', 'dead', 'reason', 'attempt_limit', 'attempts', o.attempts
           )
     where o.state in ('pending', 'leased')
       and (o.lease_until is null or o.lease_until <= v_now)
       and o.attempts >= 8
       and o.expires_at + interval '24 hours' > v_now
    returning o.id
  )
  select coalesce(array_agg(dead_jobs.id), array[]::uuid[])
    into v_dead_ids from dead_jobs;

  if cardinality(v_dead_ids) > 0 then
    update promotions.reward_outbox_attempts a
       set status = 'dead', finished_at = v_now,
           error_code = coalesce(a.error_code, 'attempt_limit')
     where a.outbox_id = any(v_dead_ids) and a.status = 'leased';
  end if;

  return query
  with candidates as materialized (
    select o.id
      from promotions.reward_outbox o
     where (
       (o.state = 'pending' and o.available_at <= v_now)
       or (o.state = 'leased' and o.lease_until <= v_now)
     )
       and o.attempts < 8
       and o.expires_at + interval '24 hours' > v_now
     order by o.available_at, o.created_at, o.id
     for update of o skip locked
     limit p_limit
  ), claimed as (
    update promotions.reward_outbox o
       set state = 'leased', attempts = o.attempts + 1,
           last_attempt_at = v_now,
           lease_until = v_now + make_interval(secs => p_lease_seconds),
           lease_token = gen_random_uuid(), lease_owner = p_worker_id,
           last_error_code = null
      from candidates c
     where o.id = c.id
    returning o.id, o.event_key, o.event_type, o.beneficiary_id, o.payload,
              o.attempts, o.lease_token, o.lease_until, o.expires_at
  ), recovered_attempts as (
    update promotions.reward_outbox_attempts a
       set status = 'retry', finished_at = v_now,
           error_code = 'lease_expired'
      from claimed c
     where a.outbox_id = c.id and a.status = 'leased'
    returning a.id
  ), inserted_attempts as (
    insert into promotions.reward_outbox_attempts
      (outbox_id, attempt_number, lease_token, worker_id, status, claimed_at)
    select c.id, c.attempts, c.lease_token, p_worker_id, 'leased', v_now
      from claimed c
    returning outbox_id
  )
  select c.id, c.event_key, c.event_type, c.beneficiary_id, c.payload,
         c.attempts, c.lease_token, c.lease_until, c.expires_at,
         c.expires_at < v_now
    from claimed c
    join inserted_attempts i on i.outbox_id = c.id
    left join lateral (select count(*) from recovered_attempts) r on true;
end
$$;

create or replace function promotions.finalize_reward_outbox(
  p_event_id uuid,
  p_lease_token uuid,
  p_succeeded boolean,
  p_result jsonb default null,
  p_error_code text default null,
  p_permanent boolean default false
)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_event promotions.reward_outbox%rowtype;
  v_error_code text;
  v_retry_seconds integer;
  v_attempt_status text;
  v_response jsonb;
begin
  if p_event_id is null or p_lease_token is null or p_succeeded is null then
    raise exception using errcode = '22023', message = 'invalid_worker_finalization';
  end if;

  if p_succeeded and (p_result is null or jsonb_typeof(p_result) <> 'object'
      or octet_length(p_result::text) > 16384) then
    raise exception using errcode = '22023', message = 'invalid_worker_result';
  end if;

  select * into v_event
    from promotions.reward_outbox o
   where o.id = p_event_id and o.state = 'leased'
     and o.lease_token = p_lease_token
   for update;
  if not found then
    return jsonb_build_object('accepted', false, 'state', 'lease_lost');
  end if;

  if p_succeeded then
    update promotions.reward_outbox
       set state = 'delivered', lease_until = null, lease_token = null,
           lease_owner = null, completed_at = v_now, result = p_result,
           last_error_code = null
     where id = p_event_id;
    update promotions.reward_outbox_attempts
       set status = 'delivered', finished_at = v_now, result = p_result,
           error_code = null
     where outbox_id = p_event_id and lease_token = p_lease_token and status = 'leased';
    return jsonb_build_object('accepted', true, 'state', 'delivered');
  end if;

  v_error_code := case
    when p_error_code ~ '^[a-z][a-z0-9_]{0,63}$' then p_error_code
    else 'worker_error'
  end;

  if coalesce(p_permanent, false) or v_event.attempts >= 8 then
    v_attempt_status := 'dead';
    v_response := jsonb_build_object(
      'status', 'dead', 'reason', v_error_code, 'attempts', v_event.attempts
    );
    update promotions.reward_outbox
       set state = 'dead', lease_until = null, lease_token = null,
           lease_owner = null, completed_at = v_now, result = v_response,
           last_error_code = v_error_code
     where id = p_event_id;
    update promotions.reward_outbox_attempts
       set status = 'dead', finished_at = v_now, error_code = v_error_code
     where outbox_id = p_event_id and lease_token = p_lease_token and status = 'leased';
    return jsonb_build_object('accepted', true, 'state', 'dead', 'attempts', v_event.attempts);
  end if;

  v_attempt_status := 'retry';
  v_retry_seconds := least(30 * power(2, greatest(v_event.attempts - 1, 0)), 3600)::integer;
  update promotions.reward_outbox
     set state = 'pending', lease_until = null, lease_token = null,
         lease_owner = null, available_at = v_now + make_interval(secs => v_retry_seconds),
         last_error_code = v_error_code
   where id = p_event_id;
  update promotions.reward_outbox_attempts
     set status = v_attempt_status, finished_at = v_now, error_code = v_error_code
   where outbox_id = p_event_id and lease_token = p_lease_token and status = 'leased';
  return jsonb_build_object(
    'accepted', true, 'state', 'pending', 'attempts', v_event.attempts,
    'retryAfterSeconds', v_retry_seconds
  );
end
$$;

create or replace function promotions.expire_referral_reservations(p_limit integer default 50)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_campaign record;
  v_attr promotions.referral_attributions%rowtype;
  v_state promotions.campaign_state%rowtype;
  v_release bigint;
  v_count integer := 0;
  v_released bigint := 0;
begin
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'invalid_expiry_limit';
  end if;

  -- Lock budget rows in campaign order before attribution/reservation rows.
  -- This matches activation and spin settlement, avoiding budget deadlocks.
  for v_campaign in
    select distinct a.campaign_version
      from promotions.referral_attributions a
      join promotions.campaign_versions v on v.version_key = a.campaign_version
     where a.reward_eligible and a.qualified_at is null and a.disqualified_at is null
       and a.deadline_at + make_interval(secs => v.receipt_lifetime_seconds) <= now()
     order by a.campaign_version
  loop
    exit when v_count >= p_limit;
    select * into v_state from promotions.campaign_state
     where version_key = v_campaign.campaign_version for update;
    if not found then continue; end if;

    for v_attr in
      select a.* from promotions.referral_attributions a
       join promotions.campaign_versions v on v.version_key = a.campaign_version
       where a.campaign_version = v_campaign.campaign_version
         and a.reward_eligible and a.qualified_at is null and a.disqualified_at is null
         and a.deadline_at + make_interval(secs => v.receipt_lifetime_seconds) <= now()
       order by a.id
       for update of a skip locked
       limit (p_limit - v_count)
    loop
      select coalesce(sum(r.reserved_paise), 0) into v_release
        from promotions.reward_reservations r
       where r.attribution_id = v_attr.id and r.state = 'reserved';
      update promotions.reward_reservations
         set state = 'released', settled_at = now()
       where attribution_id = v_attr.id and state = 'reserved';
      if v_release > 0 then
        update promotions.campaign_state
           set reserved_paise = reserved_paise - v_release, updated_at = now()
         where version_key = v_campaign.campaign_version;
        v_released := v_released + v_release;
      end if;
      update promotions.referral_attributions
         set disqualified_at = now(), disqualification_reason = 'qualification_window_expired',
             current_streak_days = 0
       where id = v_attr.id and disqualified_at is null and qualified_at is null;
      v_count := v_count + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'processed', v_count,
    'releasedPaise', v_released::text,
    'confirmedAt', now()
  );
end
$$;

create or replace function promotions.record_reward_worker_heartbeat(
  p_worker_id text,
  p_claimed integer default 0,
  p_completed integer default 0,
  p_error_code text default null
)
returns timestamptz
language plpgsql volatile security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_heartbeat timestamptz;
begin
  if p_worker_id is null or length(p_worker_id) not between 1 and 120
     or p_worker_id ~ '[^a-zA-Z0-9._:-]'
     or p_claimed is null or p_claimed not between 0 and 100
     or p_completed is null or p_completed not between 0 and 100
     or (p_error_code is not null and p_error_code !~ '^[a-z][a-z0-9_]{0,63}$') then
    raise exception using errcode = '22023', message = 'invalid_worker_heartbeat';
  end if;
  insert into promotions.reward_worker_heartbeats
    (worker_id, heartbeat_at, polls, claimed_events, completed_events, last_error_code)
  values (p_worker_id, now(), 1, p_claimed, p_completed, p_error_code)
  on conflict (worker_id) do update set
    heartbeat_at = excluded.heartbeat_at,
    polls = promotions.reward_worker_heartbeats.polls + 1,
    claimed_events = promotions.reward_worker_heartbeats.claimed_events + excluded.claimed_events,
    completed_events = promotions.reward_worker_heartbeats.completed_events + excluded.completed_events,
    last_error_code = excluded.last_error_code
  returning heartbeat_at into v_heartbeat;
  return v_heartbeat;
end
$$;

reset role;

alter table promotions.reward_outbox_attempts owner to promotions_owner;
alter table promotions.reward_worker_heartbeats owner to promotions_owner;
revoke all on table promotions.reward_outbox_attempts from public, app_user, rewards_worker;
revoke all on table promotions.reward_worker_heartbeats from public, app_user, rewards_worker;
revoke all on table promotions.reward_outbox from app_user, rewards_worker;
revoke execute on function promotions.claim_reward_outbox(text, integer, integer)
  from public, app_user;
revoke execute on function promotions.finalize_reward_outbox(uuid, uuid, boolean, jsonb, text, boolean)
  from public, app_user;
grant execute on function promotions.claim_reward_outbox(text, integer, integer)
  to rewards_worker;
grant execute on function promotions.finalize_reward_outbox(uuid, uuid, boolean, jsonb, text, boolean)
  to rewards_worker;
revoke execute on function promotions.expire_referral_reservations(integer)
  from public, app_user;
revoke execute on function promotions.record_reward_worker_heartbeat(text, integer, integer, text)
  from public, app_user;
grant execute on function promotions.expire_referral_reservations(integer)
  to rewards_worker;
grant execute on function promotions.record_reward_worker_heartbeat(text, integer, integer, text)
  to rewards_worker;

comment on table promotions.reward_outbox_attempts is
  'Immutable-per-claim audit rows for internal reward event processing; no payout/subscription side effects.';
comment on function promotions.claim_reward_outbox(text, integer, integer) is
  'SKIP LOCKED, bounded, lease-token-fenced claim; expires outbox metadata after 30 days plus 24-hour grace.';
comment on function promotions.finalize_reward_outbox(uuid, uuid, boolean, jsonb, text, boolean) is
  'Fenced internal event completion with durable result and capped retry/backoff; never mutates money or subscriptions.';
comment on function promotions.expire_referral_reservations(integer) is
  'Releases unqualified referral maximum liability only after deadline plus signed-receipt submission grace.';
comment on table promotions.reward_worker_heartbeats is
  'Last-seen worker heartbeat and aggregate counters for operator monitoring.';
