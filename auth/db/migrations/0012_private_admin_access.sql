-- Durable private-console identity, factor, challenge and session state.
-- The runtime capability is non-login and cannot be inherited by public roles.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pandapay_admin_gateway') THEN
    CREATE ROLE pandapay_admin_gateway NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pandapay_admin_gateway' AND
      (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Unsafe private admin gateway capability';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member='pandapay_admin_gateway'::regrole) THEN
    RAISE EXCEPTION 'Admin gateway capability must not inherit roles';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS admin_private;
REVOKE ALL ON SCHEMA admin_private FROM PUBLIC;
CREATE TABLE admin_private.principals (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
  state text NOT NULL CHECK (state IN ('pending','enabled','revoked')),
  version bigint NOT NULL DEFAULT 1 CHECK(version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  enabled_at timestamptz,
  revoked_at timestamptz,
  CHECK ((state='enabled') = (enabled_at IS NOT NULL) OR state='revoked'),
  CHECK ((state='revoked') = (revoked_at IS NOT NULL))
);
CREATE TABLE admin_private.email_proofs (
  login_id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES admin_private.principals(user_id) ON DELETE RESTRICT,
  preauth_cookie_digest text NOT NULL CHECK(preauth_cookie_digest ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL, consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE POLICY private_gateway_only ON admin_private.principals TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE POLICY private_gateway_only ON admin_private.email_proofs TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE TABLE admin_private.credentials (
  credential_id text PRIMARY KEY CHECK(octet_length(credential_id) BETWEEN 1 AND 1024),
  user_id uuid NOT NULL REFERENCES admin_private.principals(user_id) ON DELETE RESTRICT,
  public_key bytea NOT NULL CHECK(octet_length(public_key) BETWEEN 1 AND 8192),
  counter bigint NOT NULL DEFAULT 0 CHECK(counter >= 0),
  transports text[] NOT NULL DEFAULT '{}',
  device_type text NOT NULL,
  backed_up boolean NOT NULL DEFAULT false,
  slot text NOT NULL CHECK(slot IN ('primary','backup','additional')),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE POLICY private_gateway_only ON admin_private.credentials TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE INDEX admin_private_credentials_user ON admin_private.credentials(user_id) WHERE revoked_at IS NULL;
-- Factor revocation/replacement invalidates every session version immediately.
-- Ordinary authenticator counter updates do not extend or revoke sessions.
CREATE FUNCTION admin_private.invalidate_factor_sessions() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,admin_private AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    UPDATE admin_private.principals SET version=version+1 WHERE user_id=OLD.user_id;
    RETURN OLD;
  END IF;
  IF OLD.revoked_at IS DISTINCT FROM NEW.revoked_at
     OR OLD.public_key IS DISTINCT FROM NEW.public_key
     OR OLD.user_id IS DISTINCT FROM NEW.user_id THEN
    UPDATE admin_private.principals SET version=version+1 WHERE user_id IN (OLD.user_id,NEW.user_id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION admin_private.invalidate_factor_sessions() FROM PUBLIC;
CREATE TRIGGER private_admin_factor_session_invalidation
AFTER UPDATE OF revoked_at,public_key,user_id OR DELETE ON admin_private.credentials
FOR EACH ROW EXECUTE FUNCTION admin_private.invalidate_factor_sessions();
CREATE TABLE admin_private.challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), login_id uuid NOT NULL,
  preauth_cookie_digest text NOT NULL CHECK(preauth_cookie_digest ~ '^[0-9a-f]{64}$'),
  user_id uuid REFERENCES admin_private.principals(user_id) ON DELETE RESTRICT,
  purpose text NOT NULL CHECK(purpose IN ('email','login','enrollment','step_up')),
  challenge_digest text NOT NULL CHECK(challenge_digest ~ '^[0-9a-f]{64}$'),
  challenge_value text,
  grant_digest text CHECK(grant_digest IS NULL OR grant_digest ~ '^[0-9a-f]{64}$'),
  origin text NOT NULL, rp_id text NOT NULL, credential_ids text[] NOT NULL DEFAULT '{}',
  attempts smallint NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
  expires_at timestamptz NOT NULL, consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE POLICY private_gateway_only ON admin_private.challenges TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE INDEX admin_private_challenges_expiry ON admin_private.challenges(expires_at);
CREATE UNIQUE INDEX admin_private_one_open_challenge ON admin_private.challenges(login_id,purpose) WHERE consumed_at IS NULL;
CREATE TABLE admin_private.enrollment_grants (
  grant_digest text PRIMARY KEY CHECK(grant_digest ~ '^[0-9a-f]{64}$'), user_id uuid NOT NULL REFERENCES admin_private.principals(user_id),
  environment text NOT NULL, origin text NOT NULL, rp_id text NOT NULL,
  slot text NOT NULL CHECK(slot IN ('primary','backup','additional')),
  expires_at timestamptz NOT NULL, consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE POLICY private_gateway_only ON admin_private.enrollment_grants TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE TABLE admin_private.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES admin_private.principals(user_id),
  principal_version bigint NOT NULL CHECK(principal_version>0),
  session_epoch text NOT NULL CHECK(octet_length(session_epoch) BETWEEN 32 AND 128),
  cookie_digest text NOT NULL UNIQUE CHECK(cookie_digest ~ '^[0-9a-f]{64}$'), csrf_digest text NOT NULL CHECK(csrf_digest ~ '^[0-9a-f]{64}$'),
  verified_at timestamptz NOT NULL, idle_expires_at timestamptz NOT NULL, absolute_expires_at timestamptz NOT NULL,
  encrypted_upstream_token text NOT NULL CHECK(octet_length(encrypted_upstream_token) BETWEEN 1 AND 32768),
  revoked_at timestamptz, revocation_version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(), CHECK(idle_expires_at <= absolute_expires_at),
  CHECK(absolute_expires_at <= created_at + interval '8 hours')
);
CREATE POLICY private_gateway_only ON admin_private.sessions TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE INDEX admin_private_sessions_user ON admin_private.sessions(user_id) WHERE revoked_at IS NULL;
CREATE TABLE admin_private.access_tokens (
  token_digest text PRIMARY KEY CHECK(token_digest ~ '^[0-9a-f]{64}$'), session_id uuid NOT NULL REFERENCES admin_private.sessions(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL, revoked_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE POLICY private_gateway_only ON admin_private.access_tokens TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE INDEX admin_private_tokens_expiry ON admin_private.access_tokens(expires_at);
CREATE TABLE admin_private.rate_buckets (
  bucket_key text PRIMARY KEY CHECK(octet_length(bucket_key) BETWEEN 1 AND 256), window_started_at timestamptz NOT NULL,
  count integer NOT NULL CHECK(count >= 0), expires_at timestamptz NOT NULL
);
CREATE POLICY private_gateway_only ON admin_private.rate_buckets TO pandapay_admin_gateway USING(true) WITH CHECK(true);
CREATE TABLE admin_private.audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation_id uuid NOT NULL, actor text NOT NULL,
  action text NOT NULL, user_id uuid, reason text NOT NULL CHECK(octet_length(reason) BETWEEN 1 AND 1000),
  before_state jsonb NOT NULL DEFAULT '{}', after_state jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE POLICY private_gateway_only ON admin_private.audit TO pandapay_admin_gateway USING(true) WITH CHECK(true);
REVOKE ALL ON ALL TABLES IN SCHEMA admin_private FROM PUBLIC;
ALTER TABLE admin_private.principals ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.email_proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.enrollment_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.access_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.rate_buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.principals FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.email_proofs FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.credentials FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.challenges FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.enrollment_grants FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.access_tokens FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.rate_buckets FORCE ROW LEVEL SECURITY;
ALTER TABLE admin_private.audit FORCE ROW LEVEL SECURITY;
-- This is a capability role, not a login. A gateway LOGIN must be provisioned
-- separately and explicitly granted this capability after role audit.
GRANT USAGE ON SCHEMA admin_private TO pandapay_admin_gateway;
GRANT SELECT ON admin_private.principals,admin_private.credentials,admin_private.challenges,admin_private.email_proofs,
  admin_private.enrollment_grants,admin_private.sessions,admin_private.access_tokens,admin_private.rate_buckets TO pandapay_admin_gateway;
GRANT INSERT,UPDATE ON admin_private.challenges,admin_private.email_proofs,
  admin_private.sessions,admin_private.access_tokens,admin_private.rate_buckets TO pandapay_admin_gateway;
GRANT UPDATE(counter) ON admin_private.credentials TO pandapay_admin_gateway;
GRANT INSERT ON admin_private.audit TO pandapay_admin_gateway;
GRANT SELECT ON admin_private.audit TO pandapay_admin_gateway;
GRANT USAGE,SELECT ON SEQUENCE admin_private.audit_id_seq TO pandapay_admin_gateway;
REVOKE ALL ON admin_private.principals,admin_private.credentials,admin_private.challenges,admin_private.enrollment_grants,
  admin_private.sessions,admin_private.access_tokens,admin_private.rate_buckets,admin_private.audit FROM PUBLIC;

CREATE UNIQUE INDEX admin_private_active_factor_slot ON admin_private.credentials(user_id,slot)
 WHERE revoked_at IS NULL AND slot IN ('primary','backup');
CREATE OR REPLACE FUNCTION admin_private.register_credential(
 p_login uuid,p_cookie text,p_challenge text,p_credential text,p_public_key bytea,
 p_counter bigint,p_transports text[],p_device_type text,p_backed_up boolean,p_environment text)
 RETURNS TABLE(credential_id text,user_id uuid) LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,admin_private,public AS $$
DECLARE ch admin_private.challenges%ROWTYPE; gr admin_private.enrollment_grants%ROWTYPE;
BEGIN
 IF session_user<>'admin_gateway_runtime' THEN RAISE EXCEPTION 'private runtime required' USING ERRCODE='42501'; END IF;
 SELECT * INTO ch FROM admin_private.challenges c WHERE c.login_id=p_login AND c.preauth_cookie_digest=p_cookie
   AND c.challenge_digest=p_challenge AND c.purpose='enrollment' AND c.consumed_at IS NULL AND c.expires_at>now()
   AND c.origin='https://localhost:8443' AND c.rp_id='localhost' FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 PERFORM 1 FROM admin_private.email_proofs ep JOIN admin_private.principals pr ON pr.user_id=ep.user_id
  JOIN public.users u ON u.id=ep.user_id WHERE ep.login_id=p_login AND ep.user_id=ch.user_id AND ep.preauth_cookie_digest=p_cookie
   AND ep.consumed_at IS NULL AND ep.expires_at>now() AND pr.state='pending' AND u.is_active AND NOT u.deleted AND u.is_email_verified FOR UPDATE OF ep,pr;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT * INTO gr FROM admin_private.enrollment_grants g WHERE g.grant_digest=ch.grant_digest AND g.user_id=ch.user_id
  AND g.environment=p_environment AND g.origin=ch.origin AND g.rp_id=ch.rp_id AND g.consumed_at IS NULL AND g.expires_at>now() FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 UPDATE admin_private.challenges SET consumed_at=now() WHERE id=ch.id;
 UPDATE admin_private.email_proofs SET consumed_at=now() WHERE login_id=p_login;
 UPDATE admin_private.enrollment_grants SET consumed_at=now() WHERE grant_digest=gr.grant_digest;
 RETURN QUERY INSERT INTO admin_private.credentials AS cr(credential_id,user_id,public_key,counter,transports,device_type,backed_up,slot)
   VALUES(p_credential,ch.user_id,p_public_key,p_counter,p_transports,p_device_type,p_backed_up,gr.slot)
   RETURNING cr.credential_id,cr.user_id;
END $$;
REVOKE ALL ON FUNCTION admin_private.register_credential(uuid,text,text,text,bytea,bigint,text[],text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_private.register_credential(uuid,text,text,text,bytea,bigint,text[],text,boolean,text) TO pandapay_admin_gateway;
