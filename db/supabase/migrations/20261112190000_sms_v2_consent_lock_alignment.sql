-- WP-13/WP-12 privacy follow-up: one lock shared by the real consent
-- endpoint, corrections admission, template admission and withdrawal triggers.
-- Applied WP-10/WP-12 migrations remain immutable.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_submit_templates(p_items jsonb,p_eligible boolean) RETURNS SETOF text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE profile uuid; item jsonb; hash text; day date; used integer; n integer; existing sms_v2_unknown_templates; BEGIN
  profile := pandapay.uid();
  IF profile IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE='42501'; END IF;
  -- Use the existing consent-change lock so a concurrent revocation wins in order.
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:'||profile::text,0));
  IF NOT coalesce((SELECT granted FROM user_consents WHERE profile_id=profile AND purpose='sms_shared_learning'
      ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1),false) THEN
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
      WHERE s.template_hash=hash AND s.eligible AND coalesce((SELECT c.granted FROM user_consents c
        WHERE c.profile_id=s.profile_id AND c.purpose='sms_shared_learning'
        ORDER BY c.granted_at DESC,c.granted ASC,c.id DESC LIMIT 1),false);
    UPDATE sms_v2_unknown_templates SET seen_count=seen_count+CASE WHEN p_eligible THEN 1 ELSE 0 END,
      distinct_profiles=n,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=hash;
    RETURN NEXT hash;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_submit_templates(jsonb,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_submit_templates(jsonb,boolean) TO app_user;

CREATE OR REPLACE FUNCTION pandapay.sms_v2_revoke_template_consent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE current_granted boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:'||NEW.profile_id::text,0));
  SELECT granted INTO current_granted FROM public.user_consents
    WHERE profile_id=NEW.profile_id AND purpose='sms_shared_learning'
    ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1;
  IF current_granted IS FALSE THEN
    -- Drain template admissions already executing the old function body when
    -- this migration replaces it. New calls use the common extended lock.
    PERFORM pg_advisory_xact_lock(hashtext('sms-shared-learning-consent:'||NEW.profile_id::text));
    PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
    DELETE FROM public.sms_v2_template_submitters WHERE profile_id=NEW.profile_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_revoke_template_consent() FROM PUBLIC,app_user,pandapay_admin_api;
DROP TRIGGER sms_v2_revoke_template_consent ON user_consents;
CREATE TRIGGER sms_v2_revoke_template_consent AFTER INSERT OR UPDATE OF granted,granted_at ON user_consents
  FOR EACH ROW WHEN (NEW.purpose='sms_shared_learning')
  EXECUTE FUNCTION pandapay.sms_v2_revoke_template_consent();
