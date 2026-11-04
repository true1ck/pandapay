-- SMS pipeline v2 / Lane C: read-only release metrics for GET /admin/sms/v2/metrics.
-- The v2 event, fact and rate-counter tables are owner-scoped (forced RLS), so the
-- private admin role cannot count across profiles. This function returns aggregate
-- counts only: no profile id, fact, message or device value leaves it.
CREATE FUNCTION pandapay.sms_v2_release_metrics(p_since timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result jsonb;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE='42501';
  END IF;
  IF p_since IS NULL OR p_since > clock_timestamp() OR p_since < clock_timestamp() - interval '90 days' THEN
    RAISE EXCEPTION 'metrics window invalid' USING ERRCODE='22023';
  END IF;
  SELECT jsonb_build_object(
    'newEvents', (SELECT count(*) FROM sms_v2_events WHERE updated_at >= p_since),
    'newFacts', (SELECT count(*) FROM sms_v2_facts WHERE created_at >= p_since),
    'activeProfiles30d', (SELECT count(DISTINCT profile_id) FROM sms_v2_facts WHERE created_at >= clock_timestamp() - interval '30 days'),
    'profilesWithV2Facts', (SELECT count(DISTINCT profile_id) FROM sms_v2_facts),
    'profilesWithSupersededLegacy', (SELECT count(DISTINCT profile_id) FROM transactions
                                      WHERE status::text = 'superseded' AND superseded_by_event_id IS NOT NULL),
    -- Counters are pruned after 2 days and written once per profile window (device_digest = '').
    'rateUsed', coalesce((SELECT jsonb_object_agg(bucket, total) FROM (
                  SELECT bucket, sum(used)::bigint AS total FROM sms_v2_rate_counters
                   WHERE device_digest = '' AND window_start >= p_since GROUP BY bucket) c), '{}'::jsonb)
  ) INTO result;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_release_metrics(timestamptz) FROM PUBLIC, app_user, pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_release_metrics(timestamptz) TO pandapay_admin_api;
