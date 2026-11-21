-- Layouts that failed for reasons that are gone are asked of the AI again, once.
--
-- 1. `layout_pattern_too_long`: the matcher now builds a long notice with shorter stops and allows 1,990 characters
--    (api/src/sms_v2/layout_matcher.js), so such a layout is no longer refused for its length. It failed before any AI call.
-- 2. `draft_validation_failed` with `answer_not_json`: every route's reply was unusable while Gemini was failing (the
--    service answered 502 invalid_provider_output); the same layouts are answered fine now. They had used all their tries
--    under the current prompt, so the hourly requeue never takes them back.
-- A layout that still fails fails again with the same code; nothing loops.
UPDATE sms_v2_unknown_templates t
   SET ai_status = 'queued', failure_code = NULL, failure_detail = NULL, ai_retries = 0, ai_job_attempts = 0,
       queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
       result_revision = nextval('sms_v2_template_revision')
 WHERE t.ai_status = 'failed'
   AND t.admin_decision IS DISTINCT FROM 'rejected'
   AND (t.failure_code = 'layout_pattern_too_long'
        OR (t.failure_code = 'draft_validation_failed' AND t.failure_detail::text LIKE '%answer_not_json%'));
