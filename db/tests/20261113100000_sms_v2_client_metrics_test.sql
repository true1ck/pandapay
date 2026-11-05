\set ON_ERROR_STOP on
-- Lane N: phone-reported release counters. Aggregates carry no profile or device id,
-- consent is enforced, an upload counts once, and only a trusted learning.read admin reads.
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='admin_api_runtime') THEN
  CREATE ROLE admin_api_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
END $$;
GRANT pandapay_admin_api TO admin_api_runtime;
SELECT gen_random_uuid()::text AS p1, gen_random_uuid()::text AS p2, gen_random_uuid()::text AS p3,
       gen_random_uuid()::text AS actor, gen_random_uuid()::text AS nobody,
       (now() AT TIME ZONE 'utc')::date - 1 AS yday \gset
INSERT INTO profiles(id) VALUES(:'p1'::uuid),(:'p2'::uuid),(:'p3'::uuid);
INSERT INTO admin_users(id,email,role,is_active) VALUES(:'actor'::uuid, :'actor'||'@lanen.invalid','operator',true);
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(:'p1'::uuid,'sms_shared_learning','t',true,now()),(:'p2'::uuid,'sms_shared_learning','t',true,now()),
       (:'p3'::uuid,'sms_shared_learning','t',false,now());
SELECT set_config('test.lanen_nobody',:'nobody',true);

SET LOCAL ROLE app_user;
SELECT set_config('app.user_id', :'p1', true);
DO $$
DECLARE yday date := (now() AT TIME ZONE 'utc')::date - 1; r text;
BEGIN
 r := pandapay.sms_v2_record_client_metrics(repeat('a',64), yday, '1.2.3+4', 'verified',
   '{"sync_attempts":10,"sync_errors_network":1,"migration_started":1,"migration_completed":1}');
 IF r <> 'recorded' THEN RAISE EXCEPTION 'first upload not recorded: %', r; END IF;
 -- A re-sent upload from the same device and day counts once.
 r := pandapay.sms_v2_record_client_metrics(repeat('a',64), yday, '1.2.3+4', 'verified', '{"sync_attempts":10}');
 IF r <> 'duplicate' THEN RAISE EXCEPTION 'duplicate counted: %', r; END IF;
 -- Another device of the same account is a separate report.
 r := pandapay.sms_v2_record_client_metrics(repeat('b',64), yday, '1.2.3+4', 'verified', '{"sync_attempts":5}');
 IF r <> 'recorded' THEN RAISE EXCEPTION 'second device not recorded: %', r; END IF;
 -- Tables are closed to the application role.
 IF EXISTS(SELECT 1 FROM public.sms_v2_client_metrics_daily) THEN RAISE EXCEPTION 'aggregate readable'; END IF;
 IF EXISTS(SELECT 1 FROM public.sms_v2_client_metric_receipts) THEN RAISE EXCEPTION 'receipts readable'; END IF;
 BEGIN INSERT INTO public.sms_v2_client_metrics_daily VALUES(yday,'1','verified','sync_attempts',999999); RAISE EXCEPTION 'aggregate writable';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 -- Validation: unknown metric, content-like key, non-integer, over cap, empty, stale or future day, bad digest, bad version.
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'verified', '{"merchant":3}'); RAISE EXCEPTION 'unknown metric accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'verified', '{"sync_attempts":1.5}'); RAISE EXCEPTION 'fraction accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'verified', '{"sync_attempts":"HDFC debited"}'); RAISE EXCEPTION 'text value accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'verified', '{"sync_attempts":10001}'); RAISE EXCEPTION 'over cap accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'verified', '{"sync_attempts":0}'); RAISE EXCEPTION 'all-zero accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday - 30, '1', 'verified', '{"sync_attempts":1}'); RAISE EXCEPTION 'stale day accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday + 5, '1', 'verified', '{"sync_attempts":1}'); RAISE EXCEPTION 'future day accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics('short', yday, '1', 'verified', '{"sync_attempts":1}'); RAISE EXCEPTION 'bad digest accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, 'a b; drop', 'verified', '{"sync_attempts":1}'); RAISE EXCEPTION 'bad version accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('c',64), yday, '1', 'maybe', '{"sync_attempts":1}'); RAISE EXCEPTION 'bad attestation accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;

-- Second account, unverified, a different version.
SELECT set_config('app.user_id', :'p2', true);
DO $$ DECLARE yday date := (now() AT TIME ZONE 'utc')::date - 1; r text; BEGIN
 r := pandapay.sms_v2_record_client_metrics(repeat('a',64), yday, '1.2.4+5', 'unverified',
   '{"sync_attempts":20,"sync_errors_server":2,"migration_started":2,"migration_failed":1,"bundle_download_failures":3}');
 IF r <> 'recorded' THEN RAISE EXCEPTION 'p2 not recorded: %', r; END IF;
END $$;

-- No sharing consent: nothing is stored.
SELECT set_config('app.user_id', :'p3', true);
DO $$ DECLARE yday date := (now() AT TIME ZONE 'utc')::date - 1; r text; BEGIN
 r := pandapay.sms_v2_record_client_metrics(repeat('a',64), yday, '1.2.3+4', 'verified', '{"sync_attempts":500}');
 IF r <> 'no_consent' THEN RAISE EXCEPTION 'upload without consent accepted: %', r; END IF;
END $$;
-- Withdrawal after an earlier grant also stops the upload.
RESET ROLE;
INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at)
 VALUES(:'p1'::uuid,'sms_shared_learning','t',false,now() + interval '1 second');
SET LOCAL ROLE app_user;
SELECT set_config('app.user_id', :'p1', true);
DO $$ DECLARE yday date := (now() AT TIME ZONE 'utc')::date - 1; r text; BEGIN
 r := pandapay.sms_v2_record_client_metrics(repeat('d',64), yday, '1.2.3+4', 'verified', '{"sync_attempts":500}');
 IF r <> 'no_consent' THEN RAISE EXCEPTION 'withdrawn consent accepted: %', r; END IF;
END $$;
-- No account, no write.
SELECT set_config('app.user_id', '', true);
DO $$ DECLARE yday date := (now() AT TIME ZONE 'utc')::date - 1; BEGIN
 BEGIN PERFORM pandapay.sms_v2_record_client_metrics(repeat('a',64), yday, '1', 'verified', '{"sync_attempts":1}'); RAISE EXCEPTION 'anonymous accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM pandapay.sms_v2_client_metrics_report(now() - interval '7 days'); RAISE EXCEPTION 'app role read report';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Untrusted private session: permission check fails.
SET LOCAL ROLE pandapay_admin_api;
DO $$ BEGIN
 BEGIN PERFORM pandapay.sms_v2_client_metrics_report(now() - interval '7 days'); RAISE EXCEPTION 'untrusted session read report';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Trusted runtime with an unknown actor: denied.
SET LOCAL SESSION AUTHORIZATION admin_api_runtime;
SET LOCAL ROLE pandapay_admin_api;
SELECT set_config('pandapay.admin_actor',current_setting('test.lanen_nobody'),true);
DO $$ BEGIN
 BEGIN PERFORM pandapay.sms_v2_client_metrics_report(now() - interval '7 days'); RAISE EXCEPTION 'unknown actor read report';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

-- Trusted operator: aggregates only.
SELECT set_config('pandapay.admin_actor',:'actor',true);
DO $$
DECLARE m jsonb; t jsonb;
BEGIN
 m := pandapay.sms_v2_client_metrics_report(now() - interval '7 days');
 t := m->'totals';
 IF (t->>'sync_attempts')::int <> 35 THEN RAISE EXCEPTION 'sync_attempts wrong: %', m; END IF;
 IF (t->>'sync_errors_network')::int <> 1 OR (t->>'sync_errors_server')::int <> 2 THEN RAISE EXCEPTION 'errors wrong: %', m; END IF;
 IF (t->>'migration_started')::int <> 3 OR (t->>'migration_completed')::int <> 1 OR (t->>'migration_failed')::int <> 1 THEN
   RAISE EXCEPTION 'migration wrong: %', m; END IF;
 IF (t->>'bundle_download_failures')::int <> 3 THEN RAISE EXCEPTION 'bundle failures wrong: %', m; END IF;
 IF (m->>'reports')::int <> 3 THEN RAISE EXCEPTION 'report count wrong: %', m; END IF;
 IF jsonb_array_length(m->'byVersion') <> 2 THEN RAISE EXCEPTION 'version split wrong: %', m; END IF;
 IF NOT (m->'byVersion') @> '[{"appVersion":"1.2.4+5","attestation":"unverified"}]'::jsonb THEN RAISE EXCEPTION 'attestation split wrong: %', m; END IF;
 IF m::text ~* '(profile|device|digest|[0-9a-f]{64}|consent)' THEN RAISE EXCEPTION 'identifier leaked: %', m; END IF;
 BEGIN PERFORM pandapay.sms_v2_client_metrics_report(now() + interval '1 day'); RAISE EXCEPTION 'future window accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
RESET ROLE;
RESET SESSION AUTHORIZATION;

-- The aggregate table itself holds no profile or device column.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='sms_v2_client_metrics_daily'
           AND column_name ~ '(profile|device|user|account)') THEN
  RAISE EXCEPTION 'aggregate table has an identifying column';
 END IF;
END $$;
SELECT 'sms_v2_client_metrics ok' AS result;
ROLLBACK;
