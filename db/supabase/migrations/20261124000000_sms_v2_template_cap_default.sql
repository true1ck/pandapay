-- A registered member who shares layouts gets every unknown format resolved: no waiting on a daily cap.
--
-- The layout upload function read its per-person daily cap as
-- sms_v2_limit(profile, 'templates_per_user_per_day', 50): a person's override, else the console setting,
-- else 50. A long inbox holds more than 50 unknown formats, so the rest stayed unsent until the next day.
-- The fallback when nothing is set is now 10000. The console setting and per-person overrides still win,
-- so the owner can lower the cap again at any time. Only this one key changes; every other key keeps the
-- default its caller passes.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_limit(p_profile uuid, p_key text, p_default integer) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(
    (SELECT value FROM sms_v2_user_limits
      WHERE profile_id = p_profile AND key = p_key AND expires_at > now()),
    (SELECT (value #>> '{}')::integer FROM sms_v2_settings WHERE key = p_key),
    CASE WHEN p_key = 'templates_per_user_per_day' THEN 10000 ELSE p_default END)
$$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_limit(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_limit(uuid, text, integer) TO app_user, pandapay_admin_api;
