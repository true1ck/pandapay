-- Member labels behave like phone contacts.
--  1. The name the inviter typed for a person (members.display_name) always wins.
--  2. Otherwise the person's LIVE PandaPay name (public.profiles.display_name),
--     never the stale copy in shared_expenses.phone_directory.
--  3. Otherwise 'Former member' when the account is gone (profile_id IS NULL).
-- Also adds the member.rename command, and lets the join-request surfaces show
-- the live name of whoever opened the link.

-- The label functions below run as shared_expenses_owner and must read OTHER
-- people's names. profiles is row-level-secured to its owner, so grant this one
-- role a read policy (it already holds SELECT on the table).
DROP POLICY IF EXISTS profiles_shared_expenses_read ON public.profiles;
CREATE POLICY profiles_shared_expenses_read ON public.profiles FOR SELECT TO shared_expenses_owner USING(true);

CREATE OR REPLACE FUNCTION shared_expenses._member_label(p_name text,p_profile uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN NULLIF(btrim(p_name),'') IS NOT NULL THEN btrim(p_name)
  WHEN p_profile IS NULL THEN 'Former member'
  ELSE (SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=p_profile) END
$$;
ALTER FUNCTION shared_expenses._member_label(text,uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._member_label(text,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses._member_label(text,uuid) TO app_user;

-- A direct split is titled by the OTHER person's current label: the name the
-- inviter typed for them if any, else their live PandaPay name. The creator sees
-- the invited friend's row; anyone else sees the creator's row. Falls back to the
-- old behaviour (typed split name / directory copy / 'PandaPay friend'). Groups
-- are unchanged, and a NULL context id keeps the old behaviour.
CREATE FUNCTION shared_expenses._context_label(p_kind text,p_name text,p_created_by uuid,p_viewer uuid,p_context uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT coalesce(
  CASE WHEN p_kind='direct' AND p_context IS NOT NULL THEN
   (SELECT coalesce(NULLIF(btrim(m.display_name),''),(SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=m.profile_id))
      FROM shared_expenses.members m
     WHERE m.context_id=p_context AND m.state IN ('active','invited')
       AND CASE WHEN p_viewer IS NOT DISTINCT FROM p_created_by THEN m.profile_id IS DISTINCT FROM p_viewer ELSE m.profile_id IS NOT DISTINCT FROM p_created_by END
     ORDER BY m.created_at,m.member_id LIMIT 1)
  END,
  shared_expenses._context_label(p_kind,p_name,p_created_by,p_viewer))
$$;
ALTER FUNCTION shared_expenses._context_label(text,text,uuid,uuid,uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._context_label(text,text,uuid,uuid,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses._context_label(text,text,uuid,uuid,uuid) TO app_user;


-- Audience for the join/accepted pushes. claimantName = typed name, else live
-- profile name, else null. claimantProfileName and claimantPhoneSuffix are for
-- the owner's join card only; the notifier must never put them in a push.
CREATE OR REPLACE FUNCTION shared_expenses.invitation_audience(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token_hash;
 IF NOT FOUND OR i.claimed_profile_id IS DISTINCT FROM a THEN
  RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';
 END IF;
 RETURN jsonb_build_object(
  'contextId',i.context_id,
  'contextName',(SELECT c.name FROM shared_expenses.contexts c WHERE c.context_id=i.context_id AND c.kind='group'),
  'claimantName',coalesce(
    (SELECT NULLIF(btrim(m.display_name),'') FROM shared_expenses.members m WHERE m.context_id=i.context_id AND m.member_id=i.member_id),
    (SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id)),
  'claimantProfileName',(SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id),
  'claimantPhoneSuffix',i.verified_phone_suffix,
  'owners',(SELECT coalesce(jsonb_agg(m.profile_id ORDER BY m.member_id),'[]'::jsonb) FROM shared_expenses.members m
            WHERE m.context_id=i.context_id AND m.role='owner' AND m.state='active' AND m.profile_id IS NOT NULL AND m.profile_id<>a));
END $$;
ALTER FUNCTION shared_expenses.invitation_audience(text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.invitation_audience(text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.invitation_audience(text) TO app_user;

-- Link-join requests waiting for the signed-in owner. Existing keys unchanged;
-- claimantName is now the LIVE profile name. memberName stays the typed label.
CREATE OR REPLACE FUNCTION shared_expenses.list_join_requests() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'contextId',q.context_id,'contextKind',q.kind,
  'contextName',q.name,'memberName',q.display_name,'verifiedPhoneSuffix',q.verified_phone_suffix,'claimantName',q.claimant_name,
  'claimantProfileName',q.claimant_name,'claimantPhoneSuffix',q.verified_phone_suffix,'createdAt',q.created_at) ORDER BY q.created_at DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.invitation_id,i.context_id,c.kind,shared_expenses._context_label(c.kind,c.name,c.created_by,a,c.context_id) AS name,m.display_name,i.verified_phone_suffix,(SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id) AS claimant_name,i.created_at
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

-- Owner's invitation list: unchanged except claimantName is now the LIVE profile name.
CREATE OR REPLACE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',q.display_name,
  'status',CASE WHEN q.declined_at IS NOT NULL THEN 'declined' WHEN q.state IN ('open','awaiting_owner') AND q.expires_at<=clock_timestamp() THEN 'expired' ELSE q.state END,
  'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,'claimantName',(SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=q.claimed_profile_id),'expiresAt',q.expires_at,'createdAt',q.created_at) ORDER BY q.created_at DESC,q.invitation_id DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR i.invitation_id>p_after) ORDER BY i.created_at DESC,i.invitation_id DESC LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;
ALTER FUNCTION shared_expenses.list_invitations(uuid,uuid) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.list_invitations(uuid,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.list_invitations(uuid,uuid) TO app_user;

-- member.rename: set the label other people see for a member. The context owner
-- may rename any active or invited member; anyone may rename their own row.
-- Text is trimmed, control characters stripped, whitespace collapsed, capped at 40.
CREATE FUNCTION shared_expenses.rename_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; mid uuid; n text; r jsonb; t shared_expenses.members; is_owner boolean; seq bigint; required text[]:=ARRAY['contextId','memberId','displayName'];
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required))
  OR octet_length(p_payload::text)>2048 OR jsonb_typeof(p_payload->'displayName')<>'string' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; mid:=(p_payload->>'memberId')::uuid;
 n:=btrim(left(btrim(regexp_replace(regexp_replace(p_payload->>'displayName','[\x01-\x1f\x7f-\x9f]+',' ','g'),'\s+',' ','g')),40));
 IF ctx IS NULL OR mid IS NULL OR n IS NULL OR n='' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'member.rename',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO t FROM shared_expenses.members WHERE context_id=ctx AND member_id=mid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'member_not_found' USING ERRCODE='22023'; END IF;
 is_owner:=EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active');
 IF NOT is_owner AND t.profile_id IS DISTINCT FROM a THEN RAISE EXCEPTION 'member_rename_not_authorized' USING ERRCODE='42501'; END IF;
 -- Declined, left, erased and former (account deleted) people keep their history label.
 IF NOT (t.state='invited' AND is_owner) AND NOT (t.state='active' AND t.profile_id IS NOT NULL) THEN RAISE EXCEPTION 'member_not_renamable' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.members SET display_name=n WHERE context_id=ctx AND member_id=mid;
 seq:=shared_expenses._emit(ctx,'member.renamed',mid,jsonb_build_object('memberId',mid));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','renamed','memberId',mid,'displayName',n,'sequence',seq::text));
END $$;
ALTER FUNCTION shared_expenses.rename_member(jsonb,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.rename_member(jsonb,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.rename_member(jsonb,uuid,text) TO app_user;

-- Invitation preview shows the same live counterpart label.
CREATE OR REPLACE FUNCTION shared_expenses.preview_invitation(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; gl shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._actor();PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN
  SELECT g.* INTO gl FROM shared_expenses.group_links g JOIN shared_expenses.contexts c ON c.context_id=g.context_id AND c.state='active' AND c.kind='group'
  WHERE g.token_hash=p_token AND g.expires_at>clock_timestamp();
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
  RETURN jsonb_build_object('kind','group_link','contextId',gl.context_id,'memberName','You','phoneBound',false,'status','open','expiresAt',gl.expires_at,
   'contextName',(SELECT name FROM shared_expenses.contexts WHERE context_id=gl.context_id));
 END IF;
 IF i.state='rejected' OR i.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active')
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('invitationId',i.invitation_id,'contextId',i.context_id,'memberId',i.member_id,
 'contextName',(SELECT shared_expenses._context_label(c2.kind,c2.name,c2.created_by,a,c2.context_id) FROM shared_expenses.contexts c2 WHERE c2.context_id=i.context_id),
 'memberName',(SELECT display_name FROM shared_expenses.members WHERE context_id=i.context_id AND member_id=i.member_id),
 'kind','invitation','phoneBound',i.target_phone_hash IS NOT NULL,'status',i.state,'expiresAt',i.expires_at);
END $$;
