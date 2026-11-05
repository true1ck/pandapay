-- LO-09: the public API serves pre-signed bundles and holds no signing key. The hourly
-- maintenance job (and every mint) stores the signed copy here; the API reads it through a
-- security definer function and never signs. Rows minted before this migration have no
-- served copy until the job has run once; the API answers 503 for them (run the job first).
ALTER TABLE sms_v2_bundles
  ADD COLUMN served_body jsonb,
  ADD COLUMN served_expires_at timestamptz;

CREATE FUNCTION pandapay.sms_v2_latest_served_bundle(p_cohort text)
RETURNS TABLE (bundle_version integer, body jsonb, sha256 text, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT b.bundle_version, b.served_body, b.sha256, b.served_expires_at
    FROM sms_v2_bundles b
   WHERE b.cohort = p_cohort AND b.status = 'active'
   ORDER BY b.bundle_version DESC
   LIMIT 1;
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_latest_served_bundle(text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_latest_served_bundle(text) TO app_user;
  END IF;
END $$;
