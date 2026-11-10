-- Roll the AI drafts out to every registered member, not a list of accounts.
--
-- A phone that cannot pass App Check (a sideloaded or Staging build, or a failed
-- attestation) has its layouts stored held and gets nothing back. Until now the
-- only way past that was to list the account in sms_v2_testers and switch on
-- `testers_count_without_attestation`. The console setting
-- `members_count_without_attestation` does the same for everyone: when it is on,
-- every member who agreed to share counts like an attested phone. OFF by
-- default; with it off, behaviour is exactly as before. The setting's audit
-- trail (reason, who, when) is the console's existing one.
--
-- The function keeps its name and grants so the API needs no other change.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_tester_counts() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (EXISTS (SELECT 1 FROM sms_v2_testers t WHERE t.profile_id = pandapay.uid())
           AND coalesce((SELECT value = 'true'::jsonb FROM sms_v2_settings WHERE key = 'testers_count_without_attestation'), false))
      OR (pandapay.uid() IS NOT NULL
           AND coalesce((SELECT value = 'true'::jsonb FROM sms_v2_settings WHERE key = 'members_count_without_attestation'), false))
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_tester_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_tester_counts() TO app_user, pandapay_admin_api;
