-- Unknown SMS templates contain redacted text only. Public clients access them
-- through consent-checked functions and never read other profiles' submissions.
CREATE SEQUENCE sms_v2_template_revision;
CREATE TABLE sms_v2_unknown_templates (
  template_hash text PRIMARY KEY CHECK(template_hash ~ '^[0-9a-f]{64}$'),
  sender_brand text NOT NULL CHECK(sender_brand ~ '^[A-Z0-9]{1,32}$'),
  redacted_body text NOT NULL CHECK(length(redacted_body) BETWEEN 1 AND 20000),
  first_seen timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen timestamptz NOT NULL DEFAULT clock_timestamp(),
  live boolean NOT NULL DEFAULT false,
  last_live_at timestamptz,
  seen_count bigint NOT NULL DEFAULT 0,
  distinct_profiles integer NOT NULL DEFAULT 0,
  ai_status text NOT NULL CHECK(ai_status IN ('held','queued','working','ready','failed')),
  ai_draft jsonb,
  ai_model text,
  failure_code text,
  lease_id uuid,
  lease_expires_at timestamptz,
  result_revision bigint NOT NULL DEFAULT nextval('sms_v2_template_revision')
);
CREATE TABLE sms_v2_template_submitters (
  template_hash text NOT NULL REFERENCES sms_v2_unknown_templates ON DELETE CASCADE,
  profile_id uuid NOT NULL REFERENCES profiles ON DELETE CASCADE,
  eligible boolean NOT NULL DEFAULT false,
  first_submitted timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_submitted timestamptz NOT NULL DEFAULT clock_timestamp(),
  submission_day date NOT NULL DEFAULT (now() AT TIME ZONE 'utc')::date,
  day_count integer NOT NULL DEFAULT 0,
  result_revision bigint NOT NULL DEFAULT nextval('sms_v2_template_revision'),
  PRIMARY KEY(template_hash, profile_id)
);
CREATE INDEX sms_v2_template_submitters_profile ON sms_v2_template_submitters(profile_id,submission_day);
CREATE INDEX sms_v2_unknown_template_queue ON sms_v2_unknown_templates(ai_status,distinct_profiles DESC,live DESC,first_seen);
CREATE TABLE sms_v2_template_attempts (
  template_hash text NOT NULL CHECK(template_hash ~ '^[0-9a-f]{64}$'),
  job_id uuid NOT NULL,
  attempt integer NOT NULL CHECK(attempt IN (1,2)),
  model text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  input_tokens integer NOT NULL DEFAULT 0 CHECK(input_tokens >= 0),
  output_tokens integer NOT NULL DEFAULT 0 CHECK(output_tokens >= 0),
  total_tokens integer NOT NULL DEFAULT 0 CHECK(total_tokens >= 0),
  latency_ms integer NOT NULL DEFAULT 0 CHECK(latency_ms >= 0),
  capacity_minute timestamptz NOT NULL,
  reserved_tokens integer NOT NULL CHECK(reserved_tokens > 0),
  cost_usd numeric,
  outcome text NOT NULL DEFAULT 'started',
  PRIMARY KEY(job_id,attempt)
);
CREATE TABLE sms_v2_ai_capacity (
  minute timestamptz PRIMARY KEY,
  requests integer NOT NULL DEFAULT 0,
  reserved_tokens bigint NOT NULL DEFAULT 0
);

DO $$ DECLARE t text; write_guard text; BEGIN
  write_guard := 'pandapay.admin_has_permission(''learning.publish'') AND current_setting(''pandapay.admin_permission'',true)=''learning.publish''';
  FOREACH t IN ARRAY ARRAY['sms_v2_unknown_templates','sms_v2_template_submitters','sms_v2_template_attempts','sms_v2_ai_capacity'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY private_read ON %I FOR SELECT TO pandapay_admin_api USING (pandapay.admin_has_permission(''learning.read''))',t);
    EXECUTE format('CREATE POLICY private_write ON %I FOR ALL TO pandapay_admin_api USING (%s) WITH CHECK (%s)',t,write_guard,write_guard);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON %I TO pandapay_admin_api',t);
  END LOOP;
END $$;
GRANT USAGE,SELECT ON SEQUENCE sms_v2_template_revision TO pandapay_admin_api;

-- Private workers need only a consent decision, without browsing consent rows.
CREATE FUNCTION pandapay.sms_v2_template_has_consent(p_profile uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT pandapay.admin_has_permission('learning.publish') OR
     current_setting('pandapay.admin_permission',true) IS DISTINCT FROM 'learning.publish' THEN
    RAISE EXCEPTION 'private template worker permission required' USING ERRCODE='42501';
  END IF;
  RETURN coalesce((SELECT granted FROM user_consents WHERE profile_id=p_profile AND purpose='sms_shared_learning'
    ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1),false);
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_template_has_consent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_template_has_consent(uuid) TO pandapay_admin_api;

CREATE FUNCTION pandapay.sms_v2_submit_templates(p_items jsonb,p_eligible boolean) RETURNS SETOF text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE profile uuid; item jsonb; hash text; day date; used integer; n integer; existing sms_v2_unknown_templates; BEGIN
  profile := pandapay.uid();
  IF profile IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE='42501'; END IF;
  -- Use the existing consent-change lock so a concurrent revocation wins in order.
  PERFORM pg_advisory_xact_lock(hashtext('sms-shared-learning-consent:'||profile::text));
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

CREATE FUNCTION pandapay.sms_v2_template_results(p_revision bigint) RETURNS TABLE(template_hash text,ai_status text,ai_draft jsonb,revision bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT t.template_hash,t.ai_status,t.ai_draft,greatest(t.result_revision,s.result_revision)
    FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
   WHERE s.profile_id=pandapay.uid() AND greatest(t.result_revision,s.result_revision)>p_revision
     AND coalesce((SELECT c.granted FROM user_consents c WHERE c.profile_id=s.profile_id AND c.purpose='sms_shared_learning'
       ORDER BY c.granted_at DESC,c.granted ASC,c.id DESC LIMIT 1),false)
   ORDER BY greatest(t.result_revision,s.result_revision),t.template_hash LIMIT 500
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_template_results(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_template_results(bigint) TO app_user;

-- Erasing the submitting profile also removes orphan templates, while keeping
-- platform cost records. Remaining profiles retain only currently eligible data.
CREATE FUNCTION pandapay.sms_v2_template_submitter_deleted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE eligible_count integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  DELETE FROM sms_v2_unknown_templates t WHERE t.template_hash=OLD.template_hash
    AND NOT EXISTS(SELECT 1 FROM sms_v2_template_submitters s WHERE s.template_hash=t.template_hash);
  SELECT count(*) INTO eligible_count FROM sms_v2_template_submitters s WHERE s.template_hash=OLD.template_hash AND s.eligible
    AND coalesce((SELECT c.granted FROM user_consents c WHERE c.profile_id=s.profile_id AND c.purpose='sms_shared_learning'
      ORDER BY c.granted_at DESC,c.granted ASC,c.id DESC LIMIT 1),false);
  UPDATE sms_v2_unknown_templates SET distinct_profiles=eligible_count,
    ai_status=CASE WHEN eligible_count=0 AND ai_status IN ('queued','working') THEN 'held' ELSE ai_status END,
    lease_id=CASE WHEN eligible_count=0 THEN NULL ELSE lease_id END,
    lease_expires_at=CASE WHEN eligible_count=0 THEN NULL ELSE lease_expires_at END,
    result_revision=nextval('sms_v2_template_revision') WHERE template_hash=OLD.template_hash;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_template_submitter_deleted() FROM PUBLIC;
CREATE TRIGGER sms_v2_template_submitter_deleted AFTER DELETE ON sms_v2_template_submitters
  FOR EACH ROW EXECUTE FUNCTION pandapay.sms_v2_template_submitter_deleted();

-- Revoke a profile's queue access in the same consent transaction. The source
-- SMS stays on the phone and can be reviewed without shared learning.
CREATE FUNCTION pandapay.sms_v2_revoke_template_consent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.purpose='sms_shared_learning' AND NOT NEW.granted THEN
    PERFORM pg_advisory_xact_lock(hashtext('sms-shared-learning-consent:'||NEW.profile_id::text));
    PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
    DELETE FROM sms_v2_template_submitters WHERE profile_id=NEW.profile_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_revoke_template_consent() FROM PUBLIC;
CREATE TRIGGER sms_v2_revoke_template_consent AFTER INSERT ON user_consents
  FOR EACH ROW EXECUTE FUNCTION pandapay.sms_v2_revoke_template_consent();
