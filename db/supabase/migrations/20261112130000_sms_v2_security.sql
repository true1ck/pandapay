-- Shared SMS v2 admission. A profile budget always applies even if a caller
-- rotates its installation identifier. The second budget isolates devices
-- within the profile. Counters contain hashes, route names and counts only.
CREATE TABLE public.sms_v2_rate_counters (
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  device_digest text NOT NULL,
  bucket text NOT NULL CHECK (length(bucket) BETWEEN 1 AND 64),
  window_start timestamptz NOT NULL,
  used bigint NOT NULL CHECK (used >= 0),
  PRIMARY KEY (profile_id, device_digest, bucket, window_start)
);
ALTER TABLE public.sms_v2_rate_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_rate_counters FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_v2_rate_counters FROM PUBLIC;
CREATE INDEX sms_v2_rate_counters_expiry ON public.sms_v2_rate_counters(window_start);

CREATE FUNCTION pandapay.sms_v2_consume_rate(p_device_digest text, p_checks jsonb)
RETURNS TABLE(allowed boolean, retry_after_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  actor uuid := pandapay.uid();
  check_row record;
  device text;
  current_at timestamptz := clock_timestamp();
  start_at timestamptz;
  prior bigint;
  retry integer := 0;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_device_digest !~ '^[0-9a-f]{64}$' OR p_device_digest IS NULL OR
     jsonb_typeof(p_checks) IS DISTINCT FROM 'array' OR jsonb_array_length(p_checks) NOT BETWEEN 1 AND 8 THEN
    RAISE EXCEPTION 'invalid rate request';
  END IF;

  -- One lock per account makes the profile and device budgets atomic across
  -- replicas and prevents two admitted batches racing past a shared ceiling.
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-v2-rate:' || actor::text, 0));
  DELETE FROM public.sms_v2_rate_counters
    WHERE profile_id = actor AND window_start < current_at - interval '2 days';

  FOR check_row IN SELECT * FROM jsonb_to_recordset(p_checks)
      AS x(bucket text, seconds integer, "limit" integer, units integer)
  LOOP
    IF check_row.bucket IS NULL OR check_row.bucket !~ '^[a-z][a-z:_-]{0,63}$' OR
       check_row.seconds IS NULL OR check_row.seconds NOT IN (60, 3600, 86400) OR
       check_row."limit" IS NULL OR check_row."limit" NOT BETWEEN 1 AND 1000000 OR
       check_row.units IS NULL OR check_row.units NOT BETWEEN 1 AND 20000 THEN
      RAISE EXCEPTION 'invalid rate budget';
    END IF;
    start_at := to_timestamp(floor(extract(epoch FROM current_at) / check_row.seconds) * check_row.seconds);
    FOREACH device IN ARRAY ARRAY['', p_device_digest] LOOP
      SELECT used INTO prior FROM public.sms_v2_rate_counters
        WHERE profile_id = actor AND device_digest = device
          AND bucket = check_row.bucket AND window_start = start_at;
      IF coalesce(prior, 0) + check_row.units > check_row."limit" THEN
        retry := greatest(retry, greatest(1,
          ceil(extract(epoch FROM start_at + make_interval(secs => check_row.seconds) - current_at))::integer));
      END IF;
    END LOOP;
  END LOOP;
  IF retry > 0 THEN RETURN QUERY SELECT false, retry; RETURN; END IF;

  FOR check_row IN SELECT * FROM jsonb_to_recordset(p_checks)
      AS x(bucket text, seconds integer, "limit" integer, units integer)
  LOOP
    start_at := to_timestamp(floor(extract(epoch FROM current_at) / check_row.seconds) * check_row.seconds);
    FOREACH device IN ARRAY ARRAY['', p_device_digest] LOOP
      INSERT INTO public.sms_v2_rate_counters(profile_id, device_digest, bucket, window_start, used)
        VALUES (actor, device, check_row.bucket, start_at, check_row.units)
      ON CONFLICT (profile_id, device_digest, bucket, window_start)
        DO UPDATE SET used = public.sms_v2_rate_counters.used + excluded.used;
    END LOOP;
  END LOOP;
  RETURN QUERY SELECT true, 0;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_consume_rate(text, jsonb) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_consume_rate(text, jsonb) TO app_user;
  END IF;
END $$;
