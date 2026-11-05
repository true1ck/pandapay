-- Learning loop A5: anonymised shop signals (category choices, shop-name fixes,
-- shops left in "Other"), one row per person, kind, sender, shop key and value.
-- The server counts distinct people; a row never holds an amount, date, account
-- number or person's name. Keys are filtered here too (see the CHECKs).
CREATE TABLE public.sms_v2_learning_signals (
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('category_choice', 'merchant_name', 'uncategorised')),
  sender_brand text NOT NULL CHECK (sender_brand ~ '^[A-Z0-9]{1,32}$'),
  merchant_key text NOT NULL CHECK (merchant_key ~ '^[A-Z][A-Z0-9 &''.-]{1,59}$' AND merchant_key !~ '[0-9]{4,}'),
  value text NOT NULL CHECK (length(value) <= 40 AND value !~ '[0-9@]'),
  taxonomy_version integer NOT NULL CHECK (taxonomy_version >= 1),
  eligible boolean NOT NULL,
  is_tester boolean NOT NULL,
  times integer NOT NULL DEFAULT 1 CHECK (times >= 1),
  first_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (profile_id, kind, sender_brand, merchant_key, value)
);
CREATE INDEX sms_v2_learning_signals_key ON public.sms_v2_learning_signals (kind, merchant_key);
CREATE INDEX sms_v2_learning_signals_last ON public.sms_v2_learning_signals (last_at);
ALTER TABLE public.sms_v2_learning_signals ENABLE ROW LEVEL SECURITY;
CREATE POLICY private_read ON public.sms_v2_learning_signals FOR SELECT TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.read'));
CREATE POLICY private_prune ON public.sms_v2_learning_signals FOR DELETE TO pandapay_admin_api
  USING (pandapay.admin_has_permission('learning.publish') AND current_setting('pandapay.admin_permission',true)='learning.publish');
GRANT SELECT, DELETE ON public.sms_v2_learning_signals TO pandapay_admin_api;

CREATE FUNCTION pandapay.sms_v2_submit_signals(p_items jsonb, p_eligible boolean) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE profile uuid := pandapay.uid(); item jsonb; used integer; n integer := 0;
BEGIN
  IF profile IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE = '42501'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid signal batch' USING ERRCODE = '22023';
  END IF;
  -- The same lock as consent changes and layout admission: a revocation wins in order.
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || profile::text, 0));
  IF NOT pandapay.sms_shared_learning_granted(profile) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO used FROM sms_v2_learning_signals
   WHERE profile_id = profile AND last_at >= (date_trunc('day', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc');
  IF used + jsonb_array_length(p_items) > pandapay.sms_v2_limit(profile, 'signals_per_user_per_day', 500) THEN
    RAISE EXCEPTION 'signal daily cap' USING ERRCODE = 'P0050';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO sms_v2_learning_signals
      (profile_id, kind, sender_brand, merchant_key, value, taxonomy_version, eligible, is_tester)
    VALUES (profile, item->>'kind', item->>'senderBrand', item->>'merchantKey', item->>'value',
            (item->>'taxonomyVersion')::integer, p_eligible, pandapay.sms_v2_is_tester())
    ON CONFLICT (profile_id, kind, sender_brand, merchant_key, value) DO UPDATE
      SET times = sms_v2_learning_signals.times + 1, last_at = clock_timestamp(),
          eligible = sms_v2_learning_signals.eligible OR excluded.eligible;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_submit_signals(jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_submit_signals(jsonb, boolean) TO app_user;

-- Withdrawing (or no longer holding a v3 opt-in) deletes what the person shared.
-- Like the other consent triggers, only the latest consent event counts, so a
-- backdated opt-out cannot erase a current consent.
CREATE FUNCTION pandapay.sms_v2_revoke_signals() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || NEW.profile_id::text, 0));
  IF NOT pandapay.sms_shared_learning_granted(NEW.profile_id) THEN
    DELETE FROM sms_v2_learning_signals WHERE profile_id = NEW.profile_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_revoke_signals() FROM PUBLIC;
CREATE TRIGGER sms_v2_revoke_signals AFTER INSERT OR UPDATE OF granted, granted_at ON user_consents
  FOR EACH ROW WHEN (NEW.purpose = 'sms_shared_learning')
  EXECUTE FUNCTION pandapay.sms_v2_revoke_signals();
