-- SMS intelligence Phase 5: durable Gemini queue (single-item first).
--
-- One AI job == one SMS source. The job carries only the redacted body needed
-- for classification; a completed or failed job purges the payload. The device
-- already owns the raw Needs Review context; server failures retain only a reason code. Replaying the same source can never
-- create a second job or a second economic write: (profile_id, source_id) is
-- unique and results land through the Phase 1 fact upsert, which the
-- fact_overrides read path governs.
--
-- The worker leases one job at a time with an expiry; a crashed worker only
-- makes the same job leaseable again after the lease expires, so a 429,
-- crash or timeout costs a retry budget attempt, never a duplicate job.
-- Daily per-user quotas gate acceptance. No provider key lives in this
-- database; the worker signs its calls with a server-side token via env.

begin;

create table if not exists ai_jobs (
  id                uuid primary key default gen_random_uuid(),
  profile_id        uuid not null references profiles(id) on delete cascade,
  source_id         uuid references sms_sources(id) on delete set null,
  source_key        text not null,
  status            text not null default 'queued',
  kind              text not null default 'classify_sms',
  payload           jsonb not null default '{}'::jsonb,
  result            jsonb,
  attempts          integer not null default 0,
  lease_expires_at  timestamptz,
  lease_token       text,
  next_attempt_at  timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ai_jobs_status_known
    check (status in ('queued', 'leased', 'done', 'failed')),
  constraint ai_jobs_attempts_reasonable
    check (attempts >= 0 and attempts <= 10),
  constraint ai_jobs_payload_object
    check (jsonb_typeof(payload) = 'object')
);

comment on table ai_jobs is
  'One AI classification job per (profile, message source). A redacted body
exists only while the job is open and is purged on completion or failure.
Replays of the same source can never reopen the same job id.';

create unique index if not exists uq_ai_jobs_source
  on ai_jobs (profile_id, source_id);

-- Keep the legacy source-key identity as a second replay fence. The source
-- foreign key is nullable during retention/cleanup, so source_id alone must
-- never be the only deduplication key.
create unique index if not exists uq_ai_jobs_profile_source_key
  on ai_jobs (profile_id, source_key);

create index if not exists idx_ai_jobs_lease
  on ai_jobs (status, created_at)
  where status = 'queued';

create index if not exists idx_ai_jobs_lease_expired
  on ai_jobs (status, lease_expires_at)
  where status = 'leased';

create table if not exists ai_events (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references ai_jobs(id) on delete cascade,
  profile_id   uuid not null references profiles(id) on delete cascade,
  event_type   text not null,
  payload      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  constraint ai_events_type_not_empty
    check (length(event_type) > 0 and length(event_type) <= 64)
);

comment on table ai_events is
  'Append-only job timeline (accepted, leased, provider_retry, result,
refused, failed, purged). Redacted by design: payloads carry counters and
refusal reasons, never message bodies.';

create index if not exists idx_ai_events_job
  on ai_events (job_id, created_at);

create table if not exists ai_quota_days (
  profile_id   uuid not null references profiles(id) on delete cascade,
  day          date not null,
  jobs_used    integer not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (profile_id, day),
  constraint ai_quota_days_nonnegative
    check (jobs_used >= 0)
);

comment on table ai_quota_days is
  'Daily per-user acceptance counters. The acceptance gate reads and bumps
this instead of scanning ai_jobs, so quota checks stay one round trip.';

alter table ai_jobs enable row level security;
alter table ai_jobs force row level security;
drop policy if exists ai_jobs_owner on ai_jobs;
create policy ai_jobs_owner on ai_jobs
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

alter table ai_events enable row level security;
alter table ai_events force row level security;
drop policy if exists ai_events_owner on ai_events;
create policy ai_events_owner on ai_events
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

alter table ai_quota_days enable row level security;
alter table ai_quota_days force row level security;
drop policy if exists ai_quota_days_owner on ai_quota_days;
create policy ai_quota_days_owner on ai_quota_days
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

grant select, insert, update, delete on ai_jobs, ai_events, ai_quota_days to app_user;

-- The worker must claim across profiles, but it must not receive a general
-- RLS bypass. This narrowly scoped SECURITY DEFINER function claims exactly
-- one row and records its event in the same statement transaction. All other
-- reads/writes remain under the owning profile's normal app_user RLS context.
create or replace function pandapay.ai_claim_next_job(
  p_lease_token text,
  p_now timestamptz,
  p_lease_minutes integer,
  p_max_attempts integer
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_job public.ai_jobs%rowtype;
begin
  if p_lease_token is null or length(p_lease_token) < 32
     or p_lease_minutes < 1 or p_lease_minutes > 30
     or p_max_attempts < 1 or p_max_attempts > 10 then
    raise exception 'invalid lease request';
  end if;

  select * into v_job
    from public.ai_jobs
   where (status = 'queued' and coalesce(next_attempt_at, '-infinity'::timestamptz) <= p_now)
      or (status = 'leased' and lease_expires_at < p_now)
   order by created_at
   for update skip locked
   limit 1;

  if not found then return null; end if;

  if v_job.attempts >= p_max_attempts then
    update public.ai_jobs
       set status = 'failed', payload = jsonb_build_object('purged', true, 'failReason', 'lease_attempts_exhausted'),
           lease_token = null, lease_expires_at = null, updated_at = now()
     where id = v_job.id;
    insert into public.ai_events (job_id, profile_id, event_type, payload)
    values (v_job.id, v_job.profile_id, 'failed', jsonb_build_object('reason', 'lease_attempts_exhausted'));
    return jsonb_build_object('id', v_job.id, 'abandoned', true);
  end if;

  update public.ai_jobs
     set status = 'leased', lease_expires_at = p_now + make_interval(mins => p_lease_minutes),
         lease_token = p_lease_token, attempts = attempts + 1,
         next_attempt_at = null, updated_at = now()
   where id = v_job.id
   returning * into v_job;

  insert into public.ai_events (job_id, profile_id, event_type, payload)
  values (v_job.id, v_job.profile_id, 'leased',
          jsonb_build_object('attempts', v_job.attempts, 'leaseMinutes', p_lease_minutes));

  return jsonb_build_object(
    'id', v_job.id,
    'profileId', v_job.profile_id,
    'sourceKey', v_job.source_key,
    'sourceId', v_job.source_id,
    'attempts', v_job.attempts,
    'payload', v_job.payload,
    'leaseToken', v_job.lease_token,
    'leaseExpiresAt', v_job.lease_expires_at
  );
end;
$$;

revoke all on function pandapay.ai_claim_next_job(text, timestamptz, integer, integer) from public;
grant execute on function pandapay.ai_claim_next_job(text, timestamptz, integer, integer) to app_user;

create or replace function pandapay.ai_admin_summary()
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_summary jsonb;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  select jsonb_build_object(
    'statusCounts', coalesce((select jsonb_object_agg(status, count)
      from (select status, count(*)::int as count from public.ai_jobs group by status) counts), '{}'::jsonb),
    'oldestAgeSeconds', coalesce((select extract(epoch from (now() - min(created_at)))::int
      from public.ai_jobs where status = 'queued'), 0),
    'totalJobsToday', coalesce((select sum(jobs_used)::int from public.ai_quota_days where day = current_date), 0),
    'retryCount', (select count(*)::int from public.ai_events where event_type = 'provider_retry'),
    'batchesToday', coalesce((select count(distinct payload->>'batchId')::int
      from public.ai_events where event_type = 'result' and created_at::date = current_date
        and payload ? 'batchId'), 0),
    'batchedJobsToday', coalesce((select count(*)::int from public.ai_events
      where event_type = 'result' and created_at::date = current_date
        and payload->>'batchSize' ~ '^[2-4]$'), 0)
  ) into v_summary;
  return v_summary;
end;
$$;

create or replace function pandapay.ai_admin_jobs(p_status text, p_limit integer)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_jobs jsonb;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  if p_limit < 1 or p_limit > 200 then raise exception 'invalid limit'; end if;
  select coalesce(jsonb_agg(to_jsonb(j)), '[]'::jsonb) into v_jobs
    from (
      select a.id, a.status, a.source_key, a.attempts, a.created_at, a.updated_at,
             s.sender, a.result
        from public.ai_jobs a left join public.sms_sources s on s.id = a.source_id
       where p_status is null or a.status = p_status
       order by a.created_at desc limit p_limit
    ) j;
  return v_jobs;
end;
$$;

create or replace function pandapay.ai_admin_events(p_job_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_events jsonb;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]'::jsonb) into v_events
    from (select id, event_type, payload, created_at from public.ai_events
           where job_id = p_job_id order by created_at limit 500) e;
  return v_events;
end;
$$;

create or replace function pandapay.ai_admin_quota()
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_quota jsonb;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.day desc), '[]'::jsonb) into v_quota
    from (
      select left(encode(extensions.digest(profile_id::text, 'sha256'), 'hex'), 12) as user_key,
             day, jobs_used, updated_at
        from public.ai_quota_days
       where day >= current_date - interval '7 days'
       order by day desc limit 100
    ) q;
  return v_quota;
end;
$$;

revoke all on function pandapay.ai_admin_summary() from public;
revoke all on function pandapay.ai_admin_jobs(text, integer) from public;
revoke all on function pandapay.ai_admin_events(uuid) from public;
revoke all on function pandapay.ai_admin_quota() from public;
grant execute on function pandapay.ai_admin_summary() to app_user;
grant execute on function pandapay.ai_admin_jobs(text, integer) to app_user;
grant execute on function pandapay.ai_admin_events(uuid) to app_user;
grant execute on function pandapay.ai_admin_quota() to app_user;

commit;
