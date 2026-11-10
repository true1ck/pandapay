-- The app's Gemini status bar: what happened to the message layouts a person's
-- phone sent for an AI draft, counted by state.
--
-- Only the caller's own layouts and only counts: no layout text, nothing about
-- anyone else. Unlike sms_v2_template_results it also counts layouts that were
-- held back because the phone was not counted (no App Check, not a tester), and
-- reports that as `eligible: false`. That is the case where nothing ever comes
-- back, and the person needs to be able to see it.
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
    'failed',   (count(*) FILTER (WHERE t.ai_status='failed'))::int
  )
    FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
   WHERE s.profile_id=pandapay.uid() AND pandapay.sms_shared_learning_granted(s.profile_id)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_summary() TO app_user;
