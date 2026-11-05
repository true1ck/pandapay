-- LO-10: an App Check token is a bearer token and says nothing about the account or the
-- installation. The first sighting of a token binds it to (profile, installation digest);
-- a later sighting by another profile or installation is not treated as attested.
-- Rows hold only hashes and an expiry. They are removed once the token has expired.
CREATE TABLE public.sms_v2_attestation_bindings (
  token_digest text PRIMARY KEY CHECK (token_digest ~ '^[0-9a-f]{64}$'),
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  device_digest text NOT NULL CHECK (device_digest ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.sms_v2_attestation_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_attestation_bindings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_v2_attestation_bindings FROM PUBLIC;
CREATE INDEX sms_v2_attestation_bindings_expiry ON public.sms_v2_attestation_bindings(expires_at);

-- Returns true when the token is (now) bound to the caller and this installation.
CREATE FUNCTION pandapay.sms_v2_bind_attestation(p_token_digest text, p_device_digest text, p_expires_at timestamptz)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  actor uuid := pandapay.uid();
  current_at timestamptz := clock_timestamp();
  owner_profile uuid;
  owner_device text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$' OR
     p_device_digest IS NULL OR p_device_digest !~ '^[0-9a-f]{64}$' OR p_expires_at IS NULL THEN
    RAISE EXCEPTION 'invalid attestation binding';
  END IF;
  -- Small, bounded cleanup so the table stays short without a separate job.
  DELETE FROM public.sms_v2_attestation_bindings
    WHERE token_digest IN (SELECT token_digest FROM public.sms_v2_attestation_bindings
                            WHERE expires_at < current_at - interval '1 hour' LIMIT 100);
  INSERT INTO public.sms_v2_attestation_bindings(token_digest, profile_id, device_digest, expires_at)
    VALUES (p_token_digest, actor, p_device_digest, least(p_expires_at, current_at + interval '7 days'))
    ON CONFLICT (token_digest) DO NOTHING;
  SELECT profile_id, device_digest INTO owner_profile, owner_device
    FROM public.sms_v2_attestation_bindings WHERE token_digest = p_token_digest;
  RETURN owner_profile = actor AND owner_device = p_device_digest;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_bind_attestation(text, text, timestamptz) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    GRANT EXECUTE ON FUNCTION pandapay.sms_v2_bind_attestation(text, text, timestamptz) TO app_user;
  END IF;
END $$;
