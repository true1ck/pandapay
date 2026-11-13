-- Gemini "could not draft N formats": give layouts that failed through no fault
-- of their own another chance, and stop counting an admin's rejection as a
-- Gemini failure.
--
-- Before this, a layout the AI worker marked `failed` stayed failed for ever. The
-- worker's login cannot update a failed row, and nothing else tried again. A
-- provider outage before the worker learned to wait, a worker restart during a
-- draft, or a crash all became permanent. A layout whose drafts were genuinely
-- rejected (the model answered and the draft did not validate) is NOT retried.

ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN IF NOT EXISTS ai_retries integer NOT NULL DEFAULT 0;

-- Core: no caller check, so the migration can run it. Not granted to anyone.
CREATE FUNCTION pandapay.sms_v2_ai_requeue_failed_core(p_max integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE moved integer;
BEGIN
  UPDATE sms_v2_unknown_templates t
     SET ai_status = 'queued', failure_code = NULL, ai_retries = t.ai_retries + 1,
         lease_id = NULL, lease_expires_at = NULL,
         result_revision = nextval('sms_v2_template_revision')
   WHERE t.ai_status = 'failed'
     AND t.admin_decision IS DISTINCT FROM 'rejected'
     AND t.failure_code IS DISTINCT FROM 'admin_rejected'
     AND t.ai_retries < p_max
     AND (
       t.failure_code IN ('worker_failed', 'worker_interrupted', 'provider_unavailable')
       -- Failed with no answer from the model ever: every try came back empty.
       OR NOT EXISTS (SELECT 1 FROM sms_v2_template_attempts a
                       WHERE a.template_hash = t.template_hash AND coalesce(a.total_tokens, 0) > 0)
     );
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_failed_core(integer) FROM PUBLIC;

-- Worker entry point: the AI worker login or the private admin API
-- (learning.publish), at most three retries per layout.
CREATE FUNCTION pandapay.sms_v2_ai_requeue_failed() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  RETURN pandapay.sms_v2_ai_requeue_failed_core(3);
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_failed() FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_failed() TO pandapay_admin_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_failed() TO sms_ai_worker;
  END IF;
END $$;

-- One-off: the layouts already stuck as failed (this is the "22 formats" case).
SELECT pandapay.sms_v2_ai_requeue_failed_core(3);

-- The app's status bar: an admin's rejection of a draft is a decision, not a
-- Gemini failure, so it no longer counts as one.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_summary() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'eligible', coalesce(bool_or(s.eligible), false),
    'total',    count(*)::int,
    'held',     (count(*) FILTER (WHERE t.ai_status='held'))::int,
    'queued',   (count(*) FILTER (WHERE t.ai_status='queued'))::int,
    'working',  (count(*) FILTER (WHERE t.ai_status='working'))::int,
    'ready',    (count(*) FILTER (WHERE t.ai_status='ready'))::int,
    'covered',  (count(*) FILTER (WHERE t.ai_status='covered'))::int,
    'failed',   (count(*) FILTER (WHERE t.ai_status='failed'
                                    AND t.failure_code IS DISTINCT FROM 'admin_rejected'))::int
  )
    FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
   WHERE s.profile_id=pandapay.uid() AND pandapay.sms_shared_learning_granted(s.profile_id)
$$;
