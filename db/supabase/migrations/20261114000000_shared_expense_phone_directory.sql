-- Phone directory and invitee inbox for shared expenses.
-- Only a keyed hash of a verified phone number is stored (the key lives in the
-- API environment, never in the database), never the number itself. A lookup
-- answers one picked number at a time, is rate limited, and treats an opted-out
-- person exactly like an unregistered one. Joining never accepts any expense.
CREATE TABLE shared_expenses.phone_directory (
 profile_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 phone_hash text NOT NULL CHECK(phone_hash~'^[a-f0-9]{64}$'),
 display_name text CHECK(display_name IS NULL OR length(display_name) BETWEEN 1 AND 255),
 discoverable boolean NOT NULL DEFAULT true,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX shared_phone_directory_hash ON shared_expenses.phone_directory(phone_hash);
CREATE TABLE shared_expenses.phone_lookups (
 lookup_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 looked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX shared_phone_lookups_rate ON shared_expenses.phone_lookups(profile_id,looked_at DESC);
ALTER TABLE shared_expenses.invitations ADD COLUMN declined_at timestamptz;
CREATE INDEX shared_invitations_inbox ON shared_expenses.invitations(target_phone_hash,created_at DESC) WHERE state='open' AND target_phone_hash IS NOT NULL;

ALTER TABLE shared_expenses.phone_directory OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.phone_lookups OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.phone_directory ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.phone_directory FORCE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.phone_lookups ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.phone_lookups FORCE ROW LEVEL SECURITY;
CREATE POLICY directory_owner ON shared_expenses.phone_directory FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
CREATE POLICY lookups_owner ON shared_expenses.phone_lookups FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
REVOKE ALL ON shared_expenses.phone_directory,shared_expenses.phone_lookups FROM PUBLIC,app_user;

-- Called by the API with the hash of the caller's own verified phone. The newest
-- verifier of a number owns its entry. discoverable NULL keeps the stored choice.
CREATE FUNCTION shared_expenses.register_phone(p_hash text,p_discoverable boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); n text; d boolean; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_phone' USING ERRCODE='22023'; END IF;
 SELECT NULLIF(btrim(display_name),'') INTO n FROM public.profiles WHERE id=a;
 DELETE FROM shared_expenses.phone_directory WHERE phone_hash=p_hash AND profile_id<>a;
 INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash,display_name,discoverable)
 VALUES(a,p_hash,left(n,255),coalesce(p_discoverable,true))
 ON CONFLICT(profile_id) DO UPDATE SET phone_hash=EXCLUDED.phone_hash,display_name=EXCLUDED.display_name,
  discoverable=coalesce(p_discoverable,shared_expenses.phone_directory.discoverable),updated_at=clock_timestamp()
 RETURNING discoverable INTO d;
 RETURN jsonb_build_object('registered',true,'discoverable',d);
END $$;

CREATE FUNCTION shared_expenses.directory_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); d boolean; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT discoverable INTO d FROM shared_expenses.phone_directory WHERE profile_id=a;
 RETURN jsonb_build_object('registered',FOUND,'discoverable',coalesce(d,true));
END $$;

-- One picked number. An opted-out or unregistered number is indistinguishable.
CREATE FUNCTION shared_expenses.lookup_phone(p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); e shared_expenses.phone_directory; ctx uuid; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_phone' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.phone_directory WHERE profile_id=a AND phone_hash=p_hash) THEN
  RETURN jsonb_build_object('found',false,'self',true);
 END IF;
 -- Serialize one person's lookups so concurrent requests cannot exceed the cap.
 PERFORM pg_advisory_xact_lock(hashtextextended('shared_lookup:'||a::text,0));
 DELETE FROM shared_expenses.phone_lookups WHERE profile_id=a AND looked_at<clock_timestamp()-interval '2 days';
 IF (SELECT count(*) FROM shared_expenses.phone_lookups WHERE profile_id=a AND looked_at>clock_timestamp()-interval '1 day')>=25
 THEN RAISE EXCEPTION 'lookup_rate_limited' USING ERRCODE='55000'; END IF;
 INSERT INTO shared_expenses.phone_lookups(profile_id) VALUES(a);
 SELECT * INTO e FROM shared_expenses.phone_directory WHERE phone_hash=p_hash AND discoverable AND profile_id<>a;
 IF NOT FOUND THEN RETURN jsonb_build_object('found',false,'self',false); END IF;
 SELECT c.context_id INTO ctx FROM shared_expenses.contexts c
 WHERE c.kind='direct' AND c.state='active'
 AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.profile_id=a AND m.state='active')
 AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.profile_id=e.profile_id AND m.state IN ('active','invited'))
 ORDER BY c.created_at LIMIT 1;
 RETURN jsonb_build_object('found',true,'self',false,'displayName',e.display_name,'existingContextId',ctx);
END $$;

-- Open invitations bound to the caller's verified phone. Expired, revoked,
-- declined and already-joined invitations never appear.
CREATE FUNCTION shared_expenses.list_my_invitations(p_hash text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RETURN jsonb_build_object('items','[]'::jsonb); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'contextId',q.context_id,'contextKind',q.kind,
  'contextName',q.name,'inviterName',q.inviter_name,'expiresAt',q.expires_at,'createdAt',q.created_at) ORDER BY q.created_at DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.invitation_id,i.context_id,c.kind,c.name,d.display_name AS inviter_name,i.expires_at,i.created_at
  FROM shared_expenses.invitations i
  JOIN shared_expenses.contexts c ON c.context_id=i.context_id AND c.state='active'
  JOIN shared_expenses.members m ON m.context_id=i.context_id AND m.member_id=i.member_id AND m.state='invited' AND m.profile_id IS NULL
  LEFT JOIN shared_expenses.phone_directory d ON d.profile_id=i.issuer_profile_id
  WHERE i.target_phone_hash=p_hash AND i.state='open' AND i.expires_at>clock_timestamp() AND i.issuer_profile_id<>a
  AND NOT EXISTS(SELECT FROM shared_expenses.members x WHERE x.context_id=i.context_id AND x.profile_id=a)
  ORDER BY i.created_at DESC LIMIT 20) q;
 RETURN jsonb_build_object('items',rows);
END $$;

CREATE FUNCTION shared_expenses.claim_invitation_by_id(p_id uuid,p_phone text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_id;
 IF NOT FOUND OR i.target_phone_hash IS NULL OR p_phone IS NULL OR i.target_phone_hash IS DISTINCT FROM p_phone
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim_by_id',jsonb_build_object('invitationId',p_id,'accept',true),i.context_id);
 IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id FOR UPDATE;
 IF i.state<>'open' OR i.expires_at<=clock_timestamp() OR i.issuer_profile_id=a
 OR (i.claimed_profile_id IS NOT NULL AND i.claimed_profile_id<>a) THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 UPDATE shared_expenses.invitations SET claimed_profile_id=a,verified_phone_suffix=p_suffix,state='awaiting_owner' WHERE invitation_id=p_id;
 PERFORM shared_expenses._bind_invitation(p_id,a);
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status','joined'));
END $$;

CREATE FUNCTION shared_expenses.decline_invitation(p_id uuid,p_phone text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_id;
 IF NOT FOUND OR i.target_phone_hash IS NULL OR p_phone IS NULL OR i.target_phone_hash IS DISTINCT FROM p_phone
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.decline',jsonb_build_object('invitationId',p_id,'accept',false),i.context_id);
 IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id FOR UPDATE;
 IF i.state<>'open' THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501'; END IF;
 UPDATE shared_expenses.invitations SET state='rejected',declined_at=clock_timestamp() WHERE invitation_id=p_id;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status','declined'));
END $$;

-- create_invitation, now refusing the cases that would create confusing or
-- abusive invitations: own number, same number twice in one context, a person
-- already in the context, and re-inviting someone who declined within a week.
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

-- list_invitations: owners can tell a decline from a revoked link and an expired one.
CREATE OR REPLACE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',q.display_name,
  'status',CASE WHEN q.declined_at IS NOT NULL THEN 'declined' WHEN q.state='open' AND q.expires_at<=clock_timestamp() THEN 'expired' ELSE q.state END,
  'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,'expiresAt',q.expires_at) ORDER BY q.invitation_id),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR i.invitation_id>p_after) ORDER BY i.invitation_id LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;

ALTER FUNCTION shared_expenses.register_phone(text,boolean) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.directory_status() OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.lookup_phone(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.list_my_invitations(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.claim_invitation_by_id(uuid,text,text,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.decline_invitation(uuid,text,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.register_phone(text,boolean),shared_expenses.directory_status(),shared_expenses.lookup_phone(text),shared_expenses.list_my_invitations(text),shared_expenses.claim_invitation_by_id(uuid,text,text,uuid,text),shared_expenses.decline_invitation(uuid,text,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.register_phone(text,boolean),shared_expenses.directory_status(),shared_expenses.lookup_phone(text),shared_expenses.list_my_invitations(text),shared_expenses.claim_invitation_by_id(uuid,text,text,uuid,text),shared_expenses.decline_invitation(uuid,text,uuid,text) TO app_user;
