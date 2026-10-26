-- I11: bounded operational status and count-only health. This migration adds
-- no customer identifiers or content to the monitoring surface.
do $$ begin
  if not exists(select 1 from pg_catalog.pg_roles where rolname='notification_monitor') then
    create role notification_monitor nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
  end if;
  if exists(select 1 from pg_catalog.pg_roles where rolname='notification_monitor' and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
    raise exception 'unsafe notification_monitor role';
  end if;
  if exists(select 1 from pg_catalog.pg_auth_members where member='notification_monitor'::regrole) then
    raise exception 'notification_monitor must not be a member of another role';
  end if;
end $$;
grant usage on schema notification_delivery to notification_monitor;

set role notification_outbox_owner;

create table if not exists notification_delivery.worker_status(
  worker_id text primary key check(worker_id ~ '^[A-Za-z0-9._:-]{1,120}$'),
  heartbeat_at timestamptz not null,
  available boolean not null,
  blocked boolean not null,
  polls bigint not null default 0 check(polls>=0),
  claimed bigint not null default 0 check(claimed>=0),
  completed bigint not null default 0 check(completed>=0),
  failed bigint not null default 0 check(failed>=0),
  last_error_code text check(last_error_code is null or last_error_code ~ '^[a-z][a-z0-9_]{0,63}$')
);
alter table notification_delivery.worker_status enable row level security;
alter table notification_delivery.worker_status force row level security;
drop policy if exists notification_worker_status_owner on notification_delivery.worker_status;
create policy notification_worker_status_owner on notification_delivery.worker_status
  for all to notification_outbox_owner using(true) with check(true);
grant select,insert,update,delete on notification_delivery.worker_status to notification_outbox_owner;

create or replace function notification_delivery.report_worker_status(
  p_worker_id text, p_available boolean, p_blocked boolean,
  p_claimed integer, p_completed integer, p_failed integer, p_error_code text
)
returns boolean language plpgsql security definer set search_path=''
set lock_timeout='250ms' set statement_timeout='2s'
as $$
declare
  v_now timestamptz:=pg_catalog.clock_timestamp();
  v_known boolean;
  v_count integer;
begin
  if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9._:-]{1,120}$'
     or p_available is null or p_blocked is null or (p_available and p_blocked)
     or p_claimed is null or p_claimed not between 0 and 1
     or p_completed is null or p_completed not between 0 and 1
     or p_failed is null or p_failed not between 0 and 1
     or p_completed+p_failed>p_claimed
     or (p_error_code is not null and p_error_code !~ '^[a-z][a-z0-9_]{0,63}$') then
    raise exception 'invalid_notification_worker_status' using errcode='22023';
  end if;

  -- Serialize capacity changes without making callers wait behind another
  -- process. A missed telemetry sample is preferable to delaying a delivery.
  if not pg_catalog.pg_try_advisory_xact_lock(1313818964, 1) then return false; end if;
  select exists(select 1 from notification_delivery.worker_status where worker_id=p_worker_id)
    into v_known;
  if not v_known then
    delete from notification_delivery.worker_status where worker_id in (
      select worker_id from notification_delivery.worker_status
       where heartbeat_at < v_now-interval '1 day'
       order by heartbeat_at,worker_id limit 32
    );
    select count(*) into v_count from notification_delivery.worker_status;
    if v_count>=128 then return false; end if;
  end if;

  insert into notification_delivery.worker_status
    (worker_id,heartbeat_at,available,blocked,polls,claimed,completed,failed,last_error_code)
  values(p_worker_id,v_now,p_available,p_blocked,1,p_claimed,p_completed,p_failed,p_error_code)
  on conflict(worker_id) do update set
    heartbeat_at=excluded.heartbeat_at,
    available=excluded.available,
    blocked=excluded.blocked,
    polls=notification_delivery.worker_status.polls+1,
    claimed=notification_delivery.worker_status.claimed+excluded.claimed,
    completed=notification_delivery.worker_status.completed+excluded.completed,
    failed=notification_delivery.worker_status.failed+excluded.failed,
    last_error_code=excluded.last_error_code;
  return true;
end
$$;

-- Count-only health. Outbox size is capped at 10,000 and worker status at
-- 128, so this aggregate has a hard upper bound. Ages are seconds relative to
-- the DB clock. enabled is null because activation is runtime configuration.
create or replace function notification_delivery.health()
returns jsonb language plpgsql volatile security definer set search_path=''
set statement_timeout='2s'
as $$
declare
  v_now timestamptz:=pg_catalog.clock_timestamp();
  v_queued integer:=0; v_retained integer:=0;
  v_oldest_pending integer;
  v_expired_leased integer:=0; v_dead integer:=0; v_new_terminal_24h integer:=0;
  v_heartbeat_age integer; v_worker_rows integer:=0;
  v_blocked integer:=0; v_unavailable integer:=0; v_missing boolean:=true;
begin
  select coalesce(pending,0),coalesce(retained,0) into v_queued,v_retained
    from notification_delivery.global_queue_count where singleton;
  select case when min(created_at) is null then null
         else least(2147483647,greatest(0,floor(extract(epoch from v_now-min(created_at)))))::integer end
    into v_oldest_pending from notification_delivery.outbox where state='pending';
  select count(*) filter(where state='leased' and lease_until<=v_now),
         count(*) filter(where state='dead'),
         count(*) filter(where state in ('delivered','dead','suppressed') and completed_at>=v_now-interval '24 hours')
    into v_expired_leased,v_dead,v_new_terminal_24h
    from notification_delivery.outbox;
  select count(*),
         case when max(heartbeat_at) filter(where last_error_code is distinct from 'notification_worker_stopped') is null then null
              else least(2147483647,greatest(0,floor(extract(epoch from v_now-max(heartbeat_at) filter(where last_error_code is distinct from 'notification_worker_stopped')))))::integer end,
         count(*) filter(where blocked and last_error_code is distinct from 'notification_worker_stopped' and heartbeat_at>=v_now-interval '180 seconds'),
         count(*) filter(where not available and last_error_code is distinct from 'notification_worker_stopped' and heartbeat_at>=v_now-interval '180 seconds')
    into v_worker_rows,v_heartbeat_age,v_blocked,v_unavailable
    from notification_delivery.worker_status;
  v_missing:=coalesce(v_heartbeat_age is null or v_heartbeat_age>180,true);
  return pg_catalog.jsonb_build_object(
    'enabled',null,
    'queued',v_queued,
    'retained',v_retained,
    'max_queued',10000,
    'max_retained',10000,
    'oldest_pending_seconds',v_oldest_pending,
    'expired_leased',v_expired_leased,
    'dead',v_dead,
    'new_terminal_24h',v_new_terminal_24h,
    'worker_rows',v_worker_rows,
    'heartbeat_age_seconds',v_heartbeat_age,
    'missing_worker',v_missing,
    'blocked_workers',v_blocked,
    'unavailable_workers',v_unavailable
  );
end
$$;

revoke all on notification_delivery.worker_status from public,app_user,notification_worker,notification_monitor;
revoke all on function notification_delivery.report_worker_status(text,boolean,boolean,integer,integer,integer,text) from public,app_user,notification_monitor;
revoke all on function notification_delivery.health() from public,app_user,notification_worker;
grant execute on function notification_delivery.report_worker_status(text,boolean,boolean,integer,integer,integer,text) to notification_worker;
grant execute on function notification_delivery.health() to notification_monitor;
comment on function notification_delivery.report_worker_status(text,boolean,boolean,integer,integer,integer,text) is
  'Worker-only bounded heartbeat and aggregate counters; server clock is authoritative, no customer values accepted.';
comment on function notification_delivery.health() is
  'Monitor-only count/age summary; no customer identifiers, payloads, tokens, or event keys. enabled is intentionally null.';

reset role;
