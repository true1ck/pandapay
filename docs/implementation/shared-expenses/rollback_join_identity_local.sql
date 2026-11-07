-- LOCAL ONLY. Undoes db/supabase/migrations/20261116100000_shared_expense_join_identity.sql so a corrected
-- version of it can be applied again on a development database (no data of that migration survives: the
-- columns, the audit table and every stored phone ciphertext are dropped).
-- Never run on a database where the migration has shipped.
--
-- Apply:   psql "$LOCAL_DB_URL" -v ON_ERROR_STOP=1 -1 -f docs/implementation/shared-expenses/rollback_join_identity_local.sql
-- Then re-apply the migration file with psql -v ON_ERROR_STOP=1 -1 -f db/supabase/migrations/20261116100000_shared_expense_join_identity.sql
-- (The definitions restored below are the last ones from the earlier migrations; the migration test checks the schema is identical afterwards.)

DROP TRIGGER IF EXISTS shared_scrub_profile_phone ON public.profiles;
DROP TRIGGER IF EXISTS shared_invitations_purge_phone ON shared_expenses.invitations;
DO $$ BEGIN
 IF EXISTS(SELECT FROM pg_extension WHERE extname='pg_cron') THEN
  EXECUTE $c$SELECT cron.unschedule('purge-claimant-phones')$c$;
 END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron job not removed: %',SQLERRM;
END $$;

-- The new claim signatures go first; the previous ones are recreated below.
DROP FUNCTION IF EXISTS shared_expenses.claim_invitation(text,text,text,uuid,text,text);
DROP FUNCTION IF EXISTS shared_expenses._claim_group_link(text,text,uuid,text,text);

-- restored from 20261116090000_shared_expense_member_labels.sql
CREATE OR REPLACE FUNCTION shared_expenses._clean_label(p text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT btrim(left(btrim(regexp_replace(regexp_replace(p,'[\x01-\x1f\x7f-\x9f\u2028\u2029]+',' ','g'),'\s+',' ','g')),40))
$$;

-- restored from 20261116090000_shared_expense_member_labels.sql
CREATE OR REPLACE FUNCTION shared_expenses._member_label(p_name text,p_profile uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN NULLIF(btrim(p_name),'') IS NOT NULL THEN btrim(p_name)
  WHEN p_profile IS NULL THEN 'Former member'
  ELSE (SELECT NULLIF(btrim(p.display_name),'') FROM public.profiles p WHERE p.id=p_profile) END
$$;

-- restored from 20261116090000_shared_expense_member_labels.sql
CREATE OR REPLACE FUNCTION shared_expenses._context_label(p_kind text,p_name text,p_created_by uuid,p_viewer uuid,p_context uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
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

-- restored from 20261114020000_shared_expense_group_links.sql
CREATE OR REPLACE FUNCTION shared_expenses.revoke_group_link(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.revoke',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',false));
END $$;

-- restored from 20261112210000_shared_expenses_foundation.sql
CREATE OR REPLACE FUNCTION shared_expenses.create_context(p_context_id uuid,p_kind text,p_name text,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; mid uuid; seq bigint; BEGIN
  PERFORM shared_expenses._require_proposals();
  IF p_context_id IS NULL OR p_kind NOT IN ('group','direct') OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_context' USING ERRCODE='22023'; END IF;
  r:=shared_expenses._operation(p_operation_id,p_request_hash,'context.create',jsonb_build_object('contextId',p_context_id,'contextKind',p_kind,'name',p_name),p_context_id);
  IF r IS NOT NULL THEN
    IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context_id AND profile_id=a AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
    RETURN r;
  END IF;
  INSERT INTO shared_expenses.contexts(context_id,kind,name,created_by) VALUES(p_context_id,p_kind,btrim(p_name),a);
  mid:=gen_random_uuid();
  INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state) VALUES(p_context_id,mid,a,'owner','active');
  seq:=shared_expenses._emit(p_context_id,'context.created',p_context_id,jsonb_build_object('contextId',p_context_id));
  RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','created','contextId',p_context_id,'memberId',mid,'sequence',seq::text));
END $$;

-- restored from 20261112210000_shared_expenses_foundation.sql
CREATE OR REPLACE FUNCTION shared_expenses.invite_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; mid uuid; target uuid; r jsonb; context_kind text; seq bigint; required text[]:=ARRAY['contextId','memberId','displayName'];
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required||ARRAY['profileId'])) OR octet_length(p_payload::text)>2048 OR jsonb_typeof(p_payload->'displayName')<>'string' OR length(btrim(p_payload->>'displayName')) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; mid:=(p_payload->>'memberId')::uuid; target:=(p_payload->>'profileId')::uuid;
 IF ctx IS NULL OR mid IS NULL OR (p_payload ? 'profileId' AND target IS NULL) THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'member.invite',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT kind INTO context_kind FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx)>=(CASE WHEN context_kind='direct' THEN 2 ELSE 200 END) THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023'; END IF;
 BEGIN
   INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) VALUES(ctx,mid,target,'member','invited',btrim(p_payload->>'displayName'));
 EXCEPTION WHEN foreign_key_violation OR unique_violation THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505';
 END;
 seq:=shared_expenses._emit(ctx,'member.invited',mid,jsonb_build_object('memberId',mid,'status','invited'));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','invited','memberId',mid,'sequence',seq::text));
END $$;

-- restored from 20261116090000_shared_expense_member_labels.sql
CREATE OR REPLACE FUNCTION shared_expenses.rename_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; mid uuid; n text; r jsonb; t shared_expenses.members; is_owner boolean; seq bigint; required text[]:=ARRAY['contextId','memberId','displayName'];
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required))
  OR octet_length(p_payload::text)>2048 OR jsonb_typeof(p_payload->'displayName')<>'string' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; mid:=(p_payload->>'memberId')::uuid;
 n:=shared_expenses._clean_label(p_payload->>'displayName');
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

-- restored from 20261116090000_shared_expense_member_labels.sql
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

-- restored from 20261116090000_shared_expense_member_labels.sql
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

-- restored from 20261116090000_shared_expense_member_labels.sql
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

-- restored from 20261116090000_shared_expense_member_labels.sql
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

-- restored from 20261114020000_shared_expense_group_links.sql
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

-- restored from 20261114020000_shared_expense_group_links.sql
CREATE OR REPLACE FUNCTION shared_expenses._claim_group_link(p_token text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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

ALTER FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._claim_group_link(text,text,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text),shared_expenses._claim_group_link(text,text,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text) TO app_user;

-- Everything the migration added.
DROP FUNCTION IF EXISTS shared_expenses.attach_claimant_phone(uuid,uuid,text,text,text,bytea,text,text);
DROP FUNCTION IF EXISTS shared_expenses.reveal_claimant_phone(uuid);
DROP FUNCTION IF EXISTS shared_expenses.check_claimant_phone(uuid,text);
DROP FUNCTION IF EXISTS shared_expenses.list_join_requests_enc(uuid[]);
DROP FUNCTION IF EXISTS shared_expenses._reveal_budget_left(uuid);
DROP FUNCTION IF EXISTS shared_expenses._claimant_phone_json(shared_expenses.invitations,uuid);
DROP FUNCTION IF EXISTS shared_expenses._is_lookalike(shared_expenses.invitations,uuid);
DROP FUNCTION IF EXISTS shared_expenses._apply_claim_consent(uuid,text,text,uuid);
DROP FUNCTION IF EXISTS shared_expenses.purge_expired_claimant_phones();
DROP FUNCTION IF EXISTS shared_expenses._purge_lazy(uuid,uuid);
DROP FUNCTION IF EXISTS shared_expenses._purge_phones(uuid,uuid,integer);
DROP FUNCTION IF EXISTS shared_expenses._scrub_profile_phone();
DROP FUNCTION IF EXISTS shared_expenses._invitations_purge_phone();
DROP FUNCTION IF EXISTS shared_expenses._friend_context(uuid,uuid,text);
DROP FUNCTION IF EXISTS shared_expenses._label_taken(uuid,uuid,text);
DROP FUNCTION IF EXISTS shared_expenses._assert_member_label(text);
DROP FUNCTION IF EXISTS shared_expenses._label_reserved(text);
DROP FUNCTION IF EXISTS shared_expenses._label_key(text);
DROP FUNCTION IF EXISTS shared_expenses._clean_text(text,integer);
DROP TABLE IF EXISTS shared_expenses.phone_reveals;
DROP INDEX IF EXISTS shared_expenses.shared_invitations_phone_purge;
DROP INDEX IF EXISTS shared_expenses.shared_invitations_claimed_profile;
ALTER TABLE shared_expenses.invitations
 DROP COLUMN IF EXISTS claimant_phone_enc,DROP COLUMN IF EXISTS claimant_phone_key_id,DROP COLUMN IF EXISTS claimant_phone_cc,
 DROP COLUMN IF EXISTS claimant_phone_hash,DROP COLUMN IF EXISTS claimant_phone_mask,DROP COLUMN IF EXISTS phone_share,
 DROP COLUMN IF EXISTS phone_captured_at,DROP COLUMN IF EXISTS phone_purged_at,DROP COLUMN IF EXISTS phone_check_attempts,
 DROP COLUMN IF EXISTS last_claim_op;
