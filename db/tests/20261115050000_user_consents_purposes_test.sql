\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS profile \gset
INSERT INTO profiles(id) VALUES(:'profile');
-- The two purposes the app records through POST /consents are accepted.
INSERT INTO user_consents(profile_id,purpose,policy_version,granted)
 VALUES(:'profile','email_import','synthetic',true),
       (:'profile','sms_reading','synthetic',true),
       (:'profile','sms_reading','synthetic',false);
DO $$ BEGIN
 -- An unknown purpose is still rejected.
 BEGIN
  INSERT INTO user_consents(profile_id,purpose,policy_version,granted)
   SELECT id,'sms_everything','synthetic',true FROM profiles LIMIT 1;
  RAISE EXCEPTION 'unknown purpose accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
SELECT 'user_consents purposes ok' AS result;
ROLLBACK;
