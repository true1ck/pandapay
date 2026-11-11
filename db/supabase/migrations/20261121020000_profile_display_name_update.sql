-- A person editing their own display name.
--
-- app_user may not UPDATE public.profiles directly: setup_app_role.sql revokes it
-- (leaving only contributions_opt_in and the two deletion columns) and is re-run
-- after migrations. Profile writes therefore go through narrow SECURITY DEFINER
-- routines, like promotions.activate_current_user. This one changes ONE column of
-- ONE row, the caller's own, and nothing else.
--
-- The same rules as the API and the app: spaces collapsed and trimmed, 1 to 60
-- characters, no angle brackets and no control characters.
CREATE FUNCTION promotions.set_current_user_display_name(p_name text) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pandapay, pg_temp AS $$
DECLARE
 v_user_id uuid := pandapay.uid();
 v_name text;
BEGIN
 IF v_user_id IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='authentication_required';
 END IF;
 v_name := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
 IF char_length(v_name) NOT BETWEEN 1 AND 60 OR v_name ~ '[<>[:cntrl:]]' THEN
  RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='invalid_display_name';
 END IF;
 UPDATE public.profiles SET display_name = v_name, updated_at = now() WHERE id = v_user_id;
 IF NOT FOUND THEN
  RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='profile_not_found';
 END IF;
 RETURN v_name;
END $$;
REVOKE ALL ON FUNCTION promotions.set_current_user_display_name(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION promotions.set_current_user_display_name(text) TO app_user;
