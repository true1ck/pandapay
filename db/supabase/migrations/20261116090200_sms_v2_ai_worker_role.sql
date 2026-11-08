-- SMS v2 AI drafts worker: a dedicated least-privilege database login.
--
-- `sms_ai_worker` is created (opt-in, from SMS_AI_WORKER_DB_PASSWORD) by
-- db/setup_app_role.sql, exactly like sms_learning_worker. It lets the AI worker
-- run on the production backend host without the private admin API login. It can:
--   * read the template queue and update ONLY the worker-owned columns of queued
--     or working rows (never held, blocked, decided or published ones);
--   * read and write the attempt and capacity counters;
--   * read ACTIVE rules and the admin's AI settings;
--   * ask two functions below for aggregate answers (how many consenting people
--     submitted a layout; how many people reported each kind of correction).
-- It cannot read profiles, consents, submitters, correction cases, SMS data or
-- anything else, has no BYPASSRLS, and cannot publish or approve anything.
-- The table privileges are granted by db/setup_app_role.sql (it re-runs after
-- the migrations); this file holds the policies and functions, which are inert
-- when the role does not exist.

CREATE POLICY sms_ai_worker_read ON public.sms_v2_unknown_templates
  FOR SELECT USING (current_user = 'sms_ai_worker');
CREATE POLICY sms_ai_worker_update ON public.sms_v2_unknown_templates
  FOR UPDATE USING (current_user = 'sms_ai_worker' AND ai_status IN ('queued', 'working'))
  WITH CHECK (current_user = 'sms_ai_worker' AND ai_status IN ('queued', 'working', 'ready', 'failed', 'covered'));

CREATE POLICY sms_ai_worker_read ON public.sms_v2_template_attempts
  FOR SELECT USING (current_user = 'sms_ai_worker');
CREATE POLICY sms_ai_worker_insert ON public.sms_v2_template_attempts
  FOR INSERT WITH CHECK (current_user = 'sms_ai_worker');
CREATE POLICY sms_ai_worker_update ON public.sms_v2_template_attempts
  FOR UPDATE USING (current_user = 'sms_ai_worker') WITH CHECK (current_user = 'sms_ai_worker');

CREATE POLICY sms_ai_worker_read ON public.sms_v2_ai_capacity
  FOR SELECT USING (current_user = 'sms_ai_worker');
CREATE POLICY sms_ai_worker_insert ON public.sms_v2_ai_capacity
  FOR INSERT WITH CHECK (current_user = 'sms_ai_worker');
CREATE POLICY sms_ai_worker_update ON public.sms_v2_ai_capacity
  FOR UPDATE USING (current_user = 'sms_ai_worker') WITH CHECK (current_user = 'sms_ai_worker');

CREATE POLICY sms_ai_worker_active_rules ON public.sms_v2_rules
  FOR SELECT USING (current_user = 'sms_ai_worker' AND status = 'active');
CREATE POLICY sms_ai_worker_settings ON public.sms_v2_settings
  FOR SELECT USING (current_user = 'sms_ai_worker');

-- Aggregate answers for the worker. The caller must be the worker login, or the
-- private admin API acting with the learning.publish permission (the local
-- path), so no other login can use them to probe consent or corrections.
CREATE FUNCTION pandapay.sms_v2_ai_consent_people(p_hash text) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT count(*)::integer FROM sms_v2_template_submitters s
           WHERE s.template_hash = p_hash AND s.eligible
             AND coalesce((SELECT c.granted FROM user_consents c
                            WHERE c.profile_id = s.profile_id AND c.purpose = 'sms_shared_learning'
                            ORDER BY c.granted_at DESC, c.granted ASC, c.id DESC LIMIT 1), false));
END $$;

CREATE FUNCTION pandapay.sms_v2_ai_report_counts(p_hash text) RETURNS TABLE(correction_kind text, people bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT k.correction_kind, count(DISTINCT k.profile_id)
                 FROM sms_v2_correction_cases k
                WHERE k.template_hash = p_hash AND k.shared_learning_eligible
                GROUP BY k.correction_kind ORDER BY k.correction_kind;
END $$;

REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_consent_people(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_report_counts(text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_consent_people(text) TO pandapay_admin_api;
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_report_counts(text) TO pandapay_admin_api;
  END IF;
END $$;
