-- Group invite link: one revocable link per group. Opening it only creates a
-- join REQUEST that the owner approves; it never adds anyone, accepts any
-- expense or posts money. Requests reuse the invitation approval flow.
CREATE TABLE shared_expenses.group_links (
 context_id uuid PRIMARY KEY REFERENCES shared_expenses.contexts(context_id),
 token_hash text NOT NULL UNIQUE CHECK(token_hash~'^[a-f0-9]{64}$'),
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '30 days'
);
ALTER TABLE shared_expenses.invitations ADD COLUMN via_group_link boolean NOT NULL DEFAULT false;
ALTER TABLE shared_expenses.group_links OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.group_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.group_links FORCE ROW LEVEL SECURITY;
CREATE POLICY group_links_owner ON shared_expenses.group_links FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
REVOKE ALL ON shared_expenses.group_links FROM PUBLIC,app_user;

CREATE FUNCTION shared_expenses.create_group_link(p_context uuid,p_token_hash text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; expiry timestamptz; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_token_hash IS NULL OR p_token_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.create',jsonb_build_object('contextId',p_context,'tokenHash',p_token_hash),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 -- Replacing the link invalidates the old one; requests already made stay valid.
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 INSERT INTO shared_expenses.group_links(context_id,token_hash,created_by) VALUES(p_context,p_token_hash,a) RETURNING expires_at INTO expiry;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',true,'expiresAt',expiry));
END $$;

CREATE FUNCTION shared_expenses.revoke_group_link(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.revoke',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',false));
END $$;

CREATE FUNCTION shared_expenses.group_link_status(p_context uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE g shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO g FROM shared_expenses.group_links WHERE context_id=p_context;
 RETURN jsonb_build_object('active',FOUND AND g.expires_at>clock_timestamp(),'expiresAt',g.expires_at,'expired',FOUND AND g.expires_at<=clock_timestamp());
END $$;

-- Someone opened the group link: create a pending request for the owner.
CREATE FUNCTION shared_expenses._claim_group_link(p_token text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); g shared_expenses.group_links; r jsonb; m shared_expenses.members; inv uuid; mid uuid; nm text; BEGIN
 SELECT * INTO g FROM shared_expenses.group_links WHERE token_hash=p_token AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),g.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=g.context_id AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=g.context_id AND profile_id=a;
 IF FOUND THEN
  IF m.state='active' THEN RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',m.member_id,'status','joined'));END IF;
  RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505';
 END IF;
 SELECT i.member_id INTO mid FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.claimed_profile_id=a AND i.via_group_link AND i.state='awaiting_owner' LIMIT 1;
 IF FOUND THEN RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'status','awaiting_owner'));END IF;
 IF EXISTS(SELECT FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.claimed_profile_id=a AND i.via_group_link AND i.state='rejected' AND i.created_at>clock_timestamp()-interval '7 days')
 THEN RAISE EXCEPTION 'join_declined_recently' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.claimed_profile_id=a AND i.via_group_link AND i.created_at>clock_timestamp()-interval '1 hour')>=10 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.state='awaiting_owner')>=20 THEN RAISE EXCEPTION 'join_requests_full' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=g.context_id AND state<>'declined')>=200 THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023';END IF;
 SELECT coalesce(NULLIF(btrim(d.display_name),''),'PandaPay user') INTO nm FROM (SELECT 1) x LEFT JOIN shared_expenses.phone_directory d ON d.profile_id=a;
 mid:=gen_random_uuid();inv:=gen_random_uuid();
 INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) VALUES(g.context_id,mid,NULL,'member','invited',left(nm,120));
 INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,verified_phone_suffix,state,via_group_link)
 VALUES(inv,g.context_id,mid,g.created_by,encode(sha256(convert_to('grouplink-request:'||inv::text,'UTF8')),'hex'),a,p_suffix,'awaiting_owner',true);
 PERFORM shared_expenses._emit(g.context_id,'membership.requested',mid,jsonb_build_object('memberId',mid,'status','awaiting_owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'status','awaiting_owner'));
END $$;

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
 'contextName',(SELECT shared_expenses._context_label(c2.kind,c2.name,c2.created_by,a) FROM shared_expenses.contexts c2 WHERE c2.context_id=i.context_id),
 'memberName',(SELECT display_name FROM shared_expenses.members WHERE context_id=i.context_id AND member_id=i.member_id),
 'kind','invitation','phoneBound',i.target_phone_hash IS NOT NULL,'status',i.state,'expiresAt',i.expires_at);
END $$;
CREATE OR REPLACE FUNCTION shared_expenses.claim_invitation(p_token text,p_phone text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor();i shared_expenses.invitations;r jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN RETURN shared_expenses._claim_group_link(p_token,p_suffix,p_operation,p_hash);END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),i.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=i.invitation_id FOR UPDATE;
 IF i.expires_at<=clock_timestamp() OR i.state='rejected' OR i.issuer_profile_id=a
 OR (i.claimed_profile_id IS NOT NULL AND i.claimed_profile_id<>a)
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 IF i.target_phone_hash IS NOT NULL AND i.target_phone_hash IS DISTINCT FROM p_phone
 THEN RAISE EXCEPTION 'invitation_phone_mismatch' USING ERRCODE='42501';END IF;
 IF i.state='open' THEN
  UPDATE shared_expenses.invitations SET claimed_profile_id=a,verified_phone_suffix=p_suffix,
  state='awaiting_owner' WHERE invitation_id=i.invitation_id;
  IF i.target_phone_hash IS NOT NULL THEN PERFORM shared_expenses._bind_invitation(i.invitation_id,a);i.state:='joined';
  ELSE i.state:='awaiting_owner'; PERFORM shared_expenses._emit(i.context_id,'membership.requested',i.member_id,jsonb_build_object('memberId',i.member_id,'status','awaiting_owner'));END IF;
 END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status',i.state));
END $$;
CREATE OR REPLACE FUNCTION shared_expenses.respond_invitation(p_id uuid,p_approve boolean,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor();i shared_expenses.invitations;r jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_id;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=i.context_id AND profile_id=a AND state='active' AND role='owner')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.respond',jsonb_build_object('invitationId',p_id,'approve',p_approve),i.context_id);IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id FOR UPDATE;
 IF i.state NOT IN ('open','awaiting_owner') OR i.expires_at<=clock_timestamp() OR p_approve IS NULL
 OR (p_approve AND i.claimed_profile_id IS NULL) THEN RAISE EXCEPTION 'invitation_conflict' USING ERRCODE='55000';END IF;
 IF p_approve THEN PERFORM shared_expenses._bind_invitation(p_id,i.claimed_profile_id);
 ELSE UPDATE shared_expenses.invitations SET state='rejected' WHERE invitation_id=p_id;
  IF i.via_group_link THEN UPDATE shared_expenses.members SET state='declined' WHERE context_id=i.context_id AND member_id=i.member_id AND profile_id IS NULL AND state='invited'; END IF;END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status',CASE WHEN p_approve THEN 'joined' ELSE 'rejected' END));
END $$;
ALTER FUNCTION shared_expenses.create_group_link(uuid,text,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.revoke_group_link(uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.group_link_status(uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._claim_group_link(text,text,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.create_group_link(uuid,text,uuid,text),shared_expenses.revoke_group_link(uuid,uuid,text),shared_expenses.group_link_status(uuid),shared_expenses._claim_group_link(text,text,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.create_group_link(uuid,text,uuid,text),shared_expenses.revoke_group_link(uuid,uuid,text),shared_expenses.group_link_status(uuid) TO app_user;
