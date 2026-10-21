-- One atomic sliding-window reservation gate shared by all Gemini workers.
-- It records only request time and estimated token counts; no user, job,
-- sender, message, or provider credential is stored here.
begin;

create table if not exists public.ai_provider_reservations (
  id bigserial primary key,
  created_at timestamptz not null default clock_timestamp(),
  estimated_tokens integer not null check (estimated_tokens > 0 and estimated_tokens <= 20000)
);

create index if not exists idx_ai_provider_reservations_created
  on public.ai_provider_reservations (created_at);

create table if not exists public.ai_provider_capacity_checks (
  id bigserial primary key,
  checked_at timestamptz not null default clock_timestamp(),
  outcome text not null check (outcome in ('allowed', 'waiting', 'permanently_blocked')),
  estimated_tokens integer not null check (estimated_tokens > 0 and estimated_tokens <= 20000)
);

create index if not exists idx_ai_provider_capacity_checks_time
  on public.ai_provider_capacity_checks (checked_at);

-- No app role receives table privileges; all access goes through the narrow
-- SECURITY DEFINER reservation function, so the internal counter is not
-- subject to a caller's profile RLS identity (or exposed cross-user).
revoke all on public.ai_provider_reservations from public, app_user;
revoke all on sequence public.ai_provider_reservations_id_seq from public, app_user;
revoke all on public.ai_provider_capacity_checks from public, app_user;
revoke all on sequence public.ai_provider_capacity_checks_id_seq from public, app_user;

create or replace function pandapay.ai_reserve_provider_capacity(
  p_requests_per_minute integer,
  p_tokens_per_minute integer,
  p_estimated_tokens integer
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_window_start timestamptz;
  v_requests integer;
  v_tokens bigint;
  v_oldest timestamptz;
  v_wait_ms integer;
begin
  if p_requests_per_minute < 1 or p_requests_per_minute > 1000
     or p_tokens_per_minute < 100 or p_tokens_per_minute > 1000000
     or p_estimated_tokens < 1 or p_estimated_tokens > 20000 then
    raise exception 'invalid provider capacity request';
  end if;

  if p_estimated_tokens > p_tokens_per_minute then
    insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
    values (v_now, 'permanently_blocked', p_estimated_tokens);
    return jsonb_build_object('allowed', false, 'permanentlyBlocked', true,
                              'waitMs', 0, 'requestsRemaining', 0, 'tokensRemaining', 0);
  end if;

  -- Transaction-scoped advisory lock serializes the check-and-insert across
  -- API processes and worker replicas. A reservation cannot race another.
  perform pg_advisory_xact_lock(hashtextextended('pandapay.gemini.capacity.v1', 0));
  v_now := clock_timestamp();
  v_window_start := v_now - interval '60 seconds';

  delete from public.ai_provider_reservations where created_at <= v_now - interval '10 minutes';
  delete from public.ai_provider_capacity_checks where checked_at <= v_now - interval '24 hours';
  select count(*)::integer, coalesce(sum(estimated_tokens), 0)::bigint, min(created_at)
    into v_requests, v_tokens, v_oldest
    from public.ai_provider_reservations
   where created_at > v_window_start;

  if v_requests < p_requests_per_minute
     and v_tokens + p_estimated_tokens <= p_tokens_per_minute then
    insert into public.ai_provider_reservations (created_at, estimated_tokens)
    values (v_now, p_estimated_tokens);
    insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
    values (v_now, 'allowed', p_estimated_tokens);
    return jsonb_build_object('allowed', true, 'permanentlyBlocked', false,
      'waitMs', 0, 'requestsRemaining', p_requests_per_minute - v_requests - 1,
      'tokensRemaining', p_tokens_per_minute - v_tokens - p_estimated_tokens);
  end if;

  v_wait_ms := greatest(100, least(60000,
    coalesce(ceil(extract(epoch from (v_oldest + interval '60 seconds' - v_now)) * 1000)::integer, 1000)));
  insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
  values (v_now, 'waiting', p_estimated_tokens);
  return jsonb_build_object('allowed', false, 'permanentlyBlocked', false,
    'waitMs', v_wait_ms,
    'requestsRemaining', greatest(0, p_requests_per_minute - v_requests),
    'tokensRemaining', greatest(0, p_tokens_per_minute - v_tokens));
end;
$$;

revoke all on function pandapay.ai_reserve_provider_capacity(integer, integer, integer) from public;
grant execute on function pandapay.ai_reserve_provider_capacity(integer, integer, integer) to app_user;

create or replace function pandapay.ai_provider_admin_summary(
  p_requests_per_minute integer,
  p_tokens_per_minute integer
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_summary jsonb;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  if p_requests_per_minute < 1 or p_requests_per_minute > 1000
     or p_tokens_per_minute < 100 or p_tokens_per_minute > 1000000 then
    raise exception 'invalid provider limits';
  end if;
  delete from public.ai_provider_capacity_checks where checked_at <= clock_timestamp() - interval '24 hours';
  delete from public.ai_provider_reservations where created_at <= clock_timestamp() - interval '10 minutes';
  select jsonb_build_object(
    'requestsLastMinute', (select count(*)::integer from public.ai_provider_reservations where created_at > clock_timestamp() - interval '60 seconds'),
    'tokensLastMinute', (select coalesce(sum(estimated_tokens), 0)::bigint from public.ai_provider_reservations where created_at > clock_timestamp() - interval '60 seconds'),
    'requestsPerMinuteLimit', p_requests_per_minute,
    'tokensPerMinuteLimit', p_tokens_per_minute,
    'waitingLastMinute', (select count(*)::integer from public.ai_provider_capacity_checks where outcome = 'waiting' and checked_at > clock_timestamp() - interval '60 seconds'),
    'permanentlyBlockedLastMinute', (select count(*)::integer from public.ai_provider_capacity_checks where outcome = 'permanently_blocked' and checked_at > clock_timestamp() - interval '60 seconds')
  ) into v_summary;
  return v_summary;
end;
$$;

revoke all on function pandapay.ai_provider_admin_summary(integer, integer) from public;
grant execute on function pandapay.ai_provider_admin_summary(integer, integer) to app_user;

commit;
