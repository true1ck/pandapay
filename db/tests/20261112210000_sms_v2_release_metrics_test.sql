\set ON_ERROR_STOP on
-- Lane C: pandapay.sms_v2_release_metrics returns cross-profile aggregates to a
-- trusted private learning.read caller only, and nothing else.
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='admin_api_runtime') THEN
  CREATE ROLE admin_api_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
END $$;
GRANT pandapay_admin_api TO admin_api_runtime;
SELECT gen_random_uuid()::text AS p1, gen_random_uuid()::text AS p2, gen_random_uuid()::text AS actor, gen_random_uuid()::text AS nobody \gset
INSERT INTO profiles(id) VALUES(:'p1'::uuid),(:'p2'::uuid);
INSERT INTO admin_users(id,email,role,is_active) VALUES(:'actor'::uuid, :'actor'||'@lanec.invalid','operator',true);
INSERT INTO sms_v2_facts(fact_id,profile_id,source_key,fact_type,contract_version,observed_at,payload,provenance)
 VALUES(repeat('1',64),:'p1'::uuid,'synthetic:1','movement','2.0',now(),'{}','{}'),
       (repeat('2',64),:'p1'::uuid,'synthetic:2','movement','2.0',now(),'{}','{}'),
       (repeat('3',64),:'p2'::uuid,'synthetic:3','movement','2.0',now(),'{}','{}');
INSERT INTO sms_v2_events(event_id,profile_id,type,status,legs,confidence,occurred_at,amount_minor)
 VALUES(repeat('a',64),:'p1'::uuid,'purchase','complete','[{"factId":"synthetic","role":"debit_leg"}]',1,now(),10000),
       (repeat('b',64),:'p2'::uuid,'purchase','complete','[{"factId":"synthetic","role":"debit_leg"}]',1,now(),10000),
       (repeat('c',64),:'p2'::uuid,'purchase','complete','[{"factId":"synthetic","role":"debit_leg"}]',1,now(),10000);
UPDATE sms_v2_events SET updated_at = now() - interval '30 days' WHERE event_id = repeat('c',64);
INSERT INTO transactions(profile_id,source_key,source,amount_inr,occurred_at,status,superseded_by_event_id,state_applied)
 VALUES(:'p1'::uuid,'synthetic:legacy','sms',100,now(),'superseded',repeat('a',64),true);
INSERT INTO sms_v2_rate_counters(profile_id,device_digest,bucket,window_start,used)
 VALUES(:'p1'::uuid,'','rules',date_trunc('hour',now()),3),
       (:'p1'::uuid,repeat('d',64),'rules',date_trunc('hour',now()),3),
       (:'p2'::uuid,'','rules',date_trunc('hour',now()),2),
       (:'p2'::uuid,'','sync',date_trunc('hour',now()),7);
SELECT set_config('test.lanec_nobody',:'nobody',true);

-- Public application role: no execute.
SET LOCAL ROLE app_user;
DO $$ BEGIN
 BEGIN
  PERFORM pandapay.sms_v2_release_metrics(now() - interval '7 days');
  RAISE EXCEPTION 'public role executed release metrics';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Untrusted session using the private role: permission check fails.
SET LOCAL ROLE pandapay_admin_api;
DO $$ BEGIN
 BEGIN
  PERFORM pandapay.sms_v2_release_metrics(now() - interval '7 days');
  RAISE EXCEPTION 'untrusted session read release metrics';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Trusted runtime, unknown actor: denied.
SET LOCAL SESSION AUTHORIZATION admin_api_runtime;
SET LOCAL ROLE pandapay_admin_api;
SELECT set_config('pandapay.admin_actor',current_setting('test.lanec_nobody'),true);
DO $$ BEGIN
 BEGIN
  PERFORM pandapay.sms_v2_release_metrics(now() - interval '7 days');
  RAISE EXCEPTION 'unknown actor read release metrics';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

-- Trusted runtime, operator with learning.read: aggregates across profiles.
SELECT set_config('pandapay.admin_actor',:'actor',true);
DO $$
DECLARE m jsonb;
BEGIN
 m := pandapay.sms_v2_release_metrics(now() - interval '7 days');
 IF (m->>'newEvents')::int <> 2 THEN RAISE EXCEPTION 'newEvents wrong: %', m; END IF;
 IF (m->>'newFacts')::int <> 3 THEN RAISE EXCEPTION 'newFacts wrong: %', m; END IF;
 IF (m->>'activeProfiles30d')::int <> 2 THEN RAISE EXCEPTION 'activeProfiles30d wrong: %', m; END IF;
 IF (m->>'profilesWithV2Facts')::int <> 2 THEN RAISE EXCEPTION 'profilesWithV2Facts wrong: %', m; END IF;
 IF (m->>'profilesWithSupersededLegacy')::int < 1 THEN RAISE EXCEPTION 'superseded count wrong: %', m; END IF;
 IF (m->'rateUsed'->>'rules')::int <> 5 THEN RAISE EXCEPTION 'rules checks must count profile rows only: %', m; END IF;
 IF (m->'rateUsed'->>'sync')::int <> 7 THEN RAISE EXCEPTION 'sync calls wrong: %', m; END IF;
 IF m::text ~* '(profile_id|fact_id|source_key|synthetic)' THEN RAISE EXCEPTION 'identifiers leaked: %', m; END IF;
 BEGIN
  PERFORM pandapay.sms_v2_release_metrics(now() + interval '1 day');
  RAISE EXCEPTION 'future window accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN
  PERFORM pandapay.sms_v2_release_metrics(now() - interval '120 days');
  RAISE EXCEPTION 'over-long window accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT 'sms_v2_release_metrics ok' AS result;
ROLLBACK;
