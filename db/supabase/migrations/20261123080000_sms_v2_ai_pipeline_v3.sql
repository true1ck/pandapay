-- SMS v2 AI drafts, pipeline v3.
--
--  * First in, first out: every queued layout has a `queued_at`; the worker takes the oldest.
--  * Failure reasons are kept (codes only, never message text), per attempt and per layout.
--  * A person's message with its numbers swapped for made-up ones (`sample`) is kept only while the
--    layout waits for the AI and is deleted when the answer is final.
--  * Layouts that failed under an older prompt are given another go once, when the prompt changes.

ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN IF NOT EXISTS queued_at timestamptz,
  ADD COLUMN IF NOT EXISTS sample text,
  ADD COLUMN IF NOT EXISTS failure_detail text[];

UPDATE public.sms_v2_unknown_templates SET queued_at = first_seen WHERE queued_at IS NULL;
ALTER TABLE public.sms_v2_unknown_templates
  ALTER COLUMN queued_at SET DEFAULT clock_timestamp(),
  ALTER COLUMN queued_at SET NOT NULL;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sms_v2_unknown_templates_sample_len') THEN
    ALTER TABLE public.sms_v2_unknown_templates
      ADD CONSTRAINT sms_v2_unknown_templates_sample_len CHECK (sample IS NULL OR length(sample) <= 2000);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS sms_v2_unknown_templates_queue
  ON public.sms_v2_unknown_templates (queued_at, template_hash) WHERE ai_status = 'queued';

ALTER TABLE public.sms_v2_template_attempts
  ADD COLUMN IF NOT EXISTS error_kind text,
  ADD COLUMN IF NOT EXISTS error_codes text[],
  ADD COLUMN IF NOT EXISTS http_status integer;

-- The worker login can only change the columns it owns (see db/setup_app_role.sql, which also grants these).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT UPDATE (sample, failure_detail) ON public.sms_v2_unknown_templates TO sms_ai_worker;
    GRANT UPDATE (error_kind, error_codes, http_status) ON public.sms_v2_template_attempts TO sms_ai_worker;
  END IF;
END $$;

-- Retry of failed layouts. `p_prompt_version` (the worker's current one) also retries a layout whose drafts
-- were rejected only under older prompts; a layout the current prompt already failed on stays failed.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_requeue_failed_core(p_max integer, p_prompt_version text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE moved integer;
BEGIN
  UPDATE sms_v2_unknown_templates t
     SET ai_status = 'queued', failure_code = NULL, failure_detail = NULL, ai_retries = t.ai_retries + 1,
         queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
         result_revision = nextval('sms_v2_template_revision')
   WHERE t.ai_status = 'failed'
     AND t.admin_decision IS DISTINCT FROM 'rejected'
     AND t.failure_code IS DISTINCT FROM 'admin_rejected'
     AND t.ai_retries < p_max
     AND (
       t.failure_code IN ('worker_failed', 'worker_interrupted', 'provider_unavailable', 'capacity')
       -- Failed with no answer from the model ever: every try came back empty.
       OR NOT EXISTS (SELECT 1 FROM sms_v2_template_attempts a
                       WHERE a.template_hash = t.template_hash AND coalesce(a.total_tokens, 0) > 0)
       OR (p_prompt_version IS NOT NULL AND t.failure_code = 'draft_validation_failed'
           AND NOT EXISTS (SELECT 1 FROM sms_v2_template_attempts a
                            WHERE a.template_hash = t.template_hash AND a.prompt_version = p_prompt_version))
     );
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_failed_core(integer, text) FROM PUBLIC;

-- The old one-argument core keeps working (the earlier migration ran it once).
CREATE OR REPLACE FUNCTION pandapay.sms_v2_ai_requeue_failed_core(p_max integer) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT pandapay.sms_v2_ai_requeue_failed_core(p_max, NULL)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_failed_core(integer) FROM PUBLIC;

CREATE FUNCTION pandapay.sms_v2_ai_requeue_failed(p_prompt_version text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF session_user IS DISTINCT FROM 'sms_ai_worker' AND NOT (
       pandapay.admin_has_permission('learning.publish')
       AND current_setting('pandapay.admin_permission', true) IS NOT DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE = '42501';
  END IF;
  RETURN pandapay.sms_v2_ai_requeue_failed_core(3, p_prompt_version);
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_ai_requeue_failed(text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pandapay_admin_api') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_failed(text) TO pandapay_admin_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sms_ai_worker') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_ai_requeue_failed(text) TO sms_ai_worker;
  END IF;
END $$;

-- Phones send an optional `sample` next to the layout. It is stored with a NEW layout, or added to a layout
-- that is still waiting; never to one already answered. `queued_at` is set when a layout enters the queue.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_submit_templates(p_items jsonb,p_eligible boolean) RETURNS SETOF text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE profile uuid; item jsonb; hash text; day date; used integer; n integer; existing sms_v2_unknown_templates; smp text; BEGIN
  profile := pandapay.uid();
  IF profile IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE='42501'; END IF;
  -- Use the existing consent-change lock so a concurrent revocation wins in order.
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:'||profile::text,0));
  IF NOT pandapay.sms_shared_learning_granted(profile) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE='42501';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>50 THEN
    RAISE EXCEPTION 'invalid template batch' USING ERRCODE='22023';
  END IF;
  -- Revision allocation is serialized through commit, including worker results.
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  day := (now() AT TIME ZONE 'utc')::date;
  SELECT coalesce(sum(day_count),0) INTO used FROM sms_v2_template_submitters WHERE profile_id=profile AND submission_day=day;
  IF used+jsonb_array_length(p_items)>pandapay.sms_v2_limit(profile,'templates_per_user_per_day',50) THEN RAISE EXCEPTION 'template daily cap' USING ERRCODE='P0050'; END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    hash := item->>'templateHash';
    IF hash !~ '^[0-9a-f]{64}$' OR coalesce(item->>'senderBrand','') !~ '^[A-Z0-9]{1,32}$'
       OR length(coalesce(item->>'redactedBody','')) NOT BETWEEN 1 AND 20000
       OR (item->>'redactedBody') ~ '[0-9]{6,}'
       OR (item->>'redactedBody') ~* '(https?://|www[.]|[[:alnum:]_.+-]+@[[:alnum:]_.-]+|[[:alnum:]-]+[.](com|net|org|in|co|io|ly|me)(/|[[:space:]]|$))'
       OR (item->>'redactedBody') ~ '[+]?[0-9]([ -]?[0-9]){9,}' THEN
      RAISE EXCEPTION 'template redaction invalid' USING ERRCODE='22023';
    END IF;
    -- The sample carries made-up digits, so only links, addresses and size are checked here.
    smp := nullif(item->>'sample','');
    IF smp IS NOT NULL AND (length(smp)>2000
       OR smp ~* '(https?://|www[.]|[[:alnum:]_.+-]+@[[:alnum:]_.-]+|[[:alnum:]-]+[.](com|net|org|in|co|io|ly|me)(/|[[:space:]]|$))') THEN
      RAISE EXCEPTION 'template sample invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO existing FROM sms_v2_unknown_templates WHERE template_hash=hash;
    IF FOUND AND existing.sender_brand<>item->>'senderBrand' THEN RAISE EXCEPTION 'template sender conflict' USING ERRCODE='22023'; END IF;
    INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,live,last_live_at,ai_status,sample,queued_at)
      VALUES(hash,item->>'senderBrand',item->>'redactedBody',
        p_eligible AND (item->>'observedAt')::timestamptz BETWEEN clock_timestamp()-interval '24 hours' AND clock_timestamp()+interval '5 minutes',
        CASE WHEN p_eligible THEN least((item->>'observedAt')::timestamptz,clock_timestamp()) ELSE NULL END,
        CASE WHEN p_eligible THEN 'queued' ELSE 'held' END,
        CASE WHEN p_eligible THEN smp ELSE NULL END,
        clock_timestamp())
    ON CONFLICT(template_hash) DO UPDATE SET
      last_seen=clock_timestamp(),
      redacted_body=CASE WHEN p_eligible AND sms_v2_unknown_templates.ai_status='held' THEN excluded.redacted_body ELSE sms_v2_unknown_templates.redacted_body END,
      live=sms_v2_unknown_templates.live OR excluded.live,
      last_live_at=greatest(sms_v2_unknown_templates.last_live_at,excluded.last_live_at),
      sample=CASE WHEN p_eligible AND sms_v2_unknown_templates.sample IS NULL AND sms_v2_unknown_templates.ai_status IN ('held','queued')
                  THEN smp ELSE sms_v2_unknown_templates.sample END,
      queued_at=CASE WHEN p_eligible AND sms_v2_unknown_templates.ai_status='held' THEN clock_timestamp() ELSE sms_v2_unknown_templates.queued_at END,
      ai_status=CASE WHEN p_eligible AND sms_v2_unknown_templates.ai_status='held' THEN 'queued' ELSE sms_v2_unknown_templates.ai_status END;
    INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible,submission_day,day_count)
      VALUES(hash,profile,p_eligible,day,1)
    ON CONFLICT(template_hash,profile_id) DO UPDATE SET
      eligible=sms_v2_template_submitters.eligible OR excluded.eligible,
      last_submitted=clock_timestamp(),submission_day=day,
      day_count=CASE WHEN sms_v2_template_submitters.submission_day=day THEN sms_v2_template_submitters.day_count+1 ELSE 1 END,
      result_revision=nextval('sms_v2_template_revision');
    SELECT count(*) INTO n FROM sms_v2_template_submitters s
      WHERE s.template_hash=hash AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id);
    UPDATE sms_v2_unknown_templates SET seen_count=seen_count+CASE WHEN p_eligible THEN 1 ELSE 0 END,
      distinct_profiles=n,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=hash;
    RETURN NEXT hash;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_submit_templates(jsonb,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_submit_templates(jsonb,boolean) TO app_user;
