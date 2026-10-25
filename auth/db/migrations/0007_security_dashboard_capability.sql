-- Explicit, expiring auth security-dashboard capability. Existing auth role
-- labels and product-console memberships are never implicitly promoted.
CREATE SCHEMA IF NOT EXISTS auth_private;
REVOKE ALL ON SCHEMA auth_private FROM PUBLIC;
CREATE TABLE auth_private.security_admins (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  granted_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CHECK (expires_at > granted_at)
);
REVOKE ALL ON auth_private.security_admins FROM PUBLIC;
ALTER TABLE auth_private.security_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_private.security_admins FORCE ROW LEVEL SECURITY;
-- Access still requires explicit schema USAGE + SELECT. The trusted auth
-- authorization query scopes lookup to the validated UUID and account state.
CREATE POLICY security_admin_lookup ON auth_private.security_admins
  FOR SELECT TO PUBLIC USING (true);
CREATE POLICY security_admin_operator ON auth_private.security_admins
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
