-- Learning page counts for K of 1 or more.
--
-- `signals_min_distinct_users` (how many different people must report a shop before the Learning page shows it) is an
-- admin setting that now goes down to 1, and defaults to 1 during the friends run, where every tester has opted in.
-- This function refused K below 2, so the page's summary failed with 22023 once K was 1. The only change is that guard:
-- the body, signature and permissions are the same, and only numbers still leave the function. Raise K again before a
-- public launch so that one person cannot decide.

CREATE OR REPLACE FUNCTION pandapay.sms_v2_learning_summary(p_days integer, p_min_users integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE since timestamptz; result jsonb;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE = '42501';
  END IF;
  IF p_days IS NULL OR p_days NOT BETWEEN 1 AND 365 OR p_min_users IS NULL OR p_min_users < 1 THEN
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
