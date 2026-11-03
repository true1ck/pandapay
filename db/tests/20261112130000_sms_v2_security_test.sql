\set ON_ERROR_STOP on
BEGIN;
SELECT gen_random_uuid()::text AS p1, gen_random_uuid()::text AS p2 \gset
INSERT INTO profiles(id) VALUES (:'p1'::uuid), (:'p2'::uuid);
SET LOCAL ROLE app_user;
SELECT set_config('app.user_id', :'p1', true);
DO $$
DECLARE decision record;
BEGIN
  SELECT * INTO decision FROM pandapay.sms_v2_consume_rate(repeat('a',64),
    '[{"bucket":"facts:requests","seconds":60,"limit":2,"units":1},{"bucket":"facts:items","seconds":86400,"limit":5,"units":3}]');
  IF NOT decision.allowed THEN RAISE EXCEPTION 'first batch rejected'; END IF;
  SELECT * INTO decision FROM pandapay.sms_v2_consume_rate(repeat('a',64),
    '[{"bucket":"facts:requests","seconds":60,"limit":2,"units":1},{"bucket":"facts:items","seconds":86400,"limit":5,"units":3}]');
  IF decision.allowed OR decision.retry_after_seconds < 1 THEN RAISE EXCEPTION 'daily budget exceeded'; END IF;
  -- A denied batch did not consume the minute request budget.
  SELECT * INTO decision FROM pandapay.sms_v2_consume_rate(repeat('b',64),
    '[{"bucket":"facts:requests","seconds":60,"limit":2,"units":1},{"bucket":"facts:items","seconds":86400,"limit":5,"units":2}]');
  IF NOT decision.allowed THEN RAISE EXCEPTION 'denied batch charged quota'; END IF;
  SELECT * INTO decision FROM pandapay.sms_v2_consume_rate(repeat('c',64),
    '[{"bucket":"facts:requests","seconds":60,"limit":2,"units":1}]');
  IF decision.allowed THEN RAISE EXCEPTION 'device rotation bypassed profile limit'; END IF;
  IF EXISTS (SELECT 1 FROM public.sms_v2_rate_counters) THEN
    RAISE EXCEPTION 'counter data readable';
  END IF;
  BEGIN
    INSERT INTO public.sms_v2_rate_counters VALUES (pandapay.uid(), '', 'forged', now(), 0);
    RAISE EXCEPTION 'counter data writable';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM pandapay.sms_v2_consume_rate('bad', '[]');
    RAISE EXCEPTION 'invalid input allowed';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'invalid input allowed' THEN RAISE; END IF;
  END;
END $$;

SELECT set_config('app.user_id', :'p2', true);
DO $$ DECLARE decision record; BEGIN
  SELECT * INTO decision FROM pandapay.sms_v2_consume_rate(repeat('a',64),
    '[{"bucket":"facts:requests","seconds":60,"limit":2,"units":1},{"bucket":"facts:items","seconds":86400,"limit":5,"units":3}]');
  IF NOT decision.allowed THEN RAISE EXCEPTION 'other account quota affected'; END IF;
END $$;
RESET ROLE;
SELECT 'sms_v2_security ok' AS result;
ROLLBACK;
