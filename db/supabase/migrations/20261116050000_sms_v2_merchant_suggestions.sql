-- Learning loop B4: the AI's category suggestion for a shop left in "Other".
-- One row per shop key, written once by the private worker (the admin can ask
-- again). Nothing here reaches phones: the admin turns a suggestion into a
-- category draft, which goes through the golden check and cohort publish.
CREATE TABLE public.sms_v2_merchant_suggestions (
  merchant_key text PRIMARY KEY CHECK (merchant_key ~ '^[A-Z][A-Z0-9 &''.-]{1,59}$'),
  category text,
  confidence numeric CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  why text,
  model text,
  prompt_version text,
  status text NOT NULL CHECK (status IN ('ready', 'failed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.sms_v2_merchant_suggestions ENABLE ROW LEVEL SECURITY;
CREATE POLICY private_read ON public.sms_v2_merchant_suggestions FOR SELECT TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.read'));
CREATE POLICY private_write ON public.sms_v2_merchant_suggestions FOR ALL TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish')
  WITH CHECK (pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish');
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sms_v2_merchant_suggestions TO pandapay_admin_api;
