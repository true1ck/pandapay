\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS profile \gset
INSERT INTO profiles(id) VALUES(:'profile'::uuid);
SET LOCAL ROLE app_user;
SELECT set_config('app.user_id',:'profile',true);
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(pandapay.uid(),'sms_shared_learning','test',true,'2026-11-01T00:00:00Z');
INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,
 corrected,redacted_template,shared_learning_eligible,request_hash)
 VALUES(pandapay.uid(),'synthetic','{}','missing','gate','{}',
 '{"category":"dining"}','Synthetic skeleton',true,repeat('a',64));
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(pandapay.uid(),'sms_shared_learning','test',false,'2026-11-02T00:00:00Z');
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM sms_v2_correction_cases WHERE redacted_template IS NOT NULL OR
   corrected<>'{}'::jsonb OR shared_learning_eligible) THEN
  RAISE EXCEPTION 'withdrawn evidence retained';
 END IF;
END $$;
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(pandapay.uid(),'sms_shared_learning','test',true,'2026-11-03T00:00:00Z');
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM sms_v2_correction_cases WHERE redacted_template IS NOT NULL) THEN
  RAISE EXCEPTION 'regrant restored erased evidence';
 END IF;
END $$;
RESET ROLE;
SELECT 'sms_v2_correction_consent ok' AS result;
ROLLBACK;
