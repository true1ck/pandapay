-- Friends run: let the owner see what a tester's phone sends even when the phone cannot pass App Check (a free
-- Apple developer account cannot attest). OFF by default. When the console setting
-- `testers_count_without_attestation` is on, a profile that is in sms_v2_testers counts as eligible for the
-- Learning page and shared cases like an attested phone. Everyone else is unchanged, and the setting's own
-- audit trail (reason, who, when) is the console's existing one.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_tester_counts() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM sms_v2_testers t WHERE t.profile_id = pandapay.uid())
     AND coalesce((SELECT value = 'true'::jsonb FROM sms_v2_settings WHERE key = 'testers_count_without_attestation'), false)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_tester_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_tester_counts() TO app_user, pandapay_admin_api;
