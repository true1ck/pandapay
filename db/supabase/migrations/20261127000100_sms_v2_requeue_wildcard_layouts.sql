-- Layouts refused only because they had more than four name slots are asked of the AI again.
--
-- The matcher now accepts a name slot that is followed by fixed text without counting it against that limit
-- (api/src/sms_v2/layout_matcher.js, MAX_ANCHORED_WILDCARDS). Layouts that failed with `layout_too_many_wildcards`
-- never reached the AI (no attempt, no tokens), so they go back in the queue once. One that the matcher still refuses
-- fails the same way and stays failed; nothing loops because the failure comes from the matcher, not a provider.
UPDATE sms_v2_unknown_templates t
   SET ai_status = 'queued', failure_code = NULL, failure_detail = NULL, ai_retries = 0, ai_job_attempts = 0,
       queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
       result_revision = nextval('sms_v2_template_revision')
 WHERE t.ai_status = 'failed'
   AND t.failure_code = 'layout_too_many_wildcards'
   AND t.admin_decision IS DISTINCT FROM 'rejected';
