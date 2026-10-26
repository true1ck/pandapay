-- Shared, privacy-preserving admission for the signed-out feedback routes and
-- authenticated profile submissions. The runtime gets only this capability.
begin;

do $$ begin
  if not exists(select 1 from pg_roles where rolname='feedback_admission_owner') then
    create role feedback_admission_owner nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
  end if;
  if exists(select 1 from pg_roles where rolname='feedback_admission_owner' and
    (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls)) then
    raise exception 'unsafe feedback admission owner';
  end if;
end $$;
create schema if not exists feedback_admission;
revoke all on schema feedback_admission from public;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'pandapay_feedback_admission') then
    create role pandapay_feedback_admission nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
  end if;
end $$;
alter role pandapay_feedback_admission nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
grant usage on schema feedback_admission to pandapay_feedback_admission;
grant usage,create on schema feedback_admission to feedback_admission_owner;
set role feedback_admission_owner;

create table if not exists feedback_admission.buckets (
  route_bucket text not null check (route_bucket in ('support_tickets','data_error_reports')),
  identity_digest text not null check (identity_digest ~ '^[0-9a-f]{64}$'),
  authenticated boolean not null,
  hit_count integer not null check (hit_count between 1 and 30),
  window_started_at timestamptz not null,
  expires_at timestamptz not null,
  primary key (route_bucket, identity_digest, authenticated),
  check (expires_at = window_started_at + interval '1 hour')
);
create index if not exists buckets_expires_at_idx on feedback_admission.buckets (expires_at);
revoke all on feedback_admission.buckets from public, pandapay_feedback_admission;

create table if not exists feedback_admission.capacity (
  singleton boolean primary key default true check (singleton),
  used_rows integer not null check (used_rows between 0 and 250000)
);
revoke all on feedback_admission.capacity from public, pandapay_feedback_admission;
alter table feedback_admission.buckets enable row level security;
alter table feedback_admission.buckets force row level security;
drop policy if exists feedback_bucket_owner on feedback_admission.buckets;
create policy feedback_bucket_owner on feedback_admission.buckets for all to feedback_admission_owner using(true) with check(true);
alter table feedback_admission.capacity enable row level security;
alter table feedback_admission.capacity force row level security;
drop policy if exists feedback_capacity_owner on feedback_admission.capacity;
create policy feedback_capacity_owner on feedback_admission.capacity for all to feedback_admission_owner using(true) with check(true);
insert into feedback_admission.capacity(singleton, used_rows)
  select true, count(*)::integer from feedback_admission.buckets
  on conflict (singleton) do nothing;

create or replace function feedback_admission.consume(
  p_route_bucket text, p_identity_digest text, p_authenticated boolean
) returns table(allowed boolean, retry_after_seconds integer)
language plpgsql security definer
set search_path = pg_catalog, feedback_admission
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_limit integer;
  v_row feedback_admission.buckets%rowtype;
  v_capacity integer;
  v_pruned integer;
  v_acquired boolean;
begin
  if p_route_bucket is null or p_route_bucket not in ('support_tickets','data_error_reports')
     or p_identity_digest is null or p_identity_digest !~ '^[0-9a-f]{64}$'
     or p_authenticated is null then
    raise exception using errcode='22023', message='invalid feedback admission arguments';
  end if;
  v_limit := case when p_authenticated then 5 else 30 end;
  -- Never wait behind another admission caller. The service returns a retryable
  -- 503 for this bounded contention failure.
  v_acquired := pg_try_advisory_xact_lock(742019261);
  if not v_acquired then
    raise exception using errcode='P0001', message='feedback admission busy';
  end if;
  -- Prune at most 500 expired rows in index order and maintain exact capacity.
  with expired as (
    delete from feedback_admission.buckets b
     where b.ctid in (
       select ctid from feedback_admission.buckets
        where expires_at <= v_now order by expires_at limit 500
     )
     returning 1
  ) select count(*)::integer into v_pruned from expired;
  if v_pruned > 0 then
    update feedback_admission.capacity set used_rows=used_rows-v_pruned where singleton;
  end if;
  select * into v_row from feedback_admission.buckets
    where route_bucket=p_route_bucket and identity_digest=p_identity_digest and authenticated=p_authenticated
    for update;
  if found then
    if v_row.expires_at > v_now and v_row.hit_count >= v_limit then
      return query select false, greatest(1, ceil(extract(epoch from (v_row.expires_at-v_now)))::integer);
      return;
    end if;
    update feedback_admission.buckets
       set hit_count=case when expires_at <= v_now then 1 else hit_count+1 end,
           window_started_at=case when expires_at <= v_now then v_now else window_started_at end,
           expires_at=case when expires_at <= v_now then v_now+interval '1 hour' else expires_at end
      where route_bucket=p_route_bucket and identity_digest=p_identity_digest and authenticated=p_authenticated;
    return query select true, 0;
    return;
  end if;
  select used_rows into v_capacity from feedback_admission.capacity where singleton for update;
  if v_capacity is null then raise exception using errcode='P0001', message='feedback admission capacity unavailable'; end if;
  if v_capacity >= 250000 then
    raise exception using errcode='P0001', message='feedback admission capacity exhausted';
  end if;
  insert into feedback_admission.buckets(route_bucket,identity_digest,authenticated,hit_count,window_started_at,expires_at)
    values(p_route_bucket,p_identity_digest,p_authenticated,1,v_now,v_now+interval '1 hour')
    on conflict(route_bucket,identity_digest,authenticated) do update
      set hit_count=1,window_started_at=excluded.window_started_at,expires_at=excluded.expires_at;
  update feedback_admission.capacity set used_rows=used_rows+1 where singleton;
  return query select true, 0;
end $$;
revoke all on function feedback_admission.consume(text,text,boolean) from public;
grant execute on function feedback_admission.consume(text,text,boolean) to pandapay_feedback_admission;
comment on function feedback_admission.consume(text,text,boolean) is
  'Atomic fixed-window feedback admission. Accepts only keyed opaque identity digests; fixed route allowlist, 5/profile and 30/IP hourly caps, 250k row ceiling.';
reset role;
commit;
