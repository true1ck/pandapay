-- Dedicated, private browser gateway storage. No client or ordinary auth grant.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname='pandapay_console_session') THEN
    CREATE ROLE pandapay_console_session NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname='pandapay_console_session'
    AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Unsafe console session capability';
  END IF;
  IF EXISTS (SELECT FROM pg_catalog.pg_auth_members WHERE member='pandapay_console_session'::regrole) THEN
    RAISE EXCEPTION 'Console session capability must not inherit other roles';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS console_private;
REVOKE ALL ON SCHEMA console_private FROM PUBLIC;
CREATE TABLE IF NOT EXISTS console_private.sessions (
  session_hash text PRIMARY KEY CHECK (session_hash ~ '^[0-9a-f]{64}$'),
  encrypted_tokens text NOT NULL CHECK (pg_catalog.octet_length(encrypted_tokens) BETWEEN 1 AND 32768),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  last_used_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '12 hours')
);
CREATE INDEX IF NOT EXISTS console_sessions_expiry ON console_private.sessions(expires_at);
REVOKE ALL ON console_private.sessions FROM PUBLIC;
ALTER TABLE console_private.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE console_private.sessions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS console_session_gateway ON console_private.sessions;
CREATE POLICY console_session_gateway ON console_private.sessions TO pandapay_console_session USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA console_private TO pandapay_console_session;
GRANT SELECT,INSERT,UPDATE,DELETE ON console_private.sessions TO pandapay_console_session;
COMMENT ON TABLE console_private.sessions IS 'Encrypted upstream credentials for the opt-in same-origin browser gateway. Opaque cookie IDs are stored only as SHA-256. No customer financial data. Expired sessions never authorize; bounded cleanup runs in gateway writes.';
