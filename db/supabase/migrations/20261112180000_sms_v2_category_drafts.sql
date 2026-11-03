-- Private, reviewed category-rule changes. Rules retain the frozen CategoryRule
-- shape; draft revision and review metadata stay outside signed rule bodies.
CREATE TABLE sms_v2_category_drafts (
  draft_id uuid NOT NULL,
  revision integer NOT NULL CHECK(revision>0),
  status text NOT NULL CHECK(status IN ('draft','published')),
  body jsonb NOT NULL CHECK(jsonb_typeof(body)='object'),
  created_by uuid REFERENCES admin_users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(draft_id,revision)
);
ALTER TABLE sms_v2_category_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE sms_v2_category_drafts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON sms_v2_category_drafts FROM PUBLIC,app_user;
GRANT SELECT,INSERT,UPDATE,DELETE ON sms_v2_category_drafts TO pandapay_admin_api;
CREATE POLICY private_read ON sms_v2_category_drafts FOR SELECT TO pandapay_admin_api
 USING(pandapay.admin_has_permission('learning.read'));
CREATE POLICY private_write ON sms_v2_category_drafts FOR ALL TO pandapay_admin_api
 USING(pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish')
 WITH CHECK(pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish');
