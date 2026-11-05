-- A direct split is named by whoever created it (the name they typed for the
-- other person). The other person must see the creator instead, not their own
-- name. This only changes the label returned to a viewer; the stored name and
-- all financial data are untouched.
CREATE FUNCTION shared_expenses._context_label(p_kind text,p_name text,p_created_by uuid,p_viewer uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN p_kind='direct' AND p_created_by IS DISTINCT FROM p_viewer
  THEN coalesce((SELECT NULLIF(btrim(d.display_name),'') FROM shared_expenses.phone_directory d WHERE d.profile_id=p_created_by),'PandaPay friend')
  ELSE p_name END
$$;
ALTER FUNCTION shared_expenses._context_label(text,text,uuid,uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._context_label(text,text,uuid,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses._context_label(text,text,uuid,uuid) TO app_user;

-- Owners need the newest invitation per person and when it was made.
CREATE OR REPLACE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',q.display_name,
  'status',CASE WHEN q.declined_at IS NOT NULL THEN 'declined' WHEN q.state IN ('open','awaiting_owner') AND q.expires_at<=clock_timestamp() THEN 'expired' ELSE q.state END,
  'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,'claimantName',(SELECT NULLIF(btrim(d.display_name),'') FROM shared_expenses.phone_directory d WHERE d.profile_id=q.claimed_profile_id),'expiresAt',q.expires_at,'createdAt',q.created_at) ORDER BY q.created_at DESC,q.invitation_id DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR i.invitation_id>p_after) ORDER BY i.created_at DESC,i.invitation_id DESC LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;

-- create_invitation: keeps an existing phone binding when a new link is made.
CREATE OR REPLACE FUNCTION shared_expenses.create_invitation(p jsonb,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); id uuid:=(p->>'invitationId')::uuid; ctx uuid:=(p->>'contextId')::uuid; mid uuid:=(p->>'memberId')::uuid; r jsonb; expiry timestamptz; target text:=p->>'targetPhoneHash'; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(id,p_hash,'invitation.create',p,ctx);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND member_id=mid AND state='invited' AND profile_id IS NULL)
 THEN RAISE EXCEPTION 'invitation_conflict' USING ERRCODE='55000';END IF;
 -- Sending a fresh link for someone already invited by phone keeps that phone
 -- binding, so their in-app invite is never silently downgraded to a forwardable link.
 IF target IS NULL THEN SELECT i.target_phone_hash INTO target FROM shared_expenses.invitations i WHERE i.context_id=ctx AND i.member_id=mid AND i.target_phone_hash IS NOT NULL ORDER BY i.created_at DESC LIMIT 1; END IF;
 IF target IS NOT NULL THEN
  IF EXISTS(SELECT FROM shared_expenses.phone_directory WHERE profile_id=a AND phone_hash=target) THEN RAISE EXCEPTION 'invitation_self' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT FROM shared_expenses.phone_directory d JOIN shared_expenses.members m ON m.profile_id=d.profile_id
   WHERE d.phone_hash=target AND m.context_id=ctx AND m.state IN ('active','invited')) THEN RAISE EXCEPTION 'invitation_already_member' USING ERRCODE='55000'; END IF;
  IF EXISTS(SELECT FROM shared_expenses.invitations WHERE context_id=ctx AND member_id<>mid AND target_phone_hash=target AND state IN ('open','awaiting_owner','joined') AND expires_at>clock_timestamp())
  THEN RAISE EXCEPTION 'invitation_duplicate' USING ERRCODE='55000'; END IF;
  IF EXISTS(SELECT FROM shared_expenses.invitations WHERE issuer_profile_id=a AND target_phone_hash=target AND declined_at>clock_timestamp()-interval '7 days')
  THEN RAISE EXCEPTION 'invitation_declined_recently' USING ERRCODE='55000'; END IF;
 END IF;
 IF (SELECT count(*) FROM (SELECT 1 FROM shared_expenses.invitations WHERE issuer_profile_id=a AND created_at>clock_timestamp()-interval '1 hour' LIMIT 50) q)>=50
 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.invitations SET state='rejected' WHERE context_id=ctx AND member_id=mid AND state IN ('open','awaiting_owner');
 INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,target_phone_hash)
 VALUES(id,ctx,mid,a,p->>'tokenHash',target) RETURNING expires_at INTO expiry;
 RETURN shared_expenses._finish(id,jsonb_build_object('invitationId',id,'contextId',ctx,'memberId',mid,'status','open','expiresAt',expiry));
END $$;


-- Link-join requests waiting for the signed-in owner's decision.
CREATE FUNCTION shared_expenses.list_join_requests() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'contextId',q.context_id,'contextKind',q.kind,
  'contextName',q.name,'memberName',q.display_name,'verifiedPhoneSuffix',q.verified_phone_suffix,'claimantName',q.claimant_name,'createdAt',q.created_at) ORDER BY q.created_at DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.invitation_id,i.context_id,c.kind,shared_expenses._context_label(c.kind,c.name,c.created_by,a) AS name,m.display_name,i.verified_phone_suffix,(SELECT NULLIF(btrim(d.display_name),'') FROM shared_expenses.phone_directory d WHERE d.profile_id=i.claimed_profile_id) AS claimant_name,i.created_at
  FROM shared_expenses.invitations i
  JOIN shared_expenses.contexts c ON c.context_id=i.context_id AND c.state='active'
  JOIN shared_expenses.members m ON m.context_id=i.context_id AND m.member_id=i.member_id
  WHERE i.state='awaiting_owner' AND i.expires_at>clock_timestamp()
  AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
  ORDER BY i.created_at DESC LIMIT 20) q;
 RETURN jsonb_build_object('items',rows);
END $$;
ALTER FUNCTION shared_expenses.list_join_requests() OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.list_join_requests() FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.list_join_requests() TO app_user;

-- A member row without a stored name (the owner, or someone approved from a
-- link) is shown by the name that person chose in PandaPay, never as "Member".
CREATE FUNCTION shared_expenses._member_label(p_name text,p_profile uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT coalesce(NULLIF(btrim(p_name),''),(SELECT NULLIF(btrim(d.display_name),'') FROM shared_expenses.phone_directory d WHERE d.profile_id=p_profile))
$$;
ALTER FUNCTION shared_expenses._member_label(text,uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._member_label(text,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses._member_label(text,uuid) TO app_user;
