ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN ai_drafting_version text,
  ADD COLUMN ai_job_attempts integer NOT NULL DEFAULT 0 CHECK (ai_job_attempts BETWEEN 0 AND 3),
  ADD COLUMN ai_counted_jobs integer NOT NULL DEFAULT 0 CHECK (ai_counted_jobs BETWEEN 0 AND 5),
  ADD COLUMN ai_counted_jobs_by_version jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN ai_run_after timestamptz NOT NULL DEFAULT (CURRENT_TIMESTAMP + interval '1 minute');

CREATE INDEX sms_v2_draft_jobs_due
  ON public.sms_v2_unknown_templates (ai_run_after, queued_at, template_hash) WHERE ai_status = 'queued';
CREATE INDEX sms_v2_draft_jobs_expired
  ON public.sms_v2_unknown_templates (lease_expires_at, template_hash) WHERE ai_status = 'working';

ALTER TABLE public.sms_v2_template_attempts DROP CONSTRAINT sms_v2_template_attempts_attempt_check,
  ADD CONSTRAINT sms_v2_template_attempts_attempt_check CHECK (attempt BETWEEN 1 AND 8);

CREATE FUNCTION pandapay.sms_v2_draft_retry_delay(p_attempt integer) RETURNS interval
LANGUAGE sql VOLATILE SET search_path = pg_catalog AS $$
  SELECT CASE p_attempt
    WHEN 1 THEN interval '5 minutes' * (0.8 + random() * 0.4)
    WHEN 2 THEN interval '30 minutes' * (0.8 + random() * 0.4)
    ELSE interval '24 hours'
  END
$$;

-- The worker RLS policy deliberately prevents direct updates of terminal rows.
CREATE FUNCTION pandapay.sms_v2_ai_requeue_durable(p_version text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE moved integer;
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  IF p_version IS NULL OR p_version !~ '^[a-zA-Z0-9_.-]{1,64}$' THEN
    RAISE EXCEPTION 'invalid drafting version' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  UPDATE sms_v2_unknown_templates
     SET ai_status='queued', failure_code=NULL, failure_detail=NULL,
         ai_drafting_version=p_version, ai_job_attempts=0,
         ai_counted_jobs=coalesce((ai_counted_jobs_by_version->>p_version)::int,0),
         ai_run_after=clock_timestamp()+interval '1 minute', queued_at=clock_timestamp(),
         result_revision=nextval('sms_v2_template_revision')
   WHERE ai_status='failed' AND admin_decision IS DISTINCT FROM 'rejected'
     AND ai_drafting_version IS NOT NULL AND ai_drafting_version<>p_version
     AND coalesce((ai_counted_jobs_by_version->>p_version)::int,0)<5
     AND (failure_code IN ('draft_validation_failed','draft_layout_cap')
          OR (failure_code='draft_quarantined' AND admin_decision IS NULL));
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_durable(text) FROM PUBLIC;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT UPDATE (ai_drafting_version, ai_job_attempts, ai_counted_jobs, ai_counted_jobs_by_version, ai_run_after)
      ON public.sms_v2_unknown_templates TO sms_ai_worker;
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_durable(text) TO sms_ai_worker;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_durable(text) TO pandapay_admin_api;
  END IF;
END $$;
