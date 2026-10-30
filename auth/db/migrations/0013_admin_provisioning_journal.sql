-- Maintenance-owned provisioning intent. Neither public auth nor the private
-- gateway can manufacture, approve, complete or alter an operator intent.
CREATE TABLE admin_private.provisioning_operations (
  id uuid PRIMARY KEY,
  plan_hash text NOT NULL UNIQUE CHECK(plan_hash ~ '^[0-9a-f]{64}$'),
  target_key text NOT NULL CHECK(target_key ~ '^[0-9a-f]{64}$'),
  user_id uuid NOT NULL REFERENCES public.users(id),
  email text NOT NULL,
  operation text NOT NULL CHECK(operation IN ('grant','reconcile','enable','revoke')),
  plan jsonb NOT NULL CHECK(jsonb_typeof(plan)='object'),
  phase text NOT NULL CHECK(phase IN ('auth_prepared','product_applied','complete','blocked')),
  expected_principal_version bigint,
  blocked_code text CHECK(blocked_code ~ '^[a-z_]{1,64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CHECK((phase='complete') = (completed_at IS NOT NULL))
);
CREATE INDEX admin_provisioning_open_user ON admin_private.provisioning_operations(user_id)
  WHERE phase IN ('auth_prepared','product_applied');
REVOKE ALL ON admin_private.provisioning_operations FROM PUBLIC,pandapay_admin_gateway;
ALTER TABLE admin_private.provisioning_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_private.provisioning_operations FORCE ROW LEVEL SECURITY;
COMMENT ON TABLE admin_private.provisioning_operations IS
  'Operator-only resumable provisioning journal. No tokens, grants, keys or OTPs; runtime has no admission authority here.';
