-- Learning loop B7: controls the console needs for everything the loop does.
-- A layout an admin blocked is never sent to the AI; the audit feed and the
-- reporters list give the console counts and history without raw tables.
ALTER TABLE public.sms_v2_unknown_templates DROP CONSTRAINT sms_v2_unknown_templates_ai_status_check;
ALTER TABLE public.sms_v2_unknown_templates ADD CONSTRAINT sms_v2_unknown_templates_ai_status_check
  CHECK (ai_status IN ('held', 'queued', 'working', 'ready', 'failed', 'covered', 'blocked'));

-- The recent learning-loop changes (settings, limits, decisions, rejections,
-- publishes), newest first. Only the columns the console shows: never the
-- before or after bodies.
CREATE FUNCTION pandapay.sms_v2_audit_feed(p_limit integer) RETURNS TABLE(
  at timestamptz, admin_id uuid, action text, entity text, entity_id uuid, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'audit limit invalid' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
    SELECT l.created_at, l.admin_id, l.action, l.entity, l.entity_id, l.reason
      FROM public.admin_audit_log l
     WHERE l.action LIKE 'sms\_v2\_%'
     ORDER BY l.created_at DESC, l.id DESC
     LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_audit_feed(integer) FROM PUBLIC, app_user, pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_audit_feed(integer) TO pandapay_admin_api;

-- The accounts that sent the most to the learning loop in the last p_days:
-- counts only, by the pseudonymous account id.
CREATE FUNCTION pandapay.sms_v2_learning_reporters(p_days integer) RETURNS TABLE(
  profile_id uuid, signals bigint, layouts bigint, corrections bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE since timestamptz;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.read') THEN
    RAISE EXCEPTION 'private learning.read permission required' USING ERRCODE = '42501';
  END IF;
  IF p_days IS NULL OR p_days NOT BETWEEN 1 AND 90 THEN
    RAISE EXCEPTION 'reporters window invalid' USING ERRCODE = '22023';
  END IF;
  since := clock_timestamp() - make_interval(days => p_days);
  RETURN QUERY
    WITH s AS (SELECT t.profile_id, count(*) AS n FROM public.sms_v2_learning_signals t WHERE t.last_at >= since GROUP BY 1),
         l AS (SELECT t.profile_id, count(*) AS n FROM public.sms_v2_template_submitters t WHERE t.last_submitted >= since GROUP BY 1),
         c AS (SELECT t.profile_id, count(*) AS n FROM public.sms_v2_correction_cases t WHERE t.created_at >= since GROUP BY 1),
         everyone AS (SELECT s.profile_id FROM s UNION SELECT l.profile_id FROM l UNION SELECT c.profile_id FROM c)
    SELECT e.profile_id, coalesce(s.n, 0)::bigint, coalesce(l.n, 0)::bigint, coalesce(c.n, 0)::bigint
      FROM everyone e LEFT JOIN s USING (profile_id) LEFT JOIN l USING (profile_id) LEFT JOIN c USING (profile_id)
     ORDER BY (coalesce(s.n, 0) + coalesce(l.n, 0) + coalesce(c.n, 0)) DESC, e.profile_id
     LIMIT 20;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_learning_reporters(integer) FROM PUBLIC, app_user, pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_learning_reporters(integer) TO pandapay_admin_api;
