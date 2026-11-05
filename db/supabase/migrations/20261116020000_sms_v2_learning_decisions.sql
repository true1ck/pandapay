-- Learning loop A7: what the admin decided about a counted candidate, and the
-- counts-only summary behind the console's Learning page.
CREATE TABLE public.sms_v2_learning_decisions (
  kind text NOT NULL CHECK (kind IN ('category_choice', 'merchant_name', 'uncategorised')),
  merchant_key text NOT NULL,
  value text NOT NULL,
  decision text NOT NULL CHECK (decision IN ('dismissed', 'drafted')),
  users_at_decision integer NOT NULL,
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
  decided_by uuid NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (kind, merchant_key, value)
);
ALTER TABLE public.sms_v2_learning_decisions ENABLE ROW LEVEL SECURITY;
CREATE POLICY private_read ON public.sms_v2_learning_decisions FOR SELECT TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.read'));
CREATE POLICY private_write ON public.sms_v2_learning_decisions FOR ALL TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish')
  WITH CHECK (pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish');
GRANT SELECT, INSERT, UPDATE ON public.sms_v2_learning_decisions TO pandapay_admin_api;

-- Cross-profile counts for the Learning page. The fixes, facts, consent and
-- signal tables are owner-scoped, so the private admin role cannot count
-- across profiles. Only numbers leave this function: no profile id, shop key,
-- message or value. Shop keys are shown only by the routes, which apply K.
CREATE FUNCTION pandapay.sms_v2_learning_summary(p_days integer, p_min_users integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE since timestamptz; result jsonb;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE = '42501';
  END IF;
  IF p_days IS NULL OR p_days NOT BETWEEN 1 AND 365 OR p_min_users IS NULL OR p_min_users < 2 THEN
    RAISE EXCEPTION 'learning summary window invalid' USING ERRCODE = '22023';
  END IF;
  since := clock_timestamp() - make_interval(days => p_days);
  SELECT jsonb_build_object(
    'corrections', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', correction_kind, 'cases', cases, 'users', users) ORDER BY correction_kind)
        FROM (SELECT correction_kind, count(*) AS cases, count(DISTINCT profile_id) AS users
                FROM sms_v2_correction_cases WHERE created_at >= since GROUP BY correction_kind) c), '[]'::jsonb),
    'signals', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', kind, 'users', users, 'attestedUsers', attested,
          'belowThreshold', below) ORDER BY kind)
        FROM (SELECT s.kind,
                     count(DISTINCT s.profile_id) AS users,
                     count(DISTINCT s.profile_id) FILTER (WHERE s.eligible) AS attested,
                     (SELECT count(*) FROM (SELECT t.merchant_key FROM sms_v2_learning_signals t
                         WHERE t.kind = s.kind AND t.eligible AND t.last_at >= since
                         GROUP BY t.merchant_key HAVING count(DISTINCT t.profile_id) < p_min_users) b) AS below
                FROM sms_v2_learning_signals s WHERE s.last_at >= since GROUP BY s.kind) k), '[]'::jsonb),
    'optIn', jsonb_build_object(
      'sharingNow', (SELECT count(*) FROM (SELECT DISTINCT profile_id FROM user_consents WHERE purpose = 'sms_shared_learning') p
                      WHERE pandapay.sms_shared_learning_granted(p.profile_id)),
      'synced30d', (SELECT count(DISTINCT profile_id) FROM sms_v2_facts WHERE created_at >= clock_timestamp() - interval '30 days'),
      'syncedSharing30d', (SELECT count(*) FROM (SELECT DISTINCT profile_id FROM sms_v2_facts WHERE created_at >= clock_timestamp() - interval '30 days') f
                            WHERE pandapay.sms_shared_learning_granted(f.profile_id)),
      'perDay', coalesce((SELECT jsonb_agg(jsonb_build_object('day', day, 'on', turned_on, 'off', turned_off) ORDER BY day)
          FROM (SELECT (granted_at AT TIME ZONE 'utc')::date AS day,
                       count(*) FILTER (WHERE granted) AS turned_on, count(*) FILTER (WHERE NOT granted) AS turned_off
                  FROM user_consents WHERE purpose = 'sms_shared_learning' AND granted_at >= since GROUP BY 1) d), '[]'::jsonb))
  ) INTO result;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_learning_summary(integer, integer) FROM PUBLIC, app_user, pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_learning_summary(integer, integer) TO pandapay_admin_api;
