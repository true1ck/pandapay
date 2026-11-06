-- Who must hear about a join request or an accepted invite.
-- A person who has just claimed a link is not a member yet, so they cannot read
-- the roster. This returns only what the notifier needs, and only to the person
-- who actually claimed that exact invitation: the active owners' profile ids,
-- the context name and the display name the inviter gave the claimant.
CREATE FUNCTION shared_expenses.invitation_audience(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token_hash;
 IF NOT FOUND OR i.claimed_profile_id IS DISTINCT FROM a THEN
  RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';
 END IF;
 RETURN jsonb_build_object(
  'contextId',i.context_id,
  'contextName',(SELECT c.name FROM shared_expenses.contexts c WHERE c.context_id=i.context_id AND c.kind='group'),
  'claimantName',(SELECT m.display_name FROM shared_expenses.members m WHERE m.context_id=i.context_id AND m.member_id=i.member_id),
  'owners',(SELECT coalesce(jsonb_agg(m.profile_id ORDER BY m.member_id),'[]'::jsonb) FROM shared_expenses.members m
            WHERE m.context_id=i.context_id AND m.role='owner' AND m.state='active' AND m.profile_id IS NOT NULL AND m.profile_id<>a));
END $$;
ALTER FUNCTION shared_expenses.invitation_audience(text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.invitation_audience(text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.invitation_audience(text) TO app_user;
