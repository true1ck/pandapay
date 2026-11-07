-- Once an approved AI draft has been published as an active rule and a week has
-- passed, Gemini's raw draft is no longer needed: phones get the rule from the
-- signed bundle. The small decision record stays on the row (hash, status,
-- decision, reason, decider, timestamps, model, failure code), the redacted
-- layout stays as an example, the published rule is its own row, and token and
-- cost counters stay in sms_v2_template_attempts. A rejection already removed
-- the draft when it was decided.
-- Callable by the AI worker login or the private admin API (learning.publish).
CREATE FUNCTION pandapay.sms_v2_ai_cleanup_decided() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE cleaned integer;
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  UPDATE sms_v2_unknown_templates t SET ai_draft = NULL
   WHERE t.admin_decision IN ('approved', 'rejected') AND t.ai_draft IS NOT NULL
     AND t.decided_at < clock_timestamp() - interval '7 days'
     AND (t.admin_decision = 'rejected'
          OR EXISTS (SELECT 1 FROM sms_v2_rules r WHERE r.rule_id = 'AI-' || t.template_hash AND r.status = 'active'));
  GET DIAGNOSTICS cleaned = ROW_COUNT;
  RETURN cleaned;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_cleanup_decided() FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_cleanup_decided() TO pandapay_admin_api;
  END IF;
END $$;
