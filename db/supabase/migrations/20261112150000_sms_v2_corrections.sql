CREATE SEQUENCE public.sms_v2_correction_change_seq;
CREATE TABLE public.sms_v2_correction_cases (
  case_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  source_key text NOT NULL,
  fact_ids text[] NOT NULL,
  event_id text,
  correction_kind text NOT NULL,
  stage text NOT NULL CHECK (stage IN ('gate','extraction','instrument','linking','category','sync')),
  trace jsonb NOT NULL,
  corrected jsonb NOT NULL DEFAULT '{}',
  template_hash text,
  sender_brand text,
  redacted_template text,
  is_tester boolean NOT NULL DEFAULT false,
  shared_learning_eligible boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','decided')),
  decision text CHECK (decision IN ('data_fix','code_fix','not_a_bug')),
  reason text,
  output jsonb,
  request_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  change_seq bigint NOT NULL DEFAULT nextval('public.sms_v2_correction_change_seq'),
  UNIQUE(profile_id,request_hash)
);
CREATE INDEX sms_v2_correction_owner_seq ON public.sms_v2_correction_cases(profile_id,change_seq);
CREATE INDEX sms_v2_correction_template ON public.sms_v2_correction_cases(template_hash,status);
ALTER TABLE public.sms_v2_correction_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_correction_cases FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_v2_correction_cases FROM PUBLIC, app_user, pandapay_admin_api;
CREATE POLICY sms_v2_correction_owner_read ON public.sms_v2_correction_cases
  FOR SELECT TO app_user USING(profile_id=pandapay.uid());
CREATE POLICY sms_v2_correction_owner_insert ON public.sms_v2_correction_cases
  FOR INSERT TO app_user WITH CHECK(profile_id=pandapay.uid() AND status='open' AND decision IS NULL);
-- The only customer update is the idempotent self-assignment in INSERT's
-- conflict branch. Column grants prevent changing decisions or other payload.
CREATE POLICY sms_v2_correction_owner_retry ON public.sms_v2_correction_cases
  FOR UPDATE TO app_user USING(profile_id=pandapay.uid())
  WITH CHECK(profile_id=pandapay.uid());
GRANT SELECT,INSERT ON public.sms_v2_correction_cases TO app_user;
GRANT UPDATE(request_hash) ON public.sms_v2_correction_cases TO app_user;
GRANT USAGE ON SEQUENCE public.sms_v2_correction_change_seq TO app_user;
GRANT SELECT,UPDATE ON public.sms_v2_correction_cases TO pandapay_admin_api;
GRANT USAGE ON SEQUENCE public.sms_v2_correction_change_seq TO pandapay_admin_api;
CREATE POLICY sms_v2_correction_private_read ON public.sms_v2_correction_cases
  FOR SELECT TO pandapay_admin_api USING(pandapay.admin_has_permission('learning.read') OR pandapay.admin_has_permission('learning.publish'));
CREATE POLICY sms_v2_correction_private_decision ON public.sms_v2_correction_cases
  FOR UPDATE TO pandapay_admin_api USING(pandapay.admin_has_permission('learning.publish'))
  WITH CHECK(pandapay.admin_has_permission('learning.publish'));
