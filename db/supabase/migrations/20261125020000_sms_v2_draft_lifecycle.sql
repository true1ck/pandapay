-- AI draft lifecycle fixes (QA audit, stages 1, 2 and 5). Needs 20261123090000 (durable draft jobs) and
-- 20261123100000 (draft feedback). Both are older than this file in name order, so a database that applied
-- the feedback migration first and the durable one later is fine; one that has neither is refused here.
--
--  * A replacement (a quarantine by phones, or an admin requeue) starts a fresh durable job: attempts, wait
--    and counted jobs are reset, so it neither inherits the old draft's attempts nor is refused by the cap.
--  * The durable requeue names the failure codes the code really writes.
--  * Quarantine needs a share of the submitters, counts only current consenting submitters, is re-checked when a
--    submitter leaves, and one account can trigger only a few replacements a day.
--  * Revoking sharing deletes the person's draft deliveries and rejections too.
--  * Intake checks templateHash = sha256(senderBrand || E'\n' || redactedBody), exactly what the phone computes
--    (contracts/sms/v2/fixtures/template_hash_vectors.json, written by the real Dart code), and charges the day's
--    layouts once per layout.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_name = 'sms_v2_unknown_templates' AND column_name = 'ai_job_attempts')
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_name = 'sms_v2_unknown_templates' AND column_name = 'ai_user_replacements') THEN
    RAISE EXCEPTION 'needs migrations 20261123090000 (durable draft jobs) and 20261123100000 (draft feedback)';
  END IF;
END $$;

ALTER TABLE public.sms_v2_draft_rejections ADD COLUMN IF NOT EXISTS replaced_at timestamptz;
CREATE INDEX IF NOT EXISTS sms_v2_draft_rejections_replaced
  ON public.sms_v2_draft_rejections (profile_id, replaced_at) WHERE replaced_at IS NOT NULL;

-- Quorum for one layout's current draft. Called, with the results lock held, after every report and whenever a
-- submitter leaves. n = rejecters of the current revision who are still eligible, consenting submitters and are
-- within their daily replacement budget; d = all such submitters. Replace when n >= least(3, d) (the DESIGN
-- quorum) and n is at least half of d, so a few accounts cannot outvote the honest submitters of a popular layout.
CREATE FUNCTION pandapay.sms_v2_draft_quorum(p_hash text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t sms_v2_unknown_templates; n integer; d integer; ids uuid[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  SELECT * INTO t FROM sms_v2_unknown_templates WHERE template_hash = p_hash FOR UPDATE;
  -- An admin decision (approved or rejected) is never overridden by phones: evidence only.
  IF NOT FOUND OR t.ai_status <> 'ready' OR t.admin_decision IS NOT NULL THEN RETURN; END IF;
  SELECT count(*) INTO d FROM sms_v2_template_submitters s
   WHERE s.template_hash = p_hash AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id);
  SELECT count(*), coalesce(array_agg(j.profile_id), '{}') INTO n, ids
    FROM sms_v2_draft_rejections j
    JOIN sms_v2_template_submitters s ON s.template_hash = j.template_hash AND s.profile_id = j.profile_id AND s.eligible
   WHERE j.template_hash = p_hash AND j.draft_revision = t.ai_draft_revision
     AND pandapay.sms_shared_learning_granted(j.profile_id)
     AND (SELECT count(*) FROM sms_v2_draft_rejections k
           WHERE k.profile_id = j.profile_id AND k.replaced_at > clock_timestamp() - interval '1 day')
         < pandapay.sms_v2_limit(j.profile_id, 'draft_replacements_per_user_per_day', 5);
  IF n < least(3, greatest(d, 1)) OR n * 2 < d THEN RETURN; END IF;
  IF t.ai_user_replacements >= 2 THEN
    UPDATE sms_v2_unknown_templates SET ai_status = 'failed', failure_code = 'draft_rejected_by_users',
           ai_draft = NULL, lease_id = NULL, lease_expires_at = NULL,
           result_revision = nextval('sms_v2_template_revision')
     WHERE template_hash = p_hash;
  ELSE
    UPDATE sms_v2_draft_rejections SET replaced_at = clock_timestamp()
     WHERE template_hash = p_hash AND draft_revision = t.ai_draft_revision AND profile_id = ANY(ids);
    -- A replacement is a new durable job: all three tries, due now, its own counted jobs.
    UPDATE sms_v2_unknown_templates SET ai_status = 'queued', ai_draft = NULL, failure_code = NULL,
           failure_detail = NULL, ai_user_replacements = ai_user_replacements + 1,
           ai_job_attempts = 0, ai_run_after = clock_timestamp(), ai_counted_jobs = 0,
           ai_counted_jobs_by_version = CASE WHEN ai_drafting_version IS NULL THEN ai_counted_jobs_by_version
                                             ELSE ai_counted_jobs_by_version - ai_drafting_version END,
           queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
           result_revision = nextval('sms_v2_template_revision')
     WHERE template_hash = p_hash;
  END IF;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_draft_quorum(text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_report_draft_rejection(p_draft_id uuid, p_reason text) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me uuid; dl sms_v2_draft_deliveries; t sms_v2_unknown_templates; added integer;
BEGIN
  me := pandapay.uid();
  IF me IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('no_match', 'invalid_facts', 'unsafe_rule') THEN
    RAISE EXCEPTION 'draft rejection reason invalid' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || me::text, 0));
  IF NOT pandapay.sms_shared_learning_granted(me) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  SELECT * INTO dl FROM sms_v2_draft_deliveries WHERE draft_id = p_draft_id AND profile_id = me;
  IF NOT FOUND THEN RAISE EXCEPTION 'draft not delivered' USING ERRCODE = 'P0404'; END IF;

  INSERT INTO sms_v2_draft_rejections (profile_id, template_hash, draft_revision, reason)
    VALUES (me, dl.template_hash, dl.draft_revision, p_reason) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS added = ROW_COUNT;

  SELECT * INTO t FROM sms_v2_unknown_templates WHERE template_hash = dl.template_hash FOR UPDATE;
  -- The reporter's own phone learns of its rejection through its own revision (a stale report moves nothing).
  IF added = 1 AND FOUND AND t.ai_status = 'ready' AND t.ai_draft_revision = dl.draft_revision THEN
    UPDATE sms_v2_template_submitters SET result_revision = nextval('sms_v2_template_revision')
     WHERE template_hash = dl.template_hash AND profile_id = me;
  END IF;
  -- Also on a repeat: it settles a draft left unreplaced because the submitters changed.
  PERFORM pandapay.sms_v2_draft_quorum(dl.template_hash);
  RETURN CASE WHEN added = 1 THEN 'recorded' ELSE 'already_recorded' END;
END $$;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_template_submitter_deleted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE eligible_count integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  DELETE FROM sms_v2_unknown_templates t WHERE t.template_hash=OLD.template_hash
    AND NOT EXISTS(SELECT 1 FROM sms_v2_template_submitters s WHERE s.template_hash=t.template_hash);
  SELECT count(*) INTO eligible_count FROM sms_v2_template_submitters s WHERE s.template_hash=OLD.template_hash AND s.eligible
    AND pandapay.sms_shared_learning_granted(s.profile_id);
  UPDATE sms_v2_unknown_templates SET distinct_profiles=eligible_count,
    ai_status=CASE WHEN eligible_count=0 AND ai_status IN ('queued','working') THEN 'held' ELSE ai_status END,
    lease_id=CASE WHEN eligible_count=0 THEN NULL ELSE lease_id END,
    lease_expires_at=CASE WHEN eligible_count=0 THEN NULL ELSE lease_expires_at END,
    result_revision=nextval('sms_v2_template_revision') WHERE template_hash=OLD.template_hash;
  -- Fewer submitters can complete the quorum for a draft that phones already rejected.
  PERFORM pandapay.sms_v2_draft_quorum(OLD.template_hash);
  RETURN OLD;
END $$;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_revoke_template_consent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE current_granted boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:'||NEW.profile_id::text,0));
  SELECT granted INTO current_granted FROM public.user_consents
    WHERE profile_id=NEW.profile_id AND purpose='sms_shared_learning'
    ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1;
  IF current_granted IS FALSE THEN
    PERFORM pg_advisory_xact_lock(hashtext('sms-shared-learning-consent:'||NEW.profile_id::text));
    PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
    -- What the person shared goes, including which drafts they were shown and what they reported about them.
    DELETE FROM public.sms_v2_draft_rejections WHERE profile_id=NEW.profile_id;
    DELETE FROM public.sms_v2_draft_deliveries WHERE profile_id=NEW.profile_id;
    DELETE FROM public.sms_v2_template_submitters WHERE profile_id=NEW.profile_id;
  END IF;
  RETURN NEW;
END $$;

-- Retry of failed layouts in durable mode (the worker calls it hourly with its drafting version).
--  * draft_validation_failed, draft_layout_cap, draft_rejected_by_users (no admin decision): the draft or the
--    cap depended on the drafting version, so a layout is tried once for each new version. A layout that never ran
--    under a durable version (NULL, failed before 20261123090000) counts as an older version.
--  * worker_failed, worker_interrupted, provider_unavailable, capacity: not the layout's fault, retried whatever the
--    version, at most three times (ai_retries), like the legacy requeue did.
--  * admin_rejected and any admin-rejected layout never move.
-- Every moved layout is stamped with the version and gets a fresh job, so a failing layout cannot loop.
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
     AND ((failure_code IN ('draft_validation_failed','draft_layout_cap')
           AND ai_drafting_version IS DISTINCT FROM p_version)
          OR (failure_code='draft_rejected_by_users' AND admin_decision IS NULL
              AND ai_drafting_version IS DISTINCT FROM p_version)
          OR (failure_code IN ('worker_failed','worker_interrupted','provider_unavailable','capacity')
              AND ai_retries<3));
  GET DIAGNOSTICS moved = ROW_COUNT;
  RETURN moved;
END $$;

-- Layout intake. Same checks as 20261123080000 plus:
--  * templateHash must be sha256(senderBrand || E'\n' || redactedBody), what the phone computes, so a client
--    cannot claim a hash for a different body or brand (nor make a victim's batch fail with a sender conflict);
--  * a layout already counted for this person today is neither counted again nor does it count toward the cap;
--  * the second column says whether each layout was new for this person today (the API charges its rate bucket
--    only for those).
CREATE FUNCTION pandapay.sms_v2_submit_templates_counted(p_items jsonb,p_eligible boolean)
RETURNS TABLE(accepted_hash text, fresh boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE profile uuid; item jsonb; hash text; day date; used integer; newn integer; n integer; existing sms_v2_unknown_templates; smp text; seen_day date; BEGIN
  profile := pandapay.uid();
  IF profile IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE='42501'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:'||profile::text,0));
  IF NOT pandapay.sms_shared_learning_granted(profile) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE='42501';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>50 THEN
    RAISE EXCEPTION 'invalid template batch' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  day := (now() AT TIME ZONE 'utc')::date;
  SELECT coalesce(sum(day_count),0) INTO used FROM sms_v2_template_submitters WHERE profile_id=profile AND submission_day=day;
  SELECT count(DISTINCT x.h) INTO newn FROM (SELECT value->>'templateHash' AS h FROM jsonb_array_elements(p_items)) x
    WHERE NOT EXISTS (SELECT 1 FROM sms_v2_template_submitters s WHERE s.profile_id=profile AND s.template_hash=x.h AND s.submission_day=day);
  IF used+newn>pandapay.sms_v2_limit(profile,'templates_per_user_per_day',50) THEN RAISE EXCEPTION 'template daily cap' USING ERRCODE='P0050'; END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    hash := item->>'templateHash';
    IF hash !~ '^[0-9a-f]{64}$' OR coalesce(item->>'senderBrand','') !~ '^[A-Z0-9]{1,32}$'
       OR length(coalesce(item->>'redactedBody','')) NOT BETWEEN 1 AND 20000
       OR (item->>'redactedBody') ~ '[0-9]{6,}'
       OR (item->>'redactedBody') ~* '(https?://|www[.]|[[:alnum:]_.+-]+@[[:alnum:]_.-]+|[[:alnum:]-]+[.](com|net|org|in|co|io|ly|me)(/|[[:space:]]|$))'
       OR (item->>'redactedBody') ~ '[+]?[0-9]([ -]?[0-9]){9,}' THEN
      RAISE EXCEPTION 'template redaction invalid' USING ERRCODE='22023';
    END IF;
    IF hash <> encode(sha256(convert_to((item->>'senderBrand')||E'\n'||(item->>'redactedBody'),'UTF8')),'hex') THEN
      RAISE EXCEPTION 'template hash invalid' USING ERRCODE='22023';
    END IF;
    smp := nullif(item->>'sample','');
    IF smp IS NOT NULL AND (length(smp)>2000
       OR smp ~* '(https?://|www[.]|[[:alnum:]_.+-]+@[[:alnum:]_.-]+|[[:alnum:]-]+[.](com|net|org|in|co|io|ly|me)(/|[[:space:]]|$))') THEN
      RAISE EXCEPTION 'template sample invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO existing FROM sms_v2_unknown_templates WHERE template_hash=hash;
    IF FOUND AND existing.sender_brand<>item->>'senderBrand' THEN RAISE EXCEPTION 'template sender conflict' USING ERRCODE='22023'; END IF;
    SELECT s.submission_day INTO seen_day FROM sms_v2_template_submitters s WHERE s.template_hash=hash AND s.profile_id=profile;
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
      day_count=CASE WHEN sms_v2_template_submitters.submission_day=day THEN sms_v2_template_submitters.day_count ELSE 1 END,
      result_revision=nextval('sms_v2_template_revision');
    SELECT count(*) INTO n FROM sms_v2_template_submitters s
      WHERE s.template_hash=hash AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id);
    UPDATE sms_v2_unknown_templates SET seen_count=seen_count+CASE WHEN p_eligible THEN 1 ELSE 0 END,
      distinct_profiles=n,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=hash;
    accepted_hash := hash;
    fresh := seen_day IS DISTINCT FROM day;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_submit_templates_counted(jsonb,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_submit_templates_counted(jsonb,boolean) TO app_user;

-- The one-column form stays for callers that only want the accepted hashes.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_submit_templates(p_items jsonb,p_eligible boolean) RETURNS SETOF text
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT accepted_hash FROM pandapay.sms_v2_submit_templates_counted(p_items,p_eligible)
$$;
