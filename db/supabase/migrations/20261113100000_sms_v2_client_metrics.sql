-- SMS pipeline v2 / Lane N: phone-reported release counters (sync errors, history
-- migration outcomes, bundle download failures). Aggregate counts only: no message
-- content, no profile or device identifier in the aggregate table the admin metrics
-- read. A separate receipts table (owner-scoped, never read by admin code, pruned
-- after 14 days) makes a re-sent upload count once.
CREATE TABLE public.sms_v2_client_metrics_daily (
  day date NOT NULL,
  app_version text NOT NULL CHECK (app_version ~ '^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$'),
  attestation text NOT NULL CHECK (attestation IN ('verified','unverified')),
  metric text NOT NULL CHECK (metric IN (
    'sync_attempts','sync_errors_network','sync_errors_timeout','sync_errors_server',
    'sync_errors_storage','sync_errors_data','sync_errors_other',
    'migration_started','migration_completed','migration_failed','bundle_download_failures')),
  total bigint NOT NULL CHECK (total >= 0),
  PRIMARY KEY (day, app_version, attestation, metric)
);
ALTER TABLE public.sms_v2_client_metrics_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_client_metrics_daily FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_v2_client_metrics_daily FROM PUBLIC;

CREATE TABLE public.sms_v2_client_metric_receipts (
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  device_digest text NOT NULL CHECK (device_digest ~ '^[0-9a-f]{64}$'),
  day date NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (profile_id, device_digest, day)
);
ALTER TABLE public.sms_v2_client_metric_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_client_metric_receipts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_v2_client_metric_receipts FROM PUBLIC;
CREATE INDEX sms_v2_client_metric_receipts_expiry ON public.sms_v2_client_metric_receipts(received_at);

-- Phone upload. Returns 'recorded', 'duplicate' or 'no_consent'. Consent is read under
-- the same lock as every other sharing path, so a withdrawal that commits first wins.
CREATE FUNCTION pandapay.sms_v2_record_client_metrics(
  p_device_digest text, p_day date, p_app_version text, p_attestation text, p_counters jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  actor uuid := pandapay.uid();
  today date := (clock_timestamp() AT TIME ZONE 'utc')::date;
  item record;
  version text := p_app_version;
  inserted integer;
  nonzero boolean := false;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  IF p_device_digest IS NULL OR p_device_digest !~ '^[0-9a-f]{64}$'
     OR p_day IS NULL OR p_day > today OR p_day < today - 8
     OR p_attestation IS NULL OR p_attestation NOT IN ('verified','unverified')
     OR p_app_version IS NULL OR p_app_version !~ '^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$'
     OR jsonb_typeof(p_counters) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_counters)) NOT BETWEEN 1 AND 16 THEN
    RAISE EXCEPTION 'invalid client metrics' USING ERRCODE = '22023';
  END IF;
  FOR item IN SELECT key, value FROM jsonb_each(p_counters) LOOP
    IF item.key NOT IN ('sync_attempts','sync_errors_network','sync_errors_timeout','sync_errors_server',
        'sync_errors_storage','sync_errors_data','sync_errors_other',
        'migration_started','migration_completed','migration_failed','bundle_download_failures')
       OR jsonb_typeof(item.value) IS DISTINCT FROM 'number'
       OR item.value::text !~ '^[0-9]{1,5}$' OR (item.value::text)::integer > 10000 THEN
      RAISE EXCEPTION 'invalid client metrics' USING ERRCODE = '22023';
    END IF;
    IF (item.value::text)::integer > 0 THEN nonzero := true; END IF;
  END LOOP;
  IF NOT nonzero THEN RAISE EXCEPTION 'invalid client metrics' USING ERRCODE = '22023'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || actor::text, 0));
  IF NOT coalesce((SELECT granted FROM user_consents WHERE profile_id = actor AND purpose = 'sms_shared_learning'
      ORDER BY granted_at DESC, granted ASC, id DESC LIMIT 1), false) THEN
    RETURN 'no_consent';
  END IF;

  DELETE FROM public.sms_v2_client_metric_receipts WHERE received_at < clock_timestamp() - interval '14 days';
  INSERT INTO public.sms_v2_client_metric_receipts(profile_id, device_digest, day)
    VALUES (actor, p_device_digest, p_day) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF inserted = 0 THEN RETURN 'duplicate'; END IF;

  -- Bound the number of distinct version labels per day so the table cannot be inflated.
  IF NOT EXISTS (SELECT 1 FROM public.sms_v2_client_metrics_daily WHERE day = p_day AND app_version = version)
     AND (SELECT count(DISTINCT app_version) FROM public.sms_v2_client_metrics_daily WHERE day = p_day) >= 50 THEN
    version := 'other';
  END IF;
  INSERT INTO public.sms_v2_client_metrics_daily(day, app_version, attestation, metric, total)
    SELECT p_day, version, p_attestation, key, (value::text)::bigint
      FROM jsonb_each(p_counters) WHERE (value::text)::integer > 0
  ON CONFLICT (day, app_version, attestation, metric)
    DO UPDATE SET total = public.sms_v2_client_metrics_daily.total + excluded.total;
  RETURN 'recorded';
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_record_client_metrics(text, date, text, text, jsonb) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_record_client_metrics(text, date, text, text, jsonb) TO app_user;
  END IF;
END $$;

-- Admin read: aggregate rows only (by day-window, version and attestation), never a profile or device.
CREATE FUNCTION pandapay.sms_v2_client_metrics_report(p_since timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE result jsonb; since_day date;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE = '42501';
  END IF;
  IF p_since IS NULL OR p_since > clock_timestamp() OR p_since < clock_timestamp() - interval '90 days' THEN
    RAISE EXCEPTION 'metrics window invalid' USING ERRCODE = '22023';
  END IF;
  since_day := (p_since AT TIME ZONE 'utc')::date;
  SELECT jsonb_build_object(
    'totals', coalesce((SELECT jsonb_object_agg(metric, total) FROM (
        SELECT metric, sum(total)::bigint AS total FROM public.sms_v2_client_metrics_daily
         WHERE day >= since_day GROUP BY metric) t), '{}'::jsonb),
    'byVersion', coalesce((SELECT jsonb_agg(jsonb_build_object(
          'appVersion', app_version, 'attestation', attestation, 'counters', counters)
          ORDER BY app_version, attestation) FROM (
        SELECT app_version, attestation, jsonb_object_agg(metric, total) AS counters FROM (
          SELECT app_version, attestation, metric, sum(total)::bigint AS total
            FROM public.sms_v2_client_metrics_daily WHERE day >= since_day GROUP BY 1, 2, 3) m
         GROUP BY app_version, attestation) g), '[]'::jsonb),
    'reports', (SELECT count(*) FROM public.sms_v2_client_metric_receipts WHERE day >= since_day)
  ) INTO result;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_client_metrics_report(timestamptz) FROM PUBLIC, app_user, pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_client_metrics_report(timestamptz) TO pandapay_admin_api;
