-- Who may see whose avatar. Avatars live in the sign-in service's database, so the
-- API asks this one question before it fetches one: do the caller and the other
-- person belong to a common active Split context?
--
-- Returns only a boolean. It never returns the context, the member rows or anything
-- else, and "unknown id" and "no shared context" both answer false (no oracle).
-- The caller's own id is always true (own avatar).
--
-- Feature flag: like every other Split read (_can_read_context), seeing another
-- member is gated on shared_expenses.settings.reads_enabled. With reads off, only the
-- caller's own avatar is visible through this function.
CREATE FUNCTION shared_expenses.shares_context_with(p_other uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor();
BEGIN
 IF p_other IS NULL THEN RETURN false; END IF;
 IF p_other=a THEN RETURN true; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.settings WHERE reads_enabled) THEN RETURN false; END IF;
 RETURN EXISTS(
  SELECT FROM shared_expenses.members me
  JOIN shared_expenses.members them ON them.context_id=me.context_id
  JOIN shared_expenses.contexts c ON c.context_id=me.context_id
  WHERE me.profile_id=a AND me.state='active'
    AND them.profile_id=p_other AND them.state='active'
    AND c.state='active');
END $$;
ALTER FUNCTION shared_expenses.shares_context_with(uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.shares_context_with(uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.shares_context_with(uuid) TO app_user;

-- The other person's own PandaPay name, for a small "PandaPay name: ..." line under
-- the name the caller saved for them. Same visibility rule as avatars: only someone
-- who shares an active Split context (or the caller's own id) gets it; everyone else
-- gets NULL, indistinguishable from "no name". The name is read as the owner role,
-- which already has a read policy on profiles for the member-label functions.
CREATE FUNCTION shared_expenses.member_profile_name(p_other uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
BEGIN
 IF p_other IS NULL OR NOT shared_expenses.shares_context_with(p_other) THEN RETURN NULL; END IF;
 RETURN (SELECT left(NULLIF(btrim(p.display_name),''),120) FROM public.profiles p WHERE p.id=p_other);
END $$;
ALTER FUNCTION shared_expenses.member_profile_name(uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.member_profile_name(uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.member_profile_name(uuid) TO app_user;
