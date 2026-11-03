-- SMS v2 tables were introduced after private admin authority was provisioned.
-- Preserve the authenticated private runtime and per-operation permission checks.
DO $$ DECLARE t text; guard text; BEGIN
  guard := 'pandapay.admin_has_permission(''learning.publish'') AND current_setting(''pandapay.admin_permission'',true)=''learning.publish''';
  FOREACH t IN ARRAY ARRAY[
    'sms_v2_rules','sms_v2_rule_cohorts','sms_v2_bundles','sms_v2_bundle_parts',
    'sms_v2_testers','sms_v2_rule_stats_daily','sms_v2_rule_stats_profile_daily'
  ] LOOP
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON public.%I TO pandapay_admin_api',t);
    EXECUTE format('CREATE POLICY private_admin_read_guard ON public.%I AS RESTRICTIVE FOR SELECT TO pandapay_admin_api USING (pandapay.admin_has_permission(''learning.read''))',t);
    EXECUTE format('CREATE POLICY private_admin_insert_guard ON public.%I AS RESTRICTIVE FOR INSERT TO pandapay_admin_api WITH CHECK (%s)',t,guard);
    EXECUTE format('CREATE POLICY private_admin_update_guard ON public.%I AS RESTRICTIVE FOR UPDATE TO pandapay_admin_api USING (%s) WITH CHECK (%s)',t,guard,guard);
    EXECUTE format('CREATE POLICY private_admin_delete_guard ON public.%I AS RESTRICTIVE FOR DELETE TO pandapay_admin_api USING (%s)',t,guard);
  END LOOP;
END $$;

-- The rollup bypasses RLS as its owner, so check the private permission here too.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_rollup_rule_stats() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n integer;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.publish') OR
     current_setting('pandapay.admin_permission',true) IS DISTINCT FROM 'learning.publish' THEN
    RAISE EXCEPTION 'admin permission required' USING ERRCODE='42501';
  END IF;
  INSERT INTO sms_v2_rule_stats_daily (day, rule_id, rule_version, app_version, hits, to_review, corrected, devices)
  SELECT day, rule_id, rule_version, app_version,
         sum(hits), sum(to_review), sum(corrected), count(DISTINCT profile_id)
    FROM sms_v2_rule_stats_profile_daily
   GROUP BY day, rule_id, rule_version, app_version
  ON CONFLICT (day, rule_id, rule_version, app_version) DO UPDATE
     SET hits=excluded.hits, to_review=excluded.to_review,
         corrected=excluded.corrected, devices=excluded.devices;
  GET DIAGNOSTICS n=ROW_COUNT;
  DELETE FROM sms_v2_rule_stats_profile_daily WHERE day < (now() AT TIME ZONE 'utc')::date - 2;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_rollup_rule_stats() FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_rollup_rule_stats() TO pandapay_admin_api;
