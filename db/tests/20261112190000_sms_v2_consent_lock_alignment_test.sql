\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS profile \gset
INSERT INTO profiles(id) VALUES(:'profile');
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(:'profile','sms_shared_learning','sms-shared-learning-v3',true,'2026-11-01');
SET LOCAL ROLE app_user;
SELECT set_config('app.user_id',:'profile',true);
SELECT pandapay.sms_v2_submit_templates(jsonb_build_array(jsonb_build_object(
 'templateHash',repeat('e',64),'senderBrand','TESTBK','redactedBody','<AMT> paid to <PARTY>.','observedAt',now())),true);
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(pandapay.uid(),'sms_shared_learning','synthetic',false,'2000-01-01');
DO $$ BEGIN
 IF (SELECT count(*) FROM pandapay.sms_v2_template_results(0))<>1 THEN RAISE EXCEPTION 'backdated withdrawal erased currently consented evidence'; END IF;
END $$;
UPDATE user_consents SET granted=false WHERE profile_id=pandapay.uid() AND granted=true;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pandapay.sms_v2_template_results(0)) THEN RAISE EXCEPTION 'withdrawal update left result access'; END IF;
 BEGIN
  PERFORM pandapay.sms_v2_submit_templates(jsonb_build_array(jsonb_build_object(
   'templateHash',repeat('f',64),'senderBrand','TESTBK','redactedBody','<AMT> paid to <PARTY>.','observedAt',now())),true);
  RAISE EXCEPTION 'late contribution admitted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM sms_v2_unknown_templates WHERE template_hash=repeat('e',64)) THEN RAISE EXCEPTION 'orphan shared template retained'; END IF;
END $$;
SELECT 'sms_v2_consent_lock_alignment ok' AS result;
ROLLBACK;
