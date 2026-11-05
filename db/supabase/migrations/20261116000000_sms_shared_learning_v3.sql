-- Learning loop A2: one opt-in (policy sms-shared-learning-v3) covers every
-- shared learning signal. Only a latest-record grant at the v3 policy counts.
-- Revoking already scrubs open fixes (sms_v2_correction_consent_withdrawal,
-- 20261112160000) and removes layout submissions (sms_v2_revoke_template_consent).
CREATE FUNCTION pandapay.sms_shared_learning_granted(p_profile uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((
    SELECT granted AND policy_version = 'sms-shared-learning-v3'
      FROM user_consents
     WHERE profile_id = p_profile AND purpose = 'sms_shared_learning'
     ORDER BY granted_at DESC, granted ASC, id DESC
     LIMIT 1), false)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_shared_learning_granted(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_shared_learning_granted(uuid) TO app_user, pandapay_admin_api;

-- Layout admission: same body as 20261112190000 with the consent check replaced.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_submit_templates(p_items jsonb,p_eligible boolean) RETURNS SETOF text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE profile uuid; item jsonb; hash text; day date; used integer; n integer; existing sms_v2_unknown_templates; BEGIN
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
  IF used+jsonb_array_length(p_items)>50 THEN RAISE EXCEPTION 'template daily cap' USING ERRCODE='P0050'; END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    hash := item->>'templateHash';
    IF hash !~ '^[0-9a-f]{64}$' OR coalesce(item->>'senderBrand','') !~ '^[A-Z0-9]{1,32}$'
       OR length(coalesce(item->>'redactedBody','')) NOT BETWEEN 1 AND 20000
       OR (item->>'redactedBody') ~ '[0-9]{6,}'
       OR (item->>'redactedBody') ~* '(https?://|www[.]|[[:alnum:]_.+-]+@[[:alnum:]_.-]+|[[:alnum:]-]+[.](com|net|org|in|co|io|ly|me)(/|[[:space:]]|$))'
       OR (item->>'redactedBody') ~ '[+]?[0-9]([ -]?[0-9]){9,}' THEN
      RAISE EXCEPTION 'template redaction invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO existing FROM sms_v2_unknown_templates WHERE template_hash=hash;
    IF FOUND AND existing.sender_brand<>item->>'senderBrand' THEN RAISE EXCEPTION 'template sender conflict' USING ERRCODE='22023'; END IF;
    INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,live,last_live_at,ai_status)
      VALUES(hash,item->>'senderBrand',item->>'redactedBody',
        p_eligible AND (item->>'observedAt')::timestamptz BETWEEN clock_timestamp()-interval '24 hours' AND clock_timestamp()+interval '5 minutes',
        CASE WHEN p_eligible THEN least((item->>'observedAt')::timestamptz,clock_timestamp()) ELSE NULL END,
        CASE WHEN p_eligible THEN 'queued' ELSE 'held' END)
    ON CONFLICT(template_hash) DO UPDATE SET
      last_seen=clock_timestamp(),
      redacted_body=CASE WHEN p_eligible AND sms_v2_unknown_templates.ai_status='held' THEN excluded.redacted_body ELSE sms_v2_unknown_templates.redacted_body END,
      live=sms_v2_unknown_templates.live OR excluded.live,
      last_live_at=greatest(sms_v2_unknown_templates.last_live_at,excluded.last_live_at),
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

-- The private worker's consent decision, and the results a phone may read,
-- follow the same rule.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_template_has_consent(p_profile uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT pandapay.admin_has_permission('learning.publish') OR
     current_setting('pandapay.admin_permission',true) IS DISTINCT FROM 'learning.publish' THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE='42501';
  END IF;
  RETURN pandapay.sms_shared_learning_granted(p_profile);
END $$;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_template_results(p_revision bigint) RETURNS TABLE(template_hash text,ai_status text,ai_draft jsonb,revision bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT t.template_hash,t.ai_status,t.ai_draft,greatest(t.result_revision,s.result_revision)
    FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
   WHERE s.profile_id=pandapay.uid() AND greatest(t.result_revision,s.result_revision)>p_revision
     AND pandapay.sms_shared_learning_granted(s.profile_id)
   ORDER BY greatest(t.result_revision,s.result_revision),t.template_hash LIMIT 500
$$;

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
  RETURN OLD;
END $$;
