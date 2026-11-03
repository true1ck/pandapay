\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='admin_api_runtime') THEN
  CREATE ROLE admin_api_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
END $$;
GRANT pandapay_admin_api TO admin_api_runtime;
SELECT gen_random_uuid()::text AS p1,gen_random_uuid()::text AS p2,gen_random_uuid()::text AS actor \gset
INSERT INTO profiles(id) VALUES(:'p1'::uuid),(:'p2'::uuid);
INSERT INTO admin_users(id,email,role,is_active) VALUES(:'actor'::uuid, :'actor'||'@wp16.invalid','owner',true);
INSERT INTO sms_v2_events(event_id,profile_id,type,status,legs,confidence,occurred_at,amount_minor)
 VALUES(repeat('a',64),:'p1'::uuid,'card_bill_payment','complete','[{"factId":"synthetic","role":"debit_leg"}]',1,now(),10000),
       (repeat('b',64),:'p2'::uuid,'purchase','complete','[{"factId":"synthetic","role":"debit_leg"}]',1,now(),10000);
INSERT INTO transactions(profile_id,source_key,source,amount_inr,occurred_at,status,superseded_by_event_id,state_applied)
 VALUES(:'p1'::uuid,'synthetic:bank','sms',100,now(),'superseded',repeat('a',64),true),
       (:'p1'::uuid,'synthetic:card','sms_bulk',100,now(),'superseded',repeat('a',64),true),
       (:'p2'::uuid,'synthetic:other','sms',100,now(),'superseded',repeat('b',64),true),
       (:'p1'::uuid,'synthetic:manual','manual',50,now(),'active',NULL,true),
       (:'p1'::uuid,'synthetic:deleted','sms',25,now(),'deleted',NULL,true);
INSERT INTO transactions(profile_id,source_key,source,amount_inr,occurred_at,status,event_id,pipeline_version,state_applied,is_backfill)
 VALUES(:'p1'::uuid,'synthetic:v2','sms',100,now(),'active',repeat('a',64),2,false,true);

SET LOCAL ROLE app_user;
SELECT set_config('app.user_id',:'p1',true);
SELECT set_config('test.wp16_p1',:'p1',true);
SELECT set_config('test.wp16_p2',:'p2',true);
DO $$ BEGIN
 IF (SELECT sum(amount_inr) FROM transactions WHERE status='active')<>150 THEN RAISE EXCEPTION 'report total includes superseded rows'; END IF;
 IF EXISTS(SELECT 1 FROM transactions WHERE profile_id=current_setting('test.wp16_p2')::uuid) THEN RAISE EXCEPTION 'foreign rows visible'; END IF;
 BEGIN
  PERFORM pandapay.sms_v2_unsupersede(current_setting('test.wp16_p1')::uuid);
  RAISE EXCEPTION 'public rollback allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 -- Public admin GUC forgery must not bypass the reactivation guard.
 PERFORM set_config('pandapay.admin_actor',current_setting('app.user_id'),true);
 PERFORM set_config('pandapay.admin_permission','learning.publish',true);
 BEGIN
  UPDATE transactions SET status='active' WHERE source_key='synthetic:bank';
  RAISE EXCEPTION 'legacy sync reactivated row';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
-- Even a private-role SET ROLE from a public-authenticated connection fails.
SET LOCAL ROLE pandapay_admin_api;
DO $$ BEGIN
 BEGIN
  PERFORM pandapay.sms_v2_unsupersede(current_setting('test.wp16_p1')::uuid);
  RAISE EXCEPTION 'untrusted session rollback allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL SESSION AUTHORIZATION admin_api_runtime;
SET LOCAL ROLE pandapay_admin_api;
SELECT set_config('pandapay.admin_actor',:'actor',true);
SELECT set_config('pandapay.admin_permission','learning.read',true);
DO $$ BEGIN
 BEGIN
  PERFORM pandapay.sms_v2_unsupersede(current_setting('test.wp16_p1')::uuid);
  RAISE EXCEPTION 'read permission rollback allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('pandapay.admin_permission','learning.publish',true);
DO $$ BEGIN
 IF pandapay.sms_v2_unsupersede(current_setting('test.wp16_p1')::uuid)<>2 THEN RAISE EXCEPTION 'legacy restore count wrong'; END IF;
 IF pandapay.sms_v2_unsupersede(current_setting('test.wp16_p1')::uuid)<>0 THEN RAISE EXCEPTION 'rollback not idempotent'; END IF;
END $$;
RESET ROLE;
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
 IF (SELECT count(*) FROM transactions WHERE profile_id=current_setting('test.wp16_p1')::uuid AND status='active')<>3 THEN RAISE EXCEPTION 'restore visibility wrong'; END IF;
 IF (SELECT status::text FROM transactions WHERE source_key='synthetic:v2')<>'ignored' THEN RAISE EXCEPTION 'v2 replacement still visible'; END IF;
 IF (SELECT state_applied FROM transactions WHERE source_key='synthetic:bank')<>true THEN RAISE EXCEPTION 'historical card state changed'; END IF;
 IF (SELECT status::text FROM transactions WHERE source_key='synthetic:deleted')<>'deleted' THEN RAISE EXCEPTION 'deleted row resurrected'; END IF;
 IF (SELECT status::text FROM transactions WHERE profile_id=current_setting('test.wp16_p2')::uuid)<>'superseded' THEN RAISE EXCEPTION 'other profile changed'; END IF;
 IF (SELECT count(*) FROM admin_audit_log WHERE action='sms_v2_unsupersede' AND entity_id=current_setting('test.wp16_p1')::uuid)<>2 THEN RAISE EXCEPTION 'rollback audit missing'; END IF;
END $$;
SELECT 'sms_v2_supersede ok' AS result;
ROLLBACK;
