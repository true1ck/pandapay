-- AI pipeline reliability (22 Nov 2026, from the reliability audit).
--
-- 1. A draft job walks up to 15 routes (MAX_DRAFT_ROUTE_CALLS in template_worker.js) but the attempts table allowed 8, so the
--    9th attempt of a job with four or more providers failed its INSERT and the paid calls were repeated next time.
-- 2. `failed_at` says when a layout failed (a trigger stamps it), so a failure can be retried after a time without guessing.
-- 3. `sms_v2_ai_retry_mine`: the person's own "Try again" for layouts they submitted. Bounded per layout so a crafted client
--    cannot keep a layout cycling through paid AI calls.
-- 4. `sms_v2_ai_requeue_stale`: the worker's slow automatic retry of layouts that failed for reasons that can pass (the AI
--    was down or answered badly): after 1, 3, 9 and 27 days, four times at most, a few at a time. Deterministic refusals
--    (layout_*), admin decisions and paused rules are never retried here.

ALTER TABLE public.sms_v2_template_attempts DROP CONSTRAINT sms_v2_template_attempts_attempt_check,
  ADD CONSTRAINT sms_v2_template_attempts_attempt_check CHECK (attempt BETWEEN 1 AND 16);

ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN IF NOT EXISTS failed_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_user_retries integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_user_retry_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_auto_retries integer NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_template_failed_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF NEW.ai_status = 'failed' AND (TG_OP = 'INSERT' OR OLD.ai_status IS DISTINCT FROM 'failed') THEN
    NEW.failed_at := clock_timestamp();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sms_v2_template_failed_at ON public.sms_v2_unknown_templates;
CREATE TRIGGER sms_v2_template_failed_at BEFORE INSERT OR UPDATE OF ai_status ON public.sms_v2_unknown_templates
  FOR EACH ROW EXECUTE FUNCTION pandapay.sms_v2_template_failed_at();

CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_retry_mine(p_hashes text[]) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me uuid; moved integer;
BEGIN
  me := pandapay.uid();
  IF me IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE = '42501'; END IF;
  IF p_hashes IS NULL OR cardinality(p_hashes) NOT BETWEEN 1 AND 20
     OR EXISTS (SELECT 1 FROM unnest(p_hashes) AS h WHERE h IS NULL OR h !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION 'retry hashes invalid' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || me::text, 0));
  IF NOT pandapay.sms_shared_learning_granted(me) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  -- Only the person's own layouts, only the failures that can pass, at most 3 presses in 7 days and one an hour per layout
  -- (a layout is shared by everyone who sent it, so the cap is on the layout, not on the person). A press goes to the back
  -- of the queue and gives the layout a fresh set of tries; the quorum budget (ai_user_replacements) is not touched.
  UPDATE sms_v2_unknown_templates t
     SET ai_status = 'queued', failure_code = NULL, failure_detail = NULL, ai_job_attempts = 0, ai_counted_jobs = 0,
         ai_counted_jobs_by_version = coalesce(t.ai_counted_jobs_by_version - t.ai_drafting_version, t.ai_counted_jobs_by_version),
         ai_run_after = clock_timestamp(), queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
         ai_excluded_providers = '{}'::text[],
         ai_user_retries = CASE WHEN t.ai_user_retry_at IS NULL OR t.ai_user_retry_at < clock_timestamp() - interval '7 days'
                                THEN 1 ELSE t.ai_user_retries + 1 END,
         ai_user_retry_at = clock_timestamp(),
         result_revision = nextval('sms_v2_template_revision')
   WHERE t.template_hash = ANY (p_hashes)
     AND t.ai_status = 'failed'
     AND t.admin_decision IS NULL
     AND t.failure_code IN ('draft_validation_failed', 'draft_layout_cap', 'draft_infrastructure_exhausted',
                            'draft_rejected_by_users', 'provider_unavailable', 'worker_failed', 'worker_interrupted', 'capacity')
     AND (t.ai_user_retry_at IS NULL OR t.ai_user_retry_at < clock_timestamp() - interval '1 hour')
     AND (t.ai_user_retries < 3 OR t.ai_user_retry_at < clock_timestamp() - interval '7 days')
     AND EXISTS (SELECT 1 FROM sms_v2_template_submitters s
                  WHERE s.template_hash = t.template_hash AND s.profile_id = me AND s.eligible);
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_retry_mine(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_retry_mine(text[]) TO app_user;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_requeue_stale() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE moved integer;
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  WITH due AS (
    SELECT template_hash FROM sms_v2_unknown_templates
     WHERE ai_status = 'failed' AND admin_decision IS NULL
       AND failure_code IN ('draft_validation_failed', 'draft_layout_cap', 'draft_infrastructure_exhausted',
                            'provider_unavailable', 'worker_failed', 'worker_interrupted', 'capacity')
       AND ai_auto_retries < 4
       AND coalesce(failed_at, '-infinity'::timestamptz) <= clock_timestamp() - interval '1 day' * power(3, ai_auto_retries)
       AND pandapay.sms_v2_ai_consent_people(template_hash) > 0
     ORDER BY failed_at NULLS FIRST, template_hash
     LIMIT 25 FOR UPDATE SKIP LOCKED
  )
  UPDATE sms_v2_unknown_templates t
     SET ai_status = 'queued', failure_code = NULL, failure_detail = NULL, ai_job_attempts = 0, ai_counted_jobs = 0,
         ai_counted_jobs_by_version = coalesce(t.ai_counted_jobs_by_version - t.ai_drafting_version, t.ai_counted_jobs_by_version),
         ai_auto_retries = t.ai_auto_retries + 1,
         ai_run_after = clock_timestamp() + interval '1 minute', queued_at = clock_timestamp(),
         lease_id = NULL, lease_expires_at = NULL, ai_excluded_providers = '{}'::text[],
         result_revision = nextval('sms_v2_template_revision')
    FROM due WHERE t.template_hash = due.template_hash;
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_stale() FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_stale() TO pandapay_admin_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_stale() TO sms_ai_worker;
  END IF;
END $$;
