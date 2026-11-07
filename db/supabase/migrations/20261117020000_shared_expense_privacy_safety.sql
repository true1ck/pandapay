CREATE OR REPLACE FUNCTION shared_expenses._claim_group_link(p_token text,p_suffix text,p_operation uuid,p_hash text,p_share text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); g shared_expenses.group_links; r jsonb; m shared_expenses.members; p shared_expenses.invitations; inv uuid; mid uuid; nm text; cand text; n int:=1; BEGIN
 SELECT * INTO g FROM shared_expenses.group_links WHERE token_hash=p_token AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),g.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=g.context_id AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 -- A revoke or replacement could have committed while we waited.
 PERFORM 1 FROM shared_expenses.group_links
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
 IF (SELECT count(*) FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.state='awaiting_owner' AND i.expires_at>clock_timestamp())>=20 THEN RAISE EXCEPTION 'join_requests_full' USING ERRCODE='55000';END IF;
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
 PERFORM shared_expenses._emit(g.context_id,'membership.requested',mid,jsonb_build_object('memberId',mid,'status','awaiting_owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'invitationId',inv,'status','awaiting_owner'))||jsonb_build_object('fresh',true);
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.revoke_group_link(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.revoke',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 UPDATE shared_expenses.invitations SET claimant_phone_enc=NULL,claimant_phone_key_id=NULL,claimant_phone_mask=NULL,phone_purged_at=clock_timestamp()
  WHERE context_id=p_context AND via_group_link AND claimant_phone_enc IS NOT NULL;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',false));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.reveal_claimant_phone(p_invitation uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext('reveal:'||a::text));
 PERFORM shared_expenses._purge_lazy(a,p_invitation);
 -- Bulk reads may hold a purge row while waiting for this budget. A busy
 -- target is temporarily unavailable rather than a reason to form a lock cycle.
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation FOR UPDATE SKIP LOCKED;
 IF NOT FOUND THEN RETURN jsonb_build_object('error','phone_not_available'); END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.phone_directory WHERE profile_id=a) THEN RETURN jsonb_build_object('error','owner_phone_required'); END IF;
 IF i.state<>'awaiting_owner' OR i.expires_at<=clock_timestamp() OR i.phone_share<>'shared' OR i.claimant_phone_enc IS NULL THEN RETURN jsonb_build_object('error','phone_not_available'); END IF;
 IF NOT shared_expenses._reveal_budget_left(a) THEN RETURN jsonb_build_object('error','reveal_rate_limited'); END IF;
 -- The API decrypts inside this same transaction and rolls it back (audit row included) if it cannot.
 INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) VALUES(p_invitation,a,'tap');
 RETURN jsonb_build_object('invitationId',i.invitation_id,'enc',encode(i.claimant_phone_enc,'hex'),'keyId',i.claimant_phone_key_id);
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.list_join_requests_enc(p_ids uuid[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); res jsonb:='[]'::jsonb; i shared_expenses.invitations; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_ids IS NULL OR cardinality(p_ids)>20 THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;

 IF NOT EXISTS(SELECT FROM shared_expenses.phone_directory WHERE profile_id=a) THEN RETURN res; END IF;
 -- Bulk display is invoked after a lazy purge in the same transaction. Lock
 -- candidate rows without waiting while holding the owner's reveal budget.
 PERFORM pg_advisory_xact_lock(hashtext('reveal:'||a::text));
 FOR i IN SELECT * FROM shared_expenses.invitations x
   WHERE x.invitation_id=ANY(p_ids) AND x.state='awaiting_owner' AND x.expires_at>clock_timestamp() AND x.phone_share='shared' AND x.claimant_phone_enc IS NOT NULL
   AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=x.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
   ORDER BY x.created_at,x.invitation_id FOR UPDATE SKIP LOCKED LOOP
  CONTINUE WHEN NOT shared_expenses._is_lookalike(i,a);
  IF NOT EXISTS(SELECT FROM shared_expenses.phone_reveals r WHERE r.invitation_id=i.invitation_id AND r.owner_profile_id=a AND r.via='lookalike' AND r.at>clock_timestamp()-interval '1 hour') THEN
   CONTINUE WHEN NOT shared_expenses._reveal_budget_left(a);
   INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) VALUES(i.invitation_id,a,'lookalike');
  END IF;
  res:=res||jsonb_build_array(jsonb_build_object('invitationId',i.invitation_id,'enc',encode(i.claimant_phone_enc,'hex'),'keyId',i.claimant_phone_key_id));
 END LOOP;
 RETURN res;
END $$;

-- Profile erasure retains the ledger and member IDs for counterparties.
-- Private source data and the deleted issuer's admission credentials do not survive.
CREATE OR REPLACE FUNCTION shared_expenses._scrub_profile_phone() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
BEGIN
 UPDATE shared_expenses.members m SET state='declined'
 FROM shared_expenses.invitations i
 WHERE i.claimed_profile_id=OLD.id AND i.state='awaiting_owner' AND i.via_group_link
   AND m.context_id=i.context_id AND m.member_id=i.member_id
   AND m.profile_id IS NULL AND m.state='invited';

 UPDATE shared_expenses.invitations
 SET state=CASE WHEN state IN ('open','awaiting_owner') THEN 'rejected' ELSE state END,
     target_phone_hash=CASE WHEN issuer_profile_id=OLD.id THEN NULL ELSE target_phone_hash END,
     claimed_profile_id=NULL,verified_phone_suffix=NULL,claimant_phone_enc=NULL,
     claimant_phone_key_id=NULL,claimant_phone_cc=NULL,claimant_phone_hash=NULL,
     claimant_phone_mask=NULL,phone_share='none',phone_purged_at=clock_timestamp()
 WHERE claimed_profile_id=OLD.id OR (issuer_profile_id=OLD.id AND state IN ('open','awaiting_owner'));

 DELETE FROM shared_expenses.group_links WHERE created_by=OLD.id;
 UPDATE shared_expenses.phone_reveals SET owner_profile_id=NULL WHERE owner_profile_id=OLD.id;
 UPDATE shared_expenses.members SET display_name=NULL WHERE profile_id=OLD.id;
 DELETE FROM shared_expenses.settlement_private_references WHERE owner_profile_id=OLD.id;
 DELETE FROM shared_expenses.private_cost_facts WHERE profile_id=OLD.id;

 DELETE FROM shared_expenses.source_reservations sr USING shared_expenses.source_resources s
 WHERE sr.resource_id=s.resource_id AND s.owner_profile_id=OLD.id;
 DELETE FROM shared_expenses.source_aliases WHERE owner_profile_id=OLD.id;
 DELETE FROM shared_expenses.source_resources WHERE owner_profile_id=OLD.id;
 RETURN OLD;
END $$;


CREATE OR REPLACE FUNCTION shared_expenses.claim_invitation(p_token text,p_phone text,p_suffix text,p_operation uuid,p_hash text,p_share text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor();i shared_expenses.invitations;r jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN RETURN shared_expenses._claim_group_link(p_token,p_suffix,p_operation,p_hash,p_share);END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),i.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 PERFORM shared_expenses._purge_lazy(NULL,i.invitation_id);
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=i.invitation_id FOR UPDATE;
 IF i.expires_at<=clock_timestamp() OR i.state='rejected' OR i.issuer_profile_id=a
 OR (i.claimed_profile_id IS NOT NULL AND i.claimed_profile_id<>a)
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 IF i.target_phone_hash IS NOT NULL AND i.target_phone_hash IS DISTINCT FROM p_phone
 THEN RAISE EXCEPTION 'invitation_phone_mismatch' USING ERRCODE='42501';END IF;
 IF i.state='open' THEN
  UPDATE shared_expenses.invitations SET claimed_profile_id=a,state='awaiting_owner',expires_at=clock_timestamp()+interval '7 days' WHERE invitation_id=i.invitation_id;
  PERFORM shared_expenses._apply_claim_consent(i.invitation_id,p_suffix,p_share,p_operation);
  -- A verified number establishes current possession, not the invitee's identity.
  i.state:='awaiting_owner';
  PERFORM shared_expenses._emit(i.context_id,'membership.requested',i.member_id,
    jsonb_build_object('memberId',i.member_id,'status','awaiting_owner'));
 ELSIF i.state='awaiting_owner' AND i.claimed_profile_id=a THEN
  -- Still pending: a repeated claim re-applies consent and refreshes the suffix.
  PERFORM shared_expenses._apply_claim_consent(i.invitation_id,p_suffix,p_share,p_operation);
 END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'invitationId',i.invitation_id,'status',i.state))
  ||CASE WHEN i.state='awaiting_owner' THEN jsonb_build_object('fresh',true) ELSE '{}'::jsonb END;
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.claim_invitation_by_id(p_id uuid,p_phone text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_id;
 IF NOT FOUND OR i.target_phone_hash IS NULL OR p_phone IS NULL OR i.target_phone_hash IS DISTINCT FROM p_phone
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim_by_id',jsonb_build_object('invitationId',p_id,'accept',true),i.context_id);
 IF r IS NOT NULL THEN
  SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id;
  RETURN r||CASE WHEN r->>'status'='awaiting_owner' AND i.claimed_profile_id=a AND i.state='awaiting_owner'
    THEN jsonb_build_object('audienceKey',i.token_hash) ELSE '{}'::jsonb END;
 END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id FOR UPDATE;
 IF i.target_phone_hash IS DISTINCT FROM p_phone OR i.expires_at<=clock_timestamp()
   OR i.issuer_profile_id=a OR (i.claimed_profile_id IS NOT NULL AND i.claimed_profile_id<>a)
   OR i.state NOT IN ('open','awaiting_owner','joined') THEN
  RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';
 END IF;
 IF i.state='open' THEN
  UPDATE shared_expenses.invitations SET claimed_profile_id=a,state='awaiting_owner',
    expires_at=clock_timestamp()+interval '7 days'
  WHERE invitation_id=p_id;
  PERFORM shared_expenses._apply_claim_consent(p_id,p_suffix,NULL,p_operation);
  PERFORM shared_expenses._emit(i.context_id,'membership.requested',i.member_id,
    jsonb_build_object('memberId',i.member_id,'status','awaiting_owner'));
  i.state:='awaiting_owner';
  RETURN shared_expenses._finish(p_operation,jsonb_build_object(
    'contextId',i.context_id,'memberId',i.member_id,'status',i.state))
    ||jsonb_build_object('audienceKey',i.token_hash);
 END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object(
   'contextId',i.context_id,'memberId',i.member_id,'status',i.state));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.list_my_invitations(p_hash text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RETURN jsonb_build_object('items','[]'::jsonb); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'contextId',q.context_id,'contextKind',q.kind,
  'contextName',q.name,'inviterName',q.inviter_name,'expiresAt',q.expires_at,'createdAt',q.created_at) ORDER BY q.created_at DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.invitation_id,i.context_id,c.kind,CASE WHEN c.kind='group' THEN 'Group split' ELSE 'Direct split' END AS name,
   (SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=i.issuer_profile_id) AS inviter_name,i.expires_at,i.created_at
  FROM shared_expenses.invitations i
  JOIN shared_expenses.contexts c ON c.context_id=i.context_id AND c.state='active'
  JOIN shared_expenses.members m ON m.context_id=i.context_id AND m.member_id=i.member_id AND m.state='invited' AND m.profile_id IS NULL
  WHERE i.target_phone_hash=p_hash AND i.state='open' AND i.expires_at>clock_timestamp() AND i.issuer_profile_id<>a
  AND NOT EXISTS(SELECT FROM shared_expenses.members x WHERE x.context_id=i.context_id AND x.profile_id=a)
  ORDER BY i.created_at DESC LIMIT 20) q;
 RETURN jsonb_build_object('items',rows);
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

CREATE OR REPLACE FUNCTION shared_expenses.invitation_audience(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token_hash;
 IF NOT FOUND THEN
  -- A group link has no invitation of its own: the claim made one for the caller, so resolve the link
  -- token to the CALLER's own request (never anyone else's).
  SELECT x.* INTO i FROM shared_expenses.group_links g JOIN shared_expenses.invitations x ON x.context_id=g.context_id AND x.claimed_profile_id=a AND x.via_group_link
   WHERE g.token_hash=p_token_hash ORDER BY x.created_at DESC LIMIT 1;
 END IF;
 IF NOT FOUND OR i.claimed_profile_id IS DISTINCT FROM a THEN
  RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';
 END IF;
 RETURN jsonb_build_object(
  'contextId',i.context_id,
  'contextName',(SELECT NULLIF(shared_expenses._clean_text(c.name,120),'') FROM shared_expenses.contexts c WHERE c.context_id=i.context_id AND c.kind='group'),
  'claimantName',(SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id),
  'claimantProfileName',(SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id),
  'claimantPhoneSuffix',i.verified_phone_suffix,
  'owners',(SELECT coalesce(jsonb_agg(m.profile_id ORDER BY m.member_id),'[]'::jsonb) FROM shared_expenses.members m
            WHERE m.context_id=i.context_id AND m.role='owner' AND m.state='active' AND m.profile_id IS NOT NULL AND m.profile_id<>a));
END $$;
