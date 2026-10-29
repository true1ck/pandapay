-- Admin console visibility for the Gemini SMS pipeline.
--
-- The console could see queue counts and fact-type names, but not why a job
-- failed, what the model actually decided, or how many completed jobs still
-- needed user review. Those diagnostics already exist in ai_jobs.payload /
-- ai_jobs.result and ai_events; this exposes them to the admin-only read
-- functions without ever returning raw SMS text or prompts.

begin;

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
    'failureCount24h', coalesce((select count(*)::int from public.ai_jobs
      where status = 'failed' and updated_at >= now() - interval '24 hours'), 0),
    'failureReasons24h', coalesce((select jsonb_object_agg(reason, count)
      from (select coalesce(payload->>'failReason', 'unknown') as reason, count(*)::int as count
              from public.ai_jobs
             where status = 'failed' and updated_at >= now() - interval '24 hours'
             group by 1) reasons), '{}'::jsonb),
    'doneToday', coalesce((select count(*)::int from public.ai_jobs
      where status = 'done' and updated_at::date = current_date), 0),
    'reviewRequiredToday', coalesce((select count(*)::int from public.ai_jobs
      where status = 'done' and updated_at::date = current_date
        and result->>'reviewRequired' = 'true'), 0),
    'autoResolvedToday', coalesce((select count(*)::int from public.ai_jobs
      where status = 'done' and updated_at::date = current_date
        and result->>'reviewRequired' = 'false'), 0),
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
             a.next_attempt_at, a.lease_expires_at,
             s.sender, a.result,
             -- Failure reason is a redacted code plus validator messages only;
             -- the original SMS body was purged when the job closed.
             a.payload->>'failReason' AS fail_reason,
             a.payload->'failureDetails' AS failure_details,
             (select e.payload->>'reason' from public.ai_events e
               where e.job_id = a.id and e.event_type = 'provider_retry'
               order by e.created_at desc limit 1) AS last_retry_reason,
             a.result->'decision' AS decision,
             a.result->'reviewRequired' AS review_required,
             a.result->'factTypes' AS fact_types
        from public.ai_jobs a left join public.sms_sources s on s.id = a.source_id
       where p_status is null or a.status = p_status
       order by a.created_at desc limit p_limit
    ) j;
  return v_jobs;
end;
$$;

revoke all on function pandapay.ai_admin_summary() from public;
revoke all on function pandapay.ai_admin_jobs(text, integer) from public;
grant execute on function pandapay.ai_admin_summary() to app_user;
grant execute on function pandapay.ai_admin_jobs(text, integer) to app_user;

commit;
