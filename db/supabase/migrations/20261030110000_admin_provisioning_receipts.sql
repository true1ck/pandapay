-- Private receipt for the product half of an operator operation. An effect,
-- its existing audit rows and this receipt commit in the same transaction.
CREATE SCHEMA admin_control;
REVOKE ALL ON SCHEMA admin_control FROM PUBLIC;
CREATE TABLE admin_control.provisioning_receipts (
  operation_id uuid PRIMARY KEY,
  plan_hash text NOT NULL CHECK(plan_hash ~ '^[0-9a-f]{64}$'),
  target_key text NOT NULL CHECK(target_key ~ '^[0-9a-f]{64}$'),
  user_id uuid NOT NULL,
  operation text NOT NULL CHECK(operation IN ('grant','reconcile','enable','revoke')),
  membership_after jsonb NOT NULL CHECK(jsonb_typeof(membership_after)='array'),
  created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON admin_control.provisioning_receipts FROM PUBLIC,pandapay_admin_api;
ALTER TABLE admin_control.provisioning_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_control.provisioning_receipts FORCE ROW LEVEL SECURITY;
COMMENT ON TABLE admin_control.provisioning_receipts IS
  'Maintenance-only effect receipt; private/public API roles cannot author provisioning receipts.';
