-- Exercises SMS AI RLS, cross-user worker leasing, and provider capacity under
-- the real app_user role. Fixtures are rolled back on completion.
\set ON_ERROR_STOP on
begin;

insert into profiles (id, contributions_opt_in) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', true),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee2', true);

insert into financial_projections (
  profile_id, projection_kind, projection_key, status, projection
) values (
  'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', 'movement', 'synthetic-review-test',
  'posted', '{"amountInr":12}'::jsonb
);

insert into sms_sources (profile_id, source_key, sender, body_hash)
values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', repeat('a', 64), 'TESTBK', repeat('b', 64))
returning id as test_source_id \gset

insert into ai_jobs (profile_id, source_id, source_key, payload)
values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', :'test_source_id', repeat('a', 64),
        '{"body":"synthetic fixture"}'::jsonb)
returning id as test_job_id \gset

insert into ai_events (job_id, profile_id, event_type, payload)
values (:'test_job_id', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', 'accepted', '{}'::jsonb);

set local role app_user;
select set_config('app.user_id', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee2', true);

do $$
declare
  v_count integer;
  v_job jsonb;
  v_reservation jsonb;
begin
  select count(*) into v_count from public.ai_jobs;
  if v_count <> 0 then raise exception 'AI job RLS leaked another profile job'; end if;

  select count(*) into v_count from public.ai_events;
  if v_count <> 0 then raise exception 'AI event RLS leaked another profile event'; end if;

  select count(*) into v_count from public.financial_projections;
  if v_count <> 0 then raise exception 'central financial projection RLS leaked another profile'; end if;
  perform set_config('app.user_id', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1', true);
  select count(*) into v_count from public.financial_projections;
  if v_count <> 1 then raise exception 'owner cannot read their central financial projection'; end if;
  perform set_config('app.user_id', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee2', true);

  select pandapay.ai_claim_next_job(repeat('c', 64), now(), 6, 4) into v_job;
  if v_job->>'id' is null or v_job->>'profileId' <> 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1' then
    raise exception 'worker claim did not lease the queued job across profiles';
  end if;

  select pandapay.ai_reserve_provider_capacity(1, 1000, 20, 100) into v_reservation;
  if (v_reservation->>'allowed')::boolean is not true then
    raise exception 'first provider capacity reservation was denied';
  end if;
  select pandapay.ai_reserve_provider_capacity(1, 1000, 20, 100) into v_reservation;
  if (v_reservation->>'allowed')::boolean is not false
     or (v_reservation->>'permanentlyBlocked')::boolean is not false
     or (v_reservation->>'waitMs')::integer < 1 then
    raise exception 'RPM limiter did not return a retryable wait after capacity filled';
  end if;

  select pandapay.ai_reserve_provider_capacity(5, 10000, 1, 100) into v_reservation;
  if (v_reservation->>'allowed')::boolean is not false
     or (v_reservation->>'dailyLimitReached')::boolean is not true
     or (v_reservation->>'retryAfterMs')::bigint < 1000 then
    raise exception 'daily limiter did not return the next Pacific midnight retry delay';
  end if;
end;
$$;

rollback;
