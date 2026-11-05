-- Safe ways out of a split. Removing never rewrites history or money:
--  * an owner can remove someone who has not joined and has no expense;
--  * a member can leave only when settled up (zero balance, nothing pending).
-- Owners cannot leave. Everything else stays as it is.
CREATE FUNCTION shared_expenses.remove_member(p_context uuid,p_member uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; m shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'member.remove',jsonb_build_object('contextId',p_context,'memberId',p_member),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context AND member_id=p_member FOR UPDATE;
 IF NOT FOUND OR m.state<>'invited' OR m.profile_id IS NOT NULL OR m.role='owner' THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_members WHERE context_id=p_context AND member_id=p_member) THEN RAISE EXCEPTION 'member_has_expenses' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.members SET state='declined' WHERE context_id=p_context AND member_id=p_member;
 UPDATE shared_expenses.invitations SET state='rejected' WHERE context_id=p_context AND member_id=p_member AND state IN ('open','awaiting_owner');
 seq:=shared_expenses._emit(p_context,'member.removed',p_member,jsonb_build_object('memberId',p_member,'status','removed'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','removed','memberId',p_member,'sequence',seq::text));
END $$;

CREATE FUNCTION shared_expenses.leave_context(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; m shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR m.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'context.leave',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF m.role='owner' THEN RAISE EXCEPTION 'owner_cannot_leave' USING ERRCODE='55000'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.member_balances WHERE context_id=p_context AND member_id=m.member_id AND balance_minor<>0)
 OR EXISTS(SELECT FROM shared_expenses.revision_members rm JOIN shared_expenses.expenses e ON e.context_id=rm.context_id AND e.expense_id=rm.expense_id
   WHERE rm.context_id=p_context AND rm.member_id=m.member_id AND e.accepted_revision_id IS NULL)
 THEN RAISE EXCEPTION 'settle_first' USING ERRCODE='55000'; END IF;
 -- Emit while still active so the leaving person's own device receives the event.
 seq:=shared_expenses._emit(p_context,'membership.left',m.member_id,jsonb_build_object('memberId',m.member_id,'status','left'));
 UPDATE shared_expenses.members SET state='left' WHERE context_id=p_context AND member_id=m.member_id;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','left','memberId',m.member_id,'sequence',seq::text));
END $$;

ALTER FUNCTION shared_expenses.remove_member(uuid,uuid,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.leave_context(uuid,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.remove_member(uuid,uuid,uuid,text),shared_expenses.leave_context(uuid,uuid,text) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.remove_member(uuid,uuid,uuid,text),shared_expenses.leave_context(uuid,uuid,text) TO app_user;
