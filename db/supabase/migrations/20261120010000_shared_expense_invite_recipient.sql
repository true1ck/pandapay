-- Who should get a push when someone is invited by phone number.
-- Only the person who issued that exact invitation can call this. It returns
-- the recipient's profile id solely when the invitation is bound to a phone
-- number that a PandaPay account has registered (the same number match that
-- already puts the invite in that person's in-app inbox), plus the group name
-- and the inviter's display name. It never returns a number or a hash.
CREATE FUNCTION shared_expenses.invitation_recipient(p_invitation uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation;
 IF NOT FOUND OR i.issuer_profile_id IS DISTINCT FROM a THEN
  RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';
 END IF;
 IF i.target_phone_hash IS NULL OR i.state<>'open' THEN
  RETURN jsonb_build_object('recipient',NULL);
 END IF;
 RETURN jsonb_build_object(
  'recipient',(SELECT d.profile_id FROM shared_expenses.phone_directory d WHERE d.phone_hash=i.target_phone_hash AND d.profile_id<>a LIMIT 1),
  'contextName',(SELECT c.name FROM shared_expenses.contexts c WHERE c.context_id=i.context_id AND c.kind='group'),
  'inviterName',(SELECT d.display_name FROM shared_expenses.phone_directory d WHERE d.profile_id=a LIMIT 1));
END $$;
ALTER FUNCTION shared_expenses.invitation_recipient(uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.invitation_recipient(uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.invitation_recipient(uuid) TO app_user;
