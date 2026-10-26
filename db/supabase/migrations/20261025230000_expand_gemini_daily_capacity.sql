-- Expand Gemini provider daily capacity to support up to 3,000 requests/day across dual-key pool
begin;

create or replace function pandapay.ai_reserve_provider_capacity(
  p_requests_per_minute integer,
  p_tokens_per_minute integer,
  p_requests_per_day integer,
  p_estimated_tokens integer
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_window_start timestamptz;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_requests integer;
  v_daily_requests integer;
  v_tokens bigint;
  v_oldest timestamptz;
  v_wait_ms integer;
begin
  if p_requests_per_minute < 1 or p_requests_per_minute > 30
     or p_tokens_per_minute < 100 or p_tokens_per_minute > 2000000
     or p_requests_per_day < 1 or p_requests_per_day > 3000
     or p_estimated_tokens < 1 or p_estimated_tokens > 20000 then
    raise exception 'invalid free-tier provider capacity request';
  end if;

  if p_estimated_tokens > p_tokens_per_minute then
    insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
    values (v_now, 'permanently_blocked', p_estimated_tokens);
    return jsonb_build_object('allowed', false, 'permanentlyBlocked', true,
                              'waitMs', 0, 'requestsRemaining', 0, 'tokensRemaining', 0);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('pandapay.gemini.capacity.v1', 0));
  v_now := clock_timestamp();
  v_window_start := v_now - interval '60 seconds';
  v_day_start := date_trunc('day', v_now at time zone 'America/Los_Angeles')
                 at time zone 'America/Los_Angeles';
  v_day_end := ((v_now at time zone 'America/Los_Angeles')::date + 1)::timestamp
               at time zone 'America/Los_Angeles';

  delete from public.ai_provider_reservations where created_at < v_day_start;
  delete from public.ai_provider_capacity_checks where checked_at <= v_now - interval '24 hours';
  select count(*)::integer, coalesce(sum(estimated_tokens), 0)::bigint, min(created_at)
    into v_requests, v_tokens, v_oldest
    from public.ai_provider_reservations
   where created_at > v_window_start;
  select count(*)::integer
    into v_daily_requests
    from public.ai_provider_reservations
   where created_at >= v_day_start;

  if v_daily_requests >= p_requests_per_day then
    v_wait_ms := greatest(100, least(60000,
      ceil(extract(epoch from (v_day_end - v_now)) * 1000)::integer));
    insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
    values (v_now, 'waiting', p_estimated_tokens);
    return jsonb_build_object('allowed', false, 'permanentlyBlocked', false,
      'dailyLimitReached', true, 'waitMs', v_wait_ms,
      'retryAfterMs', greatest(1000, ceil(extract(epoch from (v_day_end - v_now)) * 1000)::bigint),
      'requestsRemaining', 0,
      'requestsTodayRemaining', 0, 'tokensRemaining', greatest(0, p_tokens_per_minute - v_tokens));
  end if;

  if v_requests < p_requests_per_minute
     and v_tokens + p_estimated_tokens <= p_tokens_per_minute then
    insert into public.ai_provider_reservations (created_at, estimated_tokens)
    values (v_now, p_estimated_tokens);
    insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
    values (v_now, 'allowed', p_estimated_tokens);
    return jsonb_build_object('allowed', true, 'permanentlyBlocked', false,
      'waitMs', 0, 'requestsRemaining', p_requests_per_minute - v_requests - 1,
      'requestsTodayRemaining', p_requests_per_day - v_daily_requests - 1,
      'tokensRemaining', p_tokens_per_minute - v_tokens - p_estimated_tokens);
  end if;

  v_wait_ms := greatest(100, least(60000,
    coalesce(ceil(extract(epoch from (v_oldest + interval '60 seconds' - v_now)) * 1000)::integer, 1000)));
  insert into public.ai_provider_capacity_checks (checked_at, outcome, estimated_tokens)
  values (v_now, 'waiting', p_estimated_tokens);
  return jsonb_build_object('allowed', false, 'permanentlyBlocked', false,
    'waitMs', v_wait_ms,
    'requestsRemaining', greatest(0, p_requests_per_minute - v_requests),
    'requestsTodayRemaining', greatest(0, p_requests_per_day - v_daily_requests),
    'tokensRemaining', greatest(0, p_tokens_per_minute - v_tokens));
end;
$$;

revoke all on function pandapay.ai_reserve_provider_capacity(integer, integer, integer, integer) from public;
grant execute on function pandapay.ai_reserve_provider_capacity(integer, integer, integer, integer) to app_user;

create or replace function pandapay.ai_provider_admin_summary(
  p_requests_per_minute integer,
  p_tokens_per_minute integer,
  p_requests_per_day integer
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_summary jsonb;
        v_day_start timestamptz;
begin
  if not pandapay.is_admin() then raise exception 'admin required' using errcode = '42501'; end if;
  if p_requests_per_minute < 1 or p_requests_per_minute > 30
     or p_tokens_per_minute < 100 or p_tokens_per_minute > 2000000
     or p_requests_per_day < 1 or p_requests_per_day > 3000 then
    raise exception 'invalid free-tier provider limits';
  end if;
  v_day_start := date_trunc('day', clock_timestamp() at time zone 'America/Los_Angeles')
                 at time zone 'America/Los_Angeles';
  delete from public.ai_provider_capacity_checks where checked_at <= clock_timestamp() - interval '24 hours';
  delete from public.ai_provider_reservations where created_at < v_day_start;
  select jsonb_build_object(
    'requestsLastMinute', (select count(*)::integer from public.ai_provider_reservations where created_at > clock_timestamp() - interval '60 seconds'),
    'tokensLastMinute', (select coalesce(sum(estimated_tokens), 0)::bigint from public.ai_provider_reservations where created_at > clock_timestamp() - interval '60 seconds'),
    'requestsPerMinuteLimit', p_requests_per_minute,
    'tokensPerMinuteLimit', p_tokens_per_minute,
    'requestsToday', (select count(*)::integer from public.ai_provider_reservations where created_at >= v_day_start),
    'requestsPerDayLimit', p_requests_per_day,
    'waitingLastMinute', (select count(*)::integer from public.ai_provider_capacity_checks where outcome = 'waiting' and checked_at > clock_timestamp() - interval '60 seconds'),
    'permanentlyBlockedLastMinute', (select count(*)::integer from public.ai_provider_capacity_checks where outcome = 'permanently_blocked' and checked_at > clock_timestamp() - interval '60 seconds')
  ) into v_summary;
  return v_summary;
end;
$$;

revoke all on function pandapay.ai_provider_admin_summary(integer, integer, integer) from public;
grant execute on function pandapay.ai_provider_admin_summary(integer, integer, integer) to app_user;

-- Unstick any queued jobs that were deferred until midnight due to the old daily cap
update public.ai_jobs
   set next_attempt_at = now()
 where status = 'queued'
   and next_attempt_at > now();

commit;
