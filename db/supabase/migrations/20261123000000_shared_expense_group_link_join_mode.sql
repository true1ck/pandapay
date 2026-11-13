-- Group link join mode. A link used to ALWAYS create a request that the owner
-- approves. The owner now chooses when the link is made:
--   auto_join = true  : anyone who opens the link joins at once (the app's default);
--   auto_join = false : the old behaviour, the owner approves each person.
-- Links that already exist keep approval (column default false), and a client
-- that never calls set_group_link_mode also keeps approval, so nothing becomes
-- open by accident. Joining still never accepts any expense or debt.
ALTER TABLE shared_expenses.group_links ADD COLUMN auto_join boolean NOT NULL DEFAULT false;

-- Owner only. Applies to the link that exists now (or, when p_token_hash is
-- given, only if that exact link is still the current one, so a replayed create
-- cannot change a newer link). Does not admit the people already waiting.
CREATE FUNCTION shared_expenses.set_group_link_mode(p_context uuid,p_auto_join boolean,p_token_hash text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); g shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_context IS NULL OR p_auto_join IS NULL THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 UPDATE shared_expenses.group_links SET auto_join=p_auto_join WHERE context_id=p_context AND expires_at>clock_timestamp() AND (p_token_hash IS NULL OR token_hash=p_token_hash) RETURNING * INTO g;
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('contextId',p_context,'active',true,'autoJoin',g.auto_join,'expiresAt',g.expires_at);
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.group_link_status(p_context uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE g shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO g FROM shared_expenses.group_links WHERE context_id=p_context;
 RETURN jsonb_build_object('active',FOUND AND g.expires_at>clock_timestamp(),'expiresAt',g.expires_at,'expired',FOUND AND g.expires_at<=clock_timestamp(),'autoJoin',FOUND AND g.auto_join);
END $$;

-- Same function as before (privacy_safety) with one new rule: on an auto-join
-- link the claimant becomes an active member in the same call, through the same
-- binding the owner's approval uses, so every membership invariant still holds.
CREATE OR REPLACE FUNCTION shared_expenses._claim_group_link(p_token text,p_suffix text,p_operation uuid,p_hash text,p_share text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); g shared_expenses.group_links; r jsonb; m shared_expenses.members; p shared_expenses.invitations; inv uuid; mid uuid; nm text; cand text; n int:=1; BEGIN
 SELECT * INTO g FROM shared_expenses.group_links WHERE token_hash=p_token AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),g.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=g.context_id AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 -- A revoke or replacement could have committed while we waited.
 SELECT * INTO g FROM shared_expenses.group_links
 WHERE context_id=g.context_id AND token_hash=p_token AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtext(g.context_id::text));
 -- A claimant can otherwise race the hourly cap across different contexts.
 PERFORM pg_advisory_xact_lock(hashtextextended('shared-link-claimant:'||a::text,0));
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=g.context_id AND profile_id=a;
 IF FOUND THEN
  IF m.state='active' THEN RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',m.member_id,'status','joined'));END IF;
  RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505';
 END IF;
 SELECT * INTO p FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.claimed_profile_id=a AND i.via_group_link AND i.state='awaiting_owner' ORDER BY i.created_at DESC LIMIT 1 FOR UPDATE;
 IF FOUND THEN
  IF g.auto_join THEN
   -- They asked while the link needed approval; the owner has since opened it.
   PERFORM shared_expenses._bind_invitation(p.invitation_id,a);
   RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',p.member_id,'invitationId',p.invitation_id,'status','joined'))||jsonb_build_object('fresh',true);
  END IF;
  IF p.expires_at<=clock_timestamp() THEN
   -- A request that expired comes back to life only if every cap still allows it.
   IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.claimed_profile_id=a AND i.via_group_link AND i.created_at>clock_timestamp()-interval '1 hour')>=10 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000';END IF;
   IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.state='awaiting_owner' AND i.expires_at>clock_timestamp())>=20 THEN RAISE EXCEPTION 'join_requests_full' USING ERRCODE='55000';END IF;
   IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=g.context_id AND state<>'declined')>200 THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023';END IF;
   UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()+interval '7 days' WHERE invitation_id=p.invitation_id;
   PERFORM shared_expenses._emit(g.context_id,'membership.requested',p.member_id,jsonb_build_object('memberId',p.member_id,'status','awaiting_owner'));
  END IF;
  PERFORM shared_expenses._apply_claim_consent(p.invitation_id,p_suffix,p_share,p_operation);
  RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',p.member_id,'invitationId',p.invitation_id,'status','awaiting_owner'))||jsonb_build_object('fresh',true);
 END IF;
 IF EXISTS(SELECT FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.claimed_profile_id=a AND i.via_group_link AND i.state='rejected' AND i.created_at>clock_timestamp()-interval '7 days')
 THEN RAISE EXCEPTION 'join_declined_recently' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.claimed_profile_id=a AND i.via_group_link AND i.created_at>clock_timestamp()-interval '1 hour')>=10 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000';END IF;
 IF NOT g.auto_join AND (SELECT count(*) FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.state='awaiting_owner' AND i.expires_at>clock_timestamp())>=20 THEN RAISE EXCEPTION 'join_requests_full' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=g.context_id AND state<>'declined')>=200 THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023';END IF;
 -- Placeholder label from the LIVE profile name, cleaned; a number suffix keeps labels unique.
 SELECT NULLIF(shared_expenses._clean_label(pr.display_name),'') INTO nm FROM (SELECT 1) x LEFT JOIN public.profiles pr ON pr.id=a;
 IF nm IS NULL OR shared_expenses._label_key(nm)='' OR shared_expenses._label_reserved(shared_expenses._label_key(nm)) THEN nm:='PandaPay user'; END IF;
 cand:=nm;
 WHILE shared_expenses._label_taken(g.context_id,NULL,cand) LOOP
  n:=n+1;
  IF n>60 THEN cand:=left(nm,28)||' ('||substr(replace(gen_random_uuid()::text,'-',''),1,8)||')'; EXIT; END IF;
  cand:=left(nm,40-length(' ('||n||')'))||' ('||n||')';
 END LOOP;
 mid:=gen_random_uuid();inv:=gen_random_uuid();
 INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) VALUES(g.context_id,mid,NULL,'member','invited',cand);
 INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,verified_phone_suffix,state,via_group_link,expires_at)
 VALUES(inv,g.context_id,mid,g.created_by,encode(sha256(convert_to('grouplink-request:'||inv::text,'UTF8')),'hex'),a,p_suffix,'awaiting_owner',true,clock_timestamp()+interval '7 days');
 PERFORM shared_expenses._apply_claim_consent(inv,p_suffix,p_share,p_operation);
 IF g.auto_join THEN
  -- Open link: no request for the owner to answer. Bind now, exactly as an
  -- owner's approval would (member active, invitation joined, event emitted).
  PERFORM shared_expenses._bind_invitation(inv,a);
  RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'invitationId',inv,'status','joined'))||jsonb_build_object('fresh',true);
 END IF;
 PERFORM shared_expenses._emit(g.context_id,'membership.requested',mid,jsonb_build_object('memberId',mid,'status','awaiting_owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'invitationId',inv,'status','awaiting_owner'))||jsonb_build_object('fresh',true);
END $$;

-- Same as before plus 'autoJoin' on the group-link branch, so the join screen
-- tells the truth ("you will join at once" vs "the owner will confirm").
CREATE OR REPLACE FUNCTION shared_expenses.preview_invitation(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; gl shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._actor();PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN
  SELECT g.* INTO gl FROM shared_expenses.group_links g JOIN shared_expenses.contexts c ON c.context_id=g.context_id AND c.state='active' AND c.kind='group'
  WHERE g.token_hash=p_token AND g.expires_at>clock_timestamp();
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
  RETURN jsonb_build_object('kind','group_link','contextId',gl.context_id,'memberName','You','phoneBound',false,'status','open','expiresAt',gl.expires_at,'autoJoin',gl.auto_join,
   'contextName',(SELECT NULLIF(shared_expenses._clean_text(name,120),'') FROM shared_expenses.contexts WHERE context_id=gl.context_id),
   'ownerName',(SELECT NULLIF(shared_expenses._member_label(m.display_name,m.profile_id),'Former member') FROM shared_expenses.members m WHERE m.context_id=gl.context_id AND m.profile_id=gl.created_by LIMIT 1));
 END IF;
 IF i.state='rejected' OR i.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active')
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('invitationId',i.invitation_id,'contextId',i.context_id,'memberId',i.member_id,
 'contextName',(SELECT CASE WHEN c2.kind='group' THEN 'Group split' ELSE 'Direct split' END FROM shared_expenses.contexts c2 WHERE c2.context_id=i.context_id),
 'memberName','You',
 'ownerName',(SELECT NULLIF(shared_expenses._member_label(m.display_name,m.profile_id),'Former member') FROM shared_expenses.members m WHERE m.context_id=i.context_id AND m.profile_id=i.issuer_profile_id LIMIT 1),
 'kind','invitation','phoneBound',i.target_phone_hash IS NOT NULL,'status',i.state,'expiresAt',i.expires_at);
END $$;

ALTER FUNCTION shared_expenses.set_group_link_mode(uuid,boolean,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.set_group_link_mode(uuid,boolean,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.set_group_link_mode(uuid,boolean,text) TO app_user;
