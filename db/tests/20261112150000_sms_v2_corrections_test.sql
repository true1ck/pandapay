\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS p1, gen_random_uuid()::text AS p2 \gset
INSERT INTO profiles(id) VALUES(:'p1'::uuid),(:'p2'::uuid);
SET LOCAL ROLE app_user;
SELECT set_config('app.user_id',:'p1',true);
INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,request_hash)
 VALUES(pandapay.uid(),'synthetic','{}','missing','gate','{}',repeat('a',64));
DO $$ BEGIN
 IF (SELECT count(*) FROM sms_v2_correction_cases) <> 1 THEN RAISE EXCEPTION 'own case hidden'; END IF;
 BEGIN
  UPDATE sms_v2_correction_cases SET decision='not_a_bug';
  RAISE EXCEPTION 'owner decision allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('app.user_id',:'p2',true);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM sms_v2_correction_cases) THEN RAISE EXCEPTION 'other profile case visible'; END IF;
END $$;
-- Account B may not insert on behalf of account A.
SELECT set_config('test.other_profile',:'p1',true);
DO $$ BEGIN
 BEGIN
  INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,request_hash)
   VALUES(current_setting('test.other_profile')::uuid,'synthetic','{}','missing','gate','{}',repeat('b',64));
  RAISE EXCEPTION 'foreign owner insertion allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SELECT 'sms_v2_corrections ok' AS result;
ROLLBACK;
