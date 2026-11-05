-- Learning loop A4: settings the admin can change in the console, and
-- per-user limit overrides. The environment still sets hard ceilings; the API
-- validates every value (api/src/sms_v2/settings.js). Both tables are private
-- to the admin role; the public API reads the few public values through
-- pandapay.sms_v2_public_settings().
CREATE TABLE public.sms_v2_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_by uuid NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500)
);
CREATE TABLE public.sms_v2_user_limits (
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  key text NOT NULL CHECK (key IN ('templates_per_user_per_day', 'signals_per_user_per_day')),
  value integer NOT NULL CHECK (value BETWEEN 1 AND 100000),
  expires_at timestamptz NOT NULL CHECK (expires_at <= created_at + interval '90 days'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_by uuid NOT NULL,
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
  PRIMARY KEY (profile_id, key)
);
DO $$ DECLARE t text; write_guard text; BEGIN
  write_guard := 'pandapay.admin_has_permission(''learning.publish'') AND current_setting(''pandapay.admin_permission'',true)=''learning.publish''';
  FOREACH t IN ARRAY ARRAY['sms_v2_settings','sms_v2_user_limits'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY private_read ON public.%I FOR SELECT TO pandapay_admin_api USING (pandapay.admin_has_permission(''learning.read''))',t);
    EXECUTE format('CREATE POLICY private_write ON public.%I FOR ALL TO pandapay_admin_api USING (%s) WITH CHECK (%s)',t,write_guard,write_guard);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON public.%I TO pandapay_admin_api',t);
  END LOOP;
END $$;

-- Per-user override, then the setting, then the built-in default.
CREATE FUNCTION pandapay.sms_v2_limit(p_profile uuid, p_key text, p_default integer) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(
    (SELECT value FROM sms_v2_user_limits
      WHERE profile_id = p_profile AND key = p_key AND expires_at > now()),
    (SELECT (value #>> '{}')::integer FROM sms_v2_settings WHERE key = p_key),
    p_default)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_limit(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_limit(uuid, text, integer) TO app_user, pandapay_admin_api;

-- The only settings the public API needs: the pause switch and the daily caps.
CREATE FUNCTION pandapay.sms_v2_public_settings() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb) FROM sms_v2_settings
   WHERE key IN ('intake_enabled', 'templates_per_user_per_day', 'corrections_per_user_per_day', 'signals_per_user_per_day')
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_public_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_public_settings() TO app_user, pandapay_admin_api;

-- Layout admission: same body as 20261116000000 with the daily cap read from settings.
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
