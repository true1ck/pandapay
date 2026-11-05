-- People whose account was deleted show as "Former member" (history and balances stay),
-- the owner can hand the group to another active member, and when the owner's account is
-- gone any active member can take it over so the group is never stuck.
CREATE OR REPLACE FUNCTION shared_expenses._member_label(p_name text,p_profile uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN NULLIF(btrim(p_name),'') IS NOT NULL THEN btrim(p_name)
  WHEN p_profile IS NULL THEN 'Former member'
  ELSE (SELECT NULLIF(btrim(d.display_name),'') FROM shared_expenses.phone_directory d WHERE d.profile_id=p_profile) END
$$;

CREATE FUNCTION shared_expenses.transfer_owner(p_context uuid,p_member uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; t shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'owner.transfer',jsonb_build_object('contextId',p_context,'memberId',p_member),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO t FROM shared_expenses.members WHERE context_id=p_context AND member_id=p_member FOR UPDATE;
 IF NOT FOUND OR t.state<>'active' OR t.profile_id IS NULL OR t.profile_id=a THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505'; END IF;
 UPDATE shared_expenses.members SET role='member' WHERE context_id=p_context AND profile_id=a;
 UPDATE shared_expenses.members SET role='owner' WHERE context_id=p_context AND member_id=p_member;
 seq:=shared_expenses._emit(p_context,'member.owner_changed',p_member,jsonb_build_object('memberId',p_member,'status','owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','owner','memberId',p_member,'sequence',seq::text));
END $$;

CREATE FUNCTION shared_expenses.take_over_ownership(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; me shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO me FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR me.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'owner.take_over',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 -- Only when no owner with a live account remains.
 IF EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND role='owner' AND state='active' AND profile_id IS NOT NULL)
 THEN RAISE EXCEPTION 'owner_still_present' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.members SET role='member' WHERE context_id=p_context AND role='owner';
 UPDATE shared_expenses.members SET role='owner' WHERE context_id=p_context AND member_id=me.member_id;
 seq:=shared_expenses._emit(p_context,'member.owner_changed',me.member_id,jsonb_build_object('memberId',me.member_id,'status','owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','owner','memberId',me.member_id,'sequence',seq::text));
END $$;

ALTER FUNCTION shared_expenses.transfer_owner(uuid,uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.take_over_ownership(uuid,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.transfer_owner(uuid,uuid,uuid,text),shared_expenses.take_over_ownership(uuid,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.transfer_owner(uuid,uuid,uuid,text),shared_expenses.take_over_ownership(uuid,uuid,text) TO app_user;
