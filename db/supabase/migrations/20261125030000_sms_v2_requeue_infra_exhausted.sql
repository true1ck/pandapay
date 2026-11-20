-- A layout that ends in the terminal failure draft_infrastructure_exhausted (three exhausted cycles in a row, see
-- template_worker.js INFRA_EXHAUSTION_CYCLES) failed because every route was in trouble, not because of anything in the layout.
-- Like draft_validation_failed it is therefore drafted once more for each new drafting version (the operator's signal that
-- something about drafting changed); the version is stamped, so it never loops, and counted jobs are per version, so the
-- layout gets a fresh three cycles. 20261125020000 left it out of the list; nothing else in the function changes, and
-- CREATE OR REPLACE keeps the grants.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_requeue_durable(p_version text) RETURNS integer
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
         ai_retries=ai_retries+CASE WHEN failure_code IN ('worker_failed','worker_interrupted','provider_unavailable','capacity') THEN 1 ELSE 0 END,
         ai_drafting_version=p_version, ai_job_attempts=0,
         ai_counted_jobs=coalesce((ai_counted_jobs_by_version->>p_version)::int,0),
         ai_run_after=clock_timestamp()+interval '1 minute', queued_at=clock_timestamp(),
         result_revision=nextval('sms_v2_template_revision')
   WHERE ai_status='failed' AND admin_decision IS DISTINCT FROM 'rejected'
     AND failure_code IS DISTINCT FROM 'admin_rejected'
     AND coalesce((ai_counted_jobs_by_version->>p_version)::int,0)<5
     AND ((failure_code IN ('draft_validation_failed','draft_layout_cap','draft_infrastructure_exhausted')
           AND ai_drafting_version IS DISTINCT FROM p_version)
          OR (failure_code='draft_rejected_by_users' AND admin_decision IS NULL
              AND ai_drafting_version IS DISTINCT FROM p_version)
          OR (failure_code IN ('worker_failed','worker_interrupted','provider_unavailable','capacity')
              AND ai_retries<3));
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
