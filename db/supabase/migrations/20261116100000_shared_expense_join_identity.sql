-- Join identity: consented phone for the owner, unique names, sanitised names.
-- Spec: docs/implementation/shared-expenses/join-identity-spec.md (sections 2-5).
--
-- Numbers: the API encrypts the claimant's number (AES-256-GCM, in Node). The
-- database only ever holds the ciphertext, a keyed hash, the country code, a
-- precomputed mask and the last four digits. Nothing here can decrypt.

-- ---------------------------------------------------------------- storage
ALTER TABLE shared_expenses.invitations
 ADD COLUMN claimant_phone_enc bytea,
 ADD COLUMN claimant_phone_key_id text,
 ADD COLUMN claimant_phone_cc text,
 ADD COLUMN claimant_phone_hash text,
 ADD COLUMN claimant_phone_mask text,
 ADD COLUMN phone_share text NOT NULL DEFAULT 'not_asked',
 ADD COLUMN phone_captured_at timestamptz,
 ADD COLUMN phone_purged_at timestamptz,
 ADD COLUMN phone_check_attempts smallint NOT NULL DEFAULT 0;
ALTER TABLE shared_expenses.invitations
 ADD CONSTRAINT invitations_phone_share_chk CHECK(phone_share IN ('shared','declined','none','not_asked')),
 ADD CONSTRAINT invitations_phone_hash_chk CHECK(claimant_phone_hash IS NULL OR claimant_phone_hash~'^[a-f0-9]{64}$'),
 ADD CONSTRAINT invitations_phone_cc_chk CHECK(claimant_phone_cc IS NULL OR claimant_phone_cc~'^(\+[0-9]{1,4})?$'),
 ADD CONSTRAINT invitations_phone_mask_chk CHECK(claimant_phone_mask IS NULL OR claimant_phone_mask~'^[+0-9• ]{1,32}$'),
 ADD CONSTRAINT invitations_phone_enc_chk CHECK(claimant_phone_enc IS NULL OR (claimant_phone_key_id IS NOT NULL AND octet_length(claimant_phone_enc) BETWEEN 29 AND 256)),
 ADD CONSTRAINT invitations_phone_enc_only_shared CHECK(claimant_phone_enc IS NULL OR phone_share='shared');
CREATE INDEX shared_invitations_phone_purge ON shared_expenses.invitations(expires_at) WHERE claimant_phone_enc IS NOT NULL;

CREATE TABLE shared_expenses.phone_reveals (
 reveal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 invitation_id uuid NOT NULL,
 owner_profile_id uuid NOT NULL,
 via text NOT NULL DEFAULT 'tap' CHECK(via IN ('tap','lookalike')),
 at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX shared_phone_reveals_owner ON shared_expenses.phone_reveals(owner_profile_id,at);
ALTER TABLE shared_expenses.phone_reveals OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.phone_reveals ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.phone_reveals FORCE ROW LEVEL SECURITY;
CREATE POLICY phone_reveals_owner ON shared_expenses.phone_reveals FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
REVOKE ALL ON shared_expenses.phone_reveals FROM PUBLIC,app_user;

-- ---------------------------------------------------------------- names
-- One cleaner for every shown or stored name: invisible/bidi/zero-width
-- characters are removed, control characters and exotic spaces become a space,
-- whitespace collapses, capped at 40 code points (left() counts characters).
CREATE OR REPLACE FUNCTION shared_expenses._clean_label(p text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT btrim(left(btrim(regexp_replace(regexp_replace(regexp_replace(p,
  '[\xad\x180e\x200b-\x200f\x202a-\x202e\x2060-\x2064\x2066-\x2069\xfeff]+','','g'),
  '[\x01-\x1f\x7f-\x9f\xa0\x1680\x2000-\x200a\x2028\x2029\x202f\x205f\x3000]+',' ','g'),
  '\s+',' ','g')),40))
$$;

-- Comparison key: NFKD, lower case, look-alike letters folded to Latin, accents,
-- punctuation, spaces and invisible characters removed. Mirrored in
-- api/src/shared_expenses/label.js; shared vectors in contracts/.../label_key_vectors.json.
CREATE FUNCTION shared_expenses._label_key(p text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT regexp_replace(regexp_replace(
  translate(lower(normalize(coalesce(p,''),NFKD)),
   'аеорсухктмнвіјАЕОРСУХКТМНВІЈοναρΟΝΑΡ',
   'aeopcyxktmhbijaeopcyxktmhbijovapovap'),
  '[\x300-\x36f\xad\x180e\x2000-\x206f\x3000-\x303f\xfe00-\xfe0f\xfeff]+','','g'),
  '[\x01-\x20\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\xa0]+','','g')
$$;

CREATE FUNCTION shared_expenses._label_reserved(p_key text) RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT p_key = ANY(ARRAY['you','me','myself','owner','admin','support','someone','pandapay','pandapayfriend','formermember','unknown','deleted'])
$$;

-- Empty-after-key names ("...", "!!") and reserved names are never allowed.
CREATE FUNCTION shared_expenses._assert_member_label(p_label text) RETURNS void LANGUAGE plpgsql
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE k text:=shared_expenses._label_key(p_label); BEGIN
 IF p_label IS NULL OR p_label='' OR k='' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 IF shared_expenses._label_reserved(k) THEN RAISE EXCEPTION 'member_name_reserved' USING ERRCODE='22023'; END IF;
END $$;

-- A label is taken when another active/invited member of the same split has the
-- same key, compared by what people actually see (typed name, else live profile name).
CREATE FUNCTION shared_expenses._label_taken(p_ctx uuid,p_self uuid,p_label text) RETURNS boolean LANGUAGE sql STABLE
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT EXISTS(SELECT FROM shared_expenses.members m
  WHERE m.context_id=p_ctx AND m.member_id IS DISTINCT FROM p_self AND m.state IN ('active','invited')
  AND shared_expenses._label_key(coalesce(NULLIF(btrim(m.display_name),''),(SELECT p.display_name FROM public.profiles p WHERE p.id=m.profile_id)))<>''
  AND shared_expenses._label_key(coalesce(NULLIF(btrim(m.display_name),''),(SELECT p.display_name FROM public.profiles p WHERE p.id=m.profile_id)))=shared_expenses._label_key(p_label))
$$;

-- Another ACTIVE direct split of this creator whose friend already has this name.
CREATE FUNCTION shared_expenses._friend_context(p_creator uuid,p_exclude uuid,p_label text) RETURNS uuid LANGUAGE sql STABLE
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT c.context_id FROM shared_expenses.contexts c
  WHERE c.kind='direct' AND c.state='active' AND c.created_by=p_creator AND c.context_id IS DISTINCT FROM p_exclude
  AND shared_expenses._label_key(shared_expenses._context_label(c.kind,c.name,c.created_by,p_creator,c.context_id))=shared_expenses._label_key(p_label)
  AND shared_expenses._label_key(p_label)<>''
  ORDER BY c.created_at,c.context_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION shared_expenses._member_label(p_name text,p_profile uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN NULLIF(btrim(p_name),'') IS NOT NULL THEN btrim(p_name)
  WHEN p_profile IS NULL THEN 'Former member'
  ELSE (SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=p_profile) END
$$;

-- ---------------------------------------------------------------- purge
-- The ciphertext and mask go as soon as a request is resolved; the last four
-- digits and the keyed hash stay (the hash is dropped with the account).
CREATE FUNCTION shared_expenses._invitations_purge_phone() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ BEGIN
 IF OLD.claimant_phone_enc IS NOT NULL AND NEW.claimant_phone_enc IS NOT DISTINCT FROM OLD.claimant_phone_enc AND NEW.state<>'awaiting_owner' THEN
  NEW.claimant_phone_enc:=NULL;NEW.claimant_phone_key_id:=NULL;NEW.claimant_phone_mask:=NULL;NEW.phone_purged_at:=clock_timestamp();
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER shared_invitations_purge_phone BEFORE UPDATE ON shared_expenses.invitations FOR EACH ROW EXECUTE FUNCTION shared_expenses._invitations_purge_phone();

-- Set-based purge: expired or resolved rows. Called lazily by every function that
-- reads requests and hourly by cron (when pg_cron exists).
CREATE FUNCTION shared_expenses.purge_expired_claimant_phones() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE n integer; BEGIN
 UPDATE shared_expenses.invitations SET claimant_phone_enc=NULL,claimant_phone_key_id=NULL,claimant_phone_mask=NULL,phone_purged_at=clock_timestamp()
  WHERE claimant_phone_enc IS NOT NULL AND (state<>'awaiting_owner' OR expires_at<=clock_timestamp());
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END $$;

-- Account deletion: the claimant's links to the request go, with every phone value.
CREATE FUNCTION shared_expenses._scrub_profile_phone() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ BEGIN
 UPDATE shared_expenses.members m SET state='declined' FROM shared_expenses.invitations i
  WHERE i.claimed_profile_id=OLD.id AND i.state='awaiting_owner' AND i.via_group_link AND m.context_id=i.context_id AND m.member_id=i.member_id AND m.profile_id IS NULL AND m.state='invited';
 UPDATE shared_expenses.invitations SET state=CASE WHEN state='awaiting_owner' THEN 'rejected' ELSE state END,
  claimed_profile_id=NULL,verified_phone_suffix=NULL,claimant_phone_enc=NULL,claimant_phone_key_id=NULL,claimant_phone_cc=NULL,
  claimant_phone_hash=NULL,claimant_phone_mask=NULL,phone_share='none',phone_purged_at=clock_timestamp()
  WHERE claimed_profile_id=OLD.id;
 RETURN OLD;
END $$;
CREATE TRIGGER shared_scrub_profile_phone BEFORE DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION shared_expenses._scrub_profile_phone();

DO $$ BEGIN
 IF EXISTS(SELECT FROM pg_extension WHERE extname='pg_cron') THEN
  EXECUTE $c$SELECT cron.schedule('purge-claimant-phones','7 * * * *','SELECT shared_expenses.purge_expired_claimant_phones()')$c$;
 END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron not scheduled: %',SQLERRM;
END $$;

-- ---------------------------------------------------------------- capture
-- Consent for a (re)claim. 'shared' is never set here: the ciphertext is bound to
-- the invitation id, which can be created in this very call, so the API attaches
-- the number afterwards in the same transaction (attach_claimant_phone).
CREATE FUNCTION shared_expenses._apply_claim_consent(p_inv uuid,p_suffix text,p_share text) RETURNS void LANGUAGE plpgsql
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE s text:=coalesce(p_share,'not_asked'); BEGIN
 IF s NOT IN ('declined','none','not_asked') THEN s:='not_asked'; END IF;
 UPDATE shared_expenses.invitations SET verified_phone_suffix=p_suffix,phone_share=s,
  phone_purged_at=CASE WHEN claimant_phone_enc IS NOT NULL THEN clock_timestamp() ELSE phone_purged_at END,
  claimant_phone_enc=NULL,claimant_phone_key_id=NULL,claimant_phone_cc=NULL,claimant_phone_hash=NULL,claimant_phone_mask=NULL,phone_captured_at=NULL
  WHERE invitation_id=p_inv;
END $$;

CREATE FUNCTION shared_expenses.attach_claimant_phone(p_invitation uuid,p_hash text,p_cc text,p_mask text,p_enc bytea,p_key_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation FOR UPDATE;
 IF NOT FOUND OR i.claimed_profile_id IS DISTINCT FROM a OR i.state<>'awaiting_owner' OR i.expires_at<=clock_timestamp() OR i.target_phone_hash IS NOT NULL
  OR p_enc IS NULL OR p_key_id IS NULL OR p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' OR octet_length(p_enc) NOT BETWEEN 29 AND 256
  OR coalesce(p_cc,'') !~ '^(\+[0-9]{1,4})?$' OR p_mask IS NULL OR p_mask !~ '^[+0-9• ]{1,32}$'
 THEN RETURN jsonb_build_object('attached',false); END IF;
 UPDATE shared_expenses.invitations SET phone_share='shared',claimant_phone_enc=p_enc,claimant_phone_key_id=p_key_id,claimant_phone_cc=NULLIF(p_cc,''),
  claimant_phone_hash=p_hash,claimant_phone_mask=p_mask,phone_captured_at=clock_timestamp(),phone_purged_at=NULL WHERE invitation_id=p_invitation;
 RETURN jsonb_build_object('attached',true);
END $$;

-- ---------------------------------------------------------------- claims
DROP FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text);
DROP FUNCTION shared_expenses._claim_group_link(text,text,uuid,text);

CREATE FUNCTION shared_expenses._claim_group_link(p_token text,p_suffix text,p_operation uuid,p_hash text,p_share text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); g shared_expenses.group_links; r jsonb; m shared_expenses.members; p shared_expenses.invitations; inv uuid; mid uuid; nm text; cand text; n int:=1; BEGIN
 SELECT * INTO g FROM shared_expenses.group_links WHERE token_hash=p_token AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'invitation.claim',jsonb_build_object('tokenHash',p_token,'accept',true),g.context_id);
 IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=g.context_id AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 PERFORM pg_advisory_xact_lock(hashtext(g.context_id::text));
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=g.context_id AND profile_id=a;
 IF FOUND THEN
  IF m.state='active' THEN RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',m.member_id,'status','joined'));END IF;
  RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505';
 END IF;
 -- A request of this person already waiting: refresh it (new consent, number, suffix). If it had
 -- expired, bring it back to life instead of returning a stale, never-answered row.
 SELECT * INTO p FROM shared_expenses.invitations i WHERE i.context_id=g.context_id AND i.claimed_profile_id=a AND i.via_group_link AND i.state='awaiting_owner' ORDER BY i.created_at DESC LIMIT 1 FOR UPDATE;
 IF FOUND THEN
  PERFORM shared_expenses._apply_claim_consent(p.invitation_id,p_suffix,p_share);
  IF p.expires_at<=clock_timestamp() THEN
   UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()+interval '7 days' WHERE invitation_id=p.invitation_id;
   PERFORM shared_expenses._emit(g.context_id,'membership.requested',p.member_id,jsonb_build_object('memberId',p.member_id,'status','awaiting_owner'));
  END IF;
  RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',p.member_id,'invitationId',p.invitation_id,'status','awaiting_owner'));
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
 PERFORM shared_expenses._apply_claim_consent(inv,p_suffix,p_share);
 PERFORM shared_expenses._emit(g.context_id,'membership.requested',mid,jsonb_build_object('memberId',mid,'status','awaiting_owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',g.context_id,'memberId',mid,'invitationId',inv,'status','awaiting_owner'));
END $$;

CREATE FUNCTION shared_expenses.claim_invitation(p_token text,p_phone text,p_suffix text,p_operation uuid,p_hash text,p_share text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor();i shared_expenses.invitations;r jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN RETURN shared_expenses._claim_group_link(p_token,p_suffix,p_operation,p_hash,p_share);END IF;
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
  UPDATE shared_expenses.invitations SET claimed_profile_id=a,state='awaiting_owner',expires_at=clock_timestamp()+interval '7 days' WHERE invitation_id=i.invitation_id;
  PERFORM shared_expenses._apply_claim_consent(i.invitation_id,p_suffix,p_share);
  IF i.target_phone_hash IS NOT NULL THEN PERFORM shared_expenses._bind_invitation(i.invitation_id,a);i.state:='joined';
  ELSE i.state:='awaiting_owner'; PERFORM shared_expenses._emit(i.context_id,'membership.requested',i.member_id,jsonb_build_object('memberId',i.member_id,'status','awaiting_owner'));END IF;
 ELSIF i.state='awaiting_owner' AND i.claimed_profile_id=a THEN
  -- Still pending: a repeated claim refreshes the suffix and re-applies consent.
  PERFORM shared_expenses._apply_claim_consent(i.invitation_id,p_suffix,p_share);
 END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'invitationId',i.invitation_id,'status',i.state));
END $$;

-- Revoking the link also drops the numbers of requests that came through it.
CREATE OR REPLACE FUNCTION shared_expenses.revoke_group_link(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.revoke',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 UPDATE shared_expenses.invitations SET claimant_phone_enc=NULL,claimant_phone_key_id=NULL,claimant_phone_mask=NULL,phone_purged_at=clock_timestamp()
  WHERE context_id=p_context AND via_group_link AND claimant_phone_enc IS NOT NULL;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',false));
END $$;

-- ---------------------------------------------------------------- commands with unique names
CREATE OR REPLACE FUNCTION shared_expenses.create_context(p_context_id uuid,p_kind text,p_name text,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; mid uuid; seq bigint; ex uuid; BEGIN
  PERFORM shared_expenses._require_proposals();
  IF p_context_id IS NULL OR p_kind NOT IN ('group','direct') OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_context' USING ERRCODE='22023'; END IF;
  r:=shared_expenses._operation(p_operation_id,p_request_hash,'context.create',jsonb_build_object('contextId',p_context_id,'contextKind',p_kind,'name',p_name),p_context_id);
  IF r IS NOT NULL THEN
    IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context_id AND profile_id=a AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
    RETURN r;
  END IF;
  IF p_kind='direct' THEN
    PERFORM shared_expenses._assert_member_label(shared_expenses._clean_label(p_name));
    PERFORM pg_advisory_xact_lock(hashtext('friends:'||a::text));
    ex:=shared_expenses._friend_context(a,NULL,p_name);
    IF ex IS NOT NULL THEN RAISE EXCEPTION 'friend_name_taken' USING ERRCODE='23505',DETAIL=ex::text; END IF;
  END IF;
  INSERT INTO shared_expenses.contexts(context_id,kind,name,created_by) VALUES(p_context_id,p_kind,btrim(p_name),a);
  mid:=gen_random_uuid();
  INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state) VALUES(p_context_id,mid,a,'owner','active');
  seq:=shared_expenses._emit(p_context_id,'context.created',p_context_id,jsonb_build_object('contextId',p_context_id));
  RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','created','contextId',p_context_id,'memberId',mid,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.invite_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; mid uuid; target uuid; r jsonb; context_kind text; creator uuid; seq bigint; nm text; ex uuid; required text[]:=ARRAY['contextId','memberId','displayName'];
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required||ARRAY['profileId'])) OR octet_length(p_payload::text)>2048 OR jsonb_typeof(p_payload->'displayName')<>'string' OR length(btrim(p_payload->>'displayName')) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; mid:=(p_payload->>'memberId')::uuid; target:=(p_payload->>'profileId')::uuid;
 IF ctx IS NULL OR mid IS NULL OR (p_payload ? 'profileId' AND target IS NULL) THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'member.invite',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT kind,created_by INTO context_kind,creator FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx)>=(CASE WHEN context_kind='direct' THEN 2 ELSE 200 END) THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023'; END IF;
 nm:=shared_expenses._clean_label(p_payload->>'displayName');
 PERFORM shared_expenses._assert_member_label(nm);
 PERFORM pg_advisory_xact_lock(hashtext(ctx::text));
 IF shared_expenses._label_taken(ctx,mid,nm) THEN RAISE EXCEPTION 'member_name_taken' USING ERRCODE='23505'; END IF;
 IF context_kind='direct' THEN
  PERFORM pg_advisory_xact_lock(hashtext('friends:'||creator::text));
  ex:=shared_expenses._friend_context(creator,ctx,nm);
  IF ex IS NOT NULL THEN RAISE EXCEPTION 'friend_name_taken' USING ERRCODE='23505',DETAIL=ex::text; END IF;
 END IF;
 BEGIN
   INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) VALUES(ctx,mid,target,'member','invited',nm);
 EXCEPTION WHEN foreign_key_violation OR unique_violation THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505';
 END;
 seq:=shared_expenses._emit(ctx,'member.invited',mid,jsonb_build_object('memberId',mid,'status','invited'));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','invited','memberId',mid,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.rename_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; mid uuid; n text; r jsonb; t shared_expenses.members; is_owner boolean; seq bigint; ckind text; creator uuid; ex uuid; required text[]:=ARRAY['contextId','memberId','displayName'];
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required))
  OR octet_length(p_payload::text)>2048 OR jsonb_typeof(p_payload->'displayName')<>'string' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; mid:=(p_payload->>'memberId')::uuid;
 n:=shared_expenses._clean_label(p_payload->>'displayName');
 IF ctx IS NULL OR mid IS NULL OR n IS NULL OR n='' THEN RAISE EXCEPTION 'invalid_member_name' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'member.rename',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 SELECT kind,created_by INTO ckind,creator FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO t FROM shared_expenses.members WHERE context_id=ctx AND member_id=mid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'member_not_found' USING ERRCODE='22023'; END IF;
 is_owner:=EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active');
 IF NOT is_owner AND t.profile_id IS DISTINCT FROM a THEN RAISE EXCEPTION 'member_rename_not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT (t.state='invited' AND is_owner) AND NOT (t.state='active' AND t.profile_id IS NOT NULL) THEN RAISE EXCEPTION 'member_not_renamable' USING ERRCODE='55000'; END IF;
 -- Same name again (or only case/spacing/accents changed) is always fine, even for legacy duplicates.
 IF shared_expenses._label_key(n) IS DISTINCT FROM shared_expenses._label_key(shared_expenses._member_label(t.display_name,t.profile_id)) THEN
  PERFORM shared_expenses._assert_member_label(n);
  PERFORM pg_advisory_xact_lock(hashtext(ctx::text));
  IF shared_expenses._label_taken(ctx,mid,n) THEN RAISE EXCEPTION 'member_name_taken' USING ERRCODE='23505'; END IF;
  IF ckind='direct' AND t.profile_id IS DISTINCT FROM creator THEN
   PERFORM pg_advisory_xact_lock(hashtext('friends:'||creator::text));
   ex:=shared_expenses._friend_context(creator,ctx,n);
   IF ex IS NOT NULL THEN RAISE EXCEPTION 'friend_name_taken' USING ERRCODE='23505',DETAIL=ex::text; END IF;
  END IF;
 END IF;
 UPDATE shared_expenses.members SET display_name=n WHERE context_id=ctx AND member_id=mid;
 seq:=shared_expenses._emit(ctx,'member.renamed',mid,jsonb_build_object('memberId',mid));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','renamed','memberId',mid,'displayName',n,'sequence',seq::text));
END $$;

-- ---------------------------------------------------------------- claimantPhone in lists
-- Same mask but a different number among pending requests of the same owner (or the
-- same last digits as a member of the same split with a different number).
CREATE FUNCTION shared_expenses._is_lookalike(i shared_expenses.invitations,p_owner uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT i.claimant_phone_hash IS NOT NULL AND (
  EXISTS(SELECT FROM shared_expenses.invitations j
   WHERE j.invitation_id<>i.invitation_id AND j.state='awaiting_owner' AND j.expires_at>clock_timestamp()
   AND j.claimant_phone_mask IS NOT DISTINCT FROM i.claimant_phone_mask AND i.claimant_phone_mask IS NOT NULL
   AND j.claimant_phone_hash IS NOT NULL AND j.claimant_phone_hash<>i.claimant_phone_hash
   AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=j.context_id AND o.profile_id=p_owner AND o.role='owner' AND o.state='active'))
  OR EXISTS(SELECT FROM shared_expenses.invitations j
   WHERE j.context_id=i.context_id AND j.invitation_id<>i.invitation_id AND j.state='joined'
   AND j.claimant_phone_hash IS NOT NULL AND j.claimant_phone_hash<>i.claimant_phone_hash
   AND j.verified_phone_suffix IS NOT NULL AND j.verified_phone_suffix=i.verified_phone_suffix
   AND coalesce(j.claimant_phone_cc,'')=coalesce(i.claimant_phone_cc,'')))
$$;

CREATE FUNCTION shared_expenses._claimant_phone_json(i shared_expenses.invitations,p_owner uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE avail boolean; reason text; status text:='unknown'; dup jsonb:='[]'::jsonb; lk boolean:=false; matched uuid; BEGIN
 avail:=i.phone_share='shared' AND i.claimant_phone_enc IS NOT NULL AND i.state='awaiting_owner' AND i.expires_at>clock_timestamp();
 reason:=CASE WHEN avail THEN NULL WHEN i.phone_share='declined' THEN 'claimant_declined' WHEN i.phone_share='none' THEN 'no_verified_phone'
  WHEN i.phone_share='not_asked' THEN 'claimed_before_update' ELSE 'purged' END;
 IF i.claimant_phone_hash IS NOT NULL THEN
  SELECT d.profile_id INTO matched FROM shared_expenses.phone_directory d WHERE d.phone_hash=i.claimant_phone_hash;
  status:=CASE WHEN NOT FOUND THEN 'unknown' WHEN matched IS NOT DISTINCT FROM i.claimed_profile_id THEN 'confirmed' ELSE 'moved' END;
 END IF;
 IF avail THEN
  lk:=shared_expenses._is_lookalike(i,p_owner);
  SELECT coalesce(jsonb_agg(x ORDER BY x),'[]'::jsonb) INTO dup FROM (
   SELECT j.invitation_id::text x FROM shared_expenses.invitations j
    WHERE j.invitation_id<>i.invitation_id AND j.claimant_phone_hash=i.claimant_phone_hash AND j.claimed_profile_id IS DISTINCT FROM i.claimed_profile_id
    AND j.state IN ('awaiting_owner','joined') AND (j.state='joined' OR j.expires_at>clock_timestamp())
    AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=j.context_id AND o.profile_id=p_owner AND o.role='owner' AND o.state='active')) q;
 END IF;
 RETURN jsonb_build_object('v',1,
  'source',CASE WHEN i.phone_share='none' THEN 'none' WHEN i.phone_share IN ('shared','declined') OR i.verified_phone_suffix IS NOT NULL THEN 'verified' ELSE 'none' END,
  'consent',i.phone_share,'countryCode',i.claimant_phone_cc,'last4',i.verified_phone_suffix,
  'mask',CASE WHEN avail THEN i.claimant_phone_mask END,'available',avail,'unavailableReason',reason,
  'lookalike',lk,'duplicateOf',dup,'numberStatus',status,
  'matchesTyped',CASE WHEN i.target_phone_hash IS NULL OR i.claimant_phone_hash IS NULL THEN NULL ELSE i.target_phone_hash=i.claimant_phone_hash END,
  'capturedAt',CASE WHEN i.phone_captured_at IS NULL THEN NULL ELSE to_char(i.phone_captured_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') END);
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.list_join_requests() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'contextId',q.context_id,'contextKind',q.kind,
  'contextName',q.name,'memberName',q.display_name,'verifiedPhoneSuffix',q.verified_phone_suffix,'claimantName',q.claimant_name,
  'claimantProfileName',q.claimant_name,'claimantPhoneSuffix',q.verified_phone_suffix,'createdAt',q.created_at,
  'claimantPhone',shared_expenses._claimant_phone_json(q.inv,a)) ORDER BY q.created_at DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.invitation_id,i.context_id,c.kind,shared_expenses._context_label(c.kind,c.name,c.created_by,a,c.context_id) AS name,m.display_name,i.verified_phone_suffix,
   NULLIF(shared_expenses._clean_label((SELECT p.display_name FROM public.profiles p WHERE p.id=i.claimed_profile_id)),'') AS claimant_name,i.created_at,i AS inv
  FROM shared_expenses.invitations i
  JOIN shared_expenses.contexts c ON c.context_id=i.context_id AND c.state='active'
  JOIN shared_expenses.members m ON m.context_id=i.context_id AND m.member_id=i.member_id
  WHERE i.state='awaiting_owner' AND i.expires_at>clock_timestamp()
  AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
  ORDER BY i.created_at DESC LIMIT 20) q;
 RETURN jsonb_build_object('items',rows);
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',q.display_name,
  'status',CASE WHEN q.declined_at IS NOT NULL THEN 'declined' WHEN q.state IN ('open','awaiting_owner') AND q.expires_at<=clock_timestamp() THEN 'expired' ELSE q.state END,
  'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,
  'claimantName',NULLIF(shared_expenses._clean_label((SELECT p.display_name FROM public.profiles p WHERE p.id=q.claimed_profile_id)),''),
  'expiresAt',q.expires_at,'createdAt',q.created_at,'claimantPhone',shared_expenses._claimant_phone_json(q.inv,a)) ORDER BY q.created_at DESC,q.invitation_id DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name,i AS inv FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR i.invitation_id>p_after) ORDER BY i.created_at DESC,i.invitation_id DESC LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;

-- Audience for pushes: names cleaned, and still no number of any kind besides the suffix it already had.
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
    (SELECT NULLIF(shared_expenses._clean_label(m.display_name),'') FROM shared_expenses.members m WHERE m.context_id=i.context_id AND m.member_id=i.member_id),
    (SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id)),
  'claimantProfileName',(SELECT NULLIF(shared_expenses._clean_label(p.display_name),'') FROM public.profiles p WHERE p.id=i.claimed_profile_id),
  'claimantPhoneSuffix',i.verified_phone_suffix,
  'owners',(SELECT coalesce(jsonb_agg(m.profile_id ORDER BY m.member_id),'[]'::jsonb) FROM shared_expenses.members m
            WHERE m.context_id=i.context_id AND m.role='owner' AND m.state='active' AND m.profile_id IS NOT NULL AND m.profile_id<>a));
END $$;

-- ---------------------------------------------------------------- reveal, check, bulk lookalike
-- Hands the ciphertext to the API (never plaintext; the database cannot decrypt).
CREATE FUNCTION shared_expenses.reveal_claimant_phone(p_invitation uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; BEGIN
 PERFORM shared_expenses._require_proposals();
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext('reveal:'||a::text));
 IF NOT EXISTS(SELECT FROM shared_expenses.phone_directory WHERE profile_id=a) THEN RETURN jsonb_build_object('error','owner_phone_required'); END IF;
 IF i.state<>'awaiting_owner' OR i.expires_at<=clock_timestamp() OR i.phone_share<>'shared' OR i.claimant_phone_enc IS NULL THEN RETURN jsonb_build_object('error','phone_not_available'); END IF;
 IF (SELECT count(*) FROM shared_expenses.phone_reveals WHERE owner_profile_id=a AND via='tap' AND at>clock_timestamp()-interval '1 hour')>=5
  OR (SELECT count(*) FROM shared_expenses.phone_reveals WHERE owner_profile_id=a AND via='tap' AND at>clock_timestamp()-interval '1 day')>=30
 THEN RETURN jsonb_build_object('error','reveal_rate_limited'); END IF;
 INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) VALUES(p_invitation,a,'tap');
 RETURN jsonb_build_object('invitationId',i.invitation_id,'enc',encode(i.claimant_phone_enc,'hex'),'keyId',i.claimant_phone_key_id);
END $$;

-- Does a number the owner typed match the claimant's? Compared by keyed hash only.
CREATE FUNCTION shared_expenses.check_claimant_phone(p_invitation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; m boolean; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT * INTO i FROM shared_expenses.invitations WHERE invitation_id=p_invitation FOR UPDATE;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 IF i.state<>'awaiting_owner' OR i.expires_at<=clock_timestamp() THEN RETURN jsonb_build_object('error','phone_not_available'); END IF;
 -- Not shared (declined, none, not asked): never answer, never count.
 IF i.phone_share<>'shared' OR i.claimant_phone_hash IS NULL THEN RETURN jsonb_build_object('matches',NULL,'attemptsLeft',greatest(3-i.phone_check_attempts,0)); END IF;
 IF i.phone_check_attempts>=3 THEN RETURN jsonb_build_object('error','check_attempts_exhausted'); END IF;
 m:=i.claimant_phone_hash=p_hash;
 UPDATE shared_expenses.invitations SET phone_check_attempts=phone_check_attempts+1 WHERE invitation_id=p_invitation;
 RETURN jsonb_build_object('matches',m,'attemptsLeft',3-(i.phone_check_attempts+1));
END $$;

-- Ciphertexts of the owner's pending look-alike requests only (the API shows those in full).
CREATE FUNCTION shared_expenses.list_join_requests_enc(p_ids uuid[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); res jsonb; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_ids IS NULL OR cardinality(p_ids)>20 THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 PERFORM shared_expenses.purge_expired_claimant_phones();
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',i.invitation_id,'enc',encode(i.claimant_phone_enc,'hex'),'keyId',i.claimant_phone_key_id)),'[]'::jsonb) INTO res
  FROM shared_expenses.invitations i
  WHERE i.invitation_id=ANY(p_ids) AND i.state='awaiting_owner' AND i.expires_at>clock_timestamp() AND i.phone_share='shared' AND i.claimant_phone_enc IS NOT NULL
  AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=a AND o.role='owner' AND o.state='active')
  AND shared_expenses._is_lookalike(i,a);
 INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via)
  SELECT (e->>'invitationId')::uuid,a,'lookalike' FROM jsonb_array_elements(res) e
  WHERE NOT EXISTS(SELECT FROM shared_expenses.phone_reveals r WHERE r.invitation_id=(e->>'invitationId')::uuid AND r.owner_profile_id=a AND r.via='lookalike' AND r.at>clock_timestamp()-interval '1 hour');
 RETURN res;
END $$;

-- ---------------------------------------------------------------- ownership and grants
ALTER FUNCTION shared_expenses._clean_label(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._label_key(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._label_reserved(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._assert_member_label(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._label_taken(uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._friend_context(uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._member_label(text,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._invitations_purge_phone() OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.purge_expired_claimant_phones() OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._scrub_profile_phone() OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._apply_claim_consent(uuid,text,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.attach_claimant_phone(uuid,text,text,text,bytea,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._claim_group_link(text,text,uuid,text,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.revoke_group_link(uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.create_context(uuid,text,text,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.invite_member(jsonb,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.rename_member(jsonb,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._is_lookalike(shared_expenses.invitations,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._claimant_phone_json(shared_expenses.invitations,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.list_join_requests() OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.list_invitations(uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.invitation_audience(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.reveal_claimant_phone(uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.check_claimant_phone(uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.list_join_requests_enc(uuid[]) OWNER TO shared_expenses_owner;

REVOKE ALL ON FUNCTION
 shared_expenses._clean_label(text),shared_expenses._label_key(text),shared_expenses._label_reserved(text),shared_expenses._assert_member_label(text),
 shared_expenses._label_taken(uuid,uuid,text),shared_expenses._friend_context(uuid,uuid,text),shared_expenses._invitations_purge_phone(),
 shared_expenses.purge_expired_claimant_phones(),shared_expenses._scrub_profile_phone(),shared_expenses._apply_claim_consent(uuid,text,text),
 shared_expenses.attach_claimant_phone(uuid,text,text,text,bytea,text),shared_expenses._claim_group_link(text,text,uuid,text,text),
 shared_expenses.claim_invitation(text,text,text,uuid,text,text),shared_expenses._is_lookalike(shared_expenses.invitations,uuid),
 shared_expenses._claimant_phone_json(shared_expenses.invitations,uuid),shared_expenses.reveal_claimant_phone(uuid),
 shared_expenses.check_claimant_phone(uuid,text),shared_expenses.list_join_requests_enc(uuid[])
 FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.attach_claimant_phone(uuid,text,text,text,bytea,text),shared_expenses.claim_invitation(text,text,text,uuid,text,text),
 shared_expenses.reveal_claimant_phone(uuid),shared_expenses.check_claimant_phone(uuid,text),shared_expenses.list_join_requests_enc(uuid[]) TO app_user;
REVOKE ALL ON FUNCTION shared_expenses._member_label(text,uuid),shared_expenses.revoke_group_link(uuid,uuid,text),shared_expenses.create_context(uuid,text,text,uuid,text),
 shared_expenses.invite_member(jsonb,uuid,text),shared_expenses.rename_member(jsonb,uuid,text),shared_expenses.list_join_requests(),shared_expenses.list_invitations(uuid,uuid),
 shared_expenses.invitation_audience(text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses._member_label(text,uuid),shared_expenses.revoke_group_link(uuid,uuid,text),shared_expenses.create_context(uuid,text,text,uuid,text),
 shared_expenses.invite_member(jsonb,uuid,text),shared_expenses.rename_member(jsonb,uuid,text),shared_expenses.list_join_requests(),shared_expenses.list_invitations(uuid,uuid),
 shared_expenses.invitation_audience(text) TO app_user;

-- Preview adds ownerName: the cleaned label of whoever created the link or invitation.
-- Names only; never anything about a phone.
CREATE OR REPLACE FUNCTION shared_expenses.preview_invitation(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); i shared_expenses.invitations; gl shared_expenses.group_links; BEGIN
 PERFORM shared_expenses._actor();PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN
  SELECT g.* INTO gl FROM shared_expenses.group_links g JOIN shared_expenses.contexts c ON c.context_id=g.context_id AND c.state='active' AND c.kind='group'
  WHERE g.token_hash=p_token AND g.expires_at>clock_timestamp();
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
  RETURN jsonb_build_object('kind','group_link','contextId',gl.context_id,'memberName','You','phoneBound',false,'status','open','expiresAt',gl.expires_at,
   'contextName',(SELECT name FROM shared_expenses.contexts WHERE context_id=gl.context_id),
   'ownerName',(SELECT NULLIF(shared_expenses._member_label(m.display_name,m.profile_id),'Former member') FROM shared_expenses.members m WHERE m.context_id=gl.context_id AND m.profile_id=gl.created_by LIMIT 1));
 END IF;
 IF i.state='rejected' OR i.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active')
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('invitationId',i.invitation_id,'contextId',i.context_id,'memberId',i.member_id,
 'contextName',(SELECT shared_expenses._context_label(c2.kind,c2.name,c2.created_by,a,c2.context_id) FROM shared_expenses.contexts c2 WHERE c2.context_id=i.context_id),
 'memberName',(SELECT display_name FROM shared_expenses.members WHERE context_id=i.context_id AND member_id=i.member_id),
 'ownerName',(SELECT NULLIF(shared_expenses._member_label(m.display_name,m.profile_id),'Former member') FROM shared_expenses.members m WHERE m.context_id=i.context_id AND m.profile_id=i.issuer_profile_id LIMIT 1),
 'kind','invitation','phoneBound',i.target_phone_hash IS NOT NULL,'status',i.state,'expiresAt',i.expires_at);
END $$;
ALTER FUNCTION shared_expenses.preview_invitation(text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.preview_invitation(text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.preview_invitation(text) TO app_user;
