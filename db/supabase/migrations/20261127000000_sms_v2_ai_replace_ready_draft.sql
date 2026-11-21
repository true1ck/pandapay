-- The AI drafts worker re-checks the drafts that are already "ready" with today's checks (api/src/sms_v2/jobs/draft_audit.js)
-- and replaces one that can be repaired. The row policy on sms_v2_unknown_templates lets the worker login update only rows
-- that are queued or working, and that stays: this function is the one narrow door.
--
-- It changes ONLY the `emit` of a draft (what the message means). The id, the match pattern, the template hash, the
-- examples, the sender and everything else must stay exactly as they were, so it cannot be used to put a different pattern
-- in front of phones. It does nothing unless the draft is still exactly `p_before`, still ready, has no admin decision and
-- still has a consenting submitter; the new result revision makes phones pull the new version. Returns whether it replaced.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_replace_ready_draft(p_hash text, p_before jsonb, p_after jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE changed integer;
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  IF p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_before) IS DISTINCT FROM 'object' OR jsonb_typeof(p_after) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_after->'emit') IS DISTINCT FROM 'array'
     OR (p_after - 'emit') IS DISTINCT FROM (p_before - 'emit') THEN
    RAISE EXCEPTION 'only the emit of a draft may change' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  UPDATE sms_v2_unknown_templates t
     SET ai_draft = p_after, result_revision = nextval('sms_v2_template_revision')
   WHERE t.template_hash = p_hash AND t.ai_status = 'ready' AND t.ai_draft = p_before
     AND t.admin_decision IS NULL AND pandapay.sms_v2_ai_consent_people(t.template_hash) > 0;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_replace_ready_draft(text, jsonb, jsonb) FROM PUBLIC;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_replace_ready_draft(text, jsonb, jsonb) TO sms_ai_worker;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_replace_ready_draft(text, jsonb, jsonb) TO pandapay_admin_api;
  END IF;
END $$;
