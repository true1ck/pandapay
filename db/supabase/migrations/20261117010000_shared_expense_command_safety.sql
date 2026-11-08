-- Keep the actor receipt before the context lock to preserve lock ordering.
-- Mutable authorization is checked again after the context lock is acquired.
-- Leave and transfer replays can return the actor's own committed receipt
-- even when the successful command changed their original role.
-- Existing signatures, ownership, ACLs and expense approval rules are retained.

CREATE INDEX shared_pair_balances_high_member
 ON shared_expenses.pair_balances(context_id,high_member_id);
CREATE INDEX shared_revision_members_by_member
 ON shared_expenses.revision_members(context_id,member_id) WHERE approval_required;

CREATE OR REPLACE FUNCTION shared_expenses.remove_member(p_context uuid,p_member uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; m shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'member.remove',jsonb_build_object('contextId',p_context,'memberId',p_member),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context AND member_id=p_member FOR UPDATE;
 IF NOT FOUND OR m.state<>'invited' OR m.profile_id IS NOT NULL OR m.role='owner' THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_members WHERE context_id=p_context AND member_id=p_member) THEN RAISE EXCEPTION 'member_has_expenses' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.members SET state='declined' WHERE context_id=p_context AND member_id=p_member;
 UPDATE shared_expenses.invitations SET state='rejected' WHERE context_id=p_context AND member_id=p_member AND state IN ('open','awaiting_owner');
 seq:=shared_expenses._emit(p_context,'member.removed',p_member,jsonb_build_object('memberId',p_member,'status','removed'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','removed','memberId',p_member,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.create_group_link(p_context uuid,p_token_hash text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; expiry timestamptz; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF p_token_hash IS NULL OR p_token_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_invitation' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'grouplink.create',jsonb_build_object('contextId',p_context,'tokenHash',p_token_hash),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' AND kind='group' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 -- Replacing the link invalidates the old one; requests already made stay valid.
 DELETE FROM shared_expenses.group_links WHERE context_id=p_context;
 INSERT INTO shared_expenses.group_links(context_id,token_hash,created_by) VALUES(p_context,p_token_hash,a) RETURNING expires_at INTO expiry;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',p_context,'active',true,'expiresAt',expiry));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.create_invitation(p jsonb,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); id uuid:=(p->>'invitationId')::uuid; ctx uuid:=(p->>'contextId')::uuid; mid uuid:=(p->>'memberId')::uuid; r jsonb; expiry timestamptz; target text:=p->>'targetPhoneHash'; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(id,p_hash,'invitation.create',p,ctx);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
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
 -- Issuer caps span contexts, so a context lock alone is insufficient.
 PERFORM pg_advisory_xact_lock(hashtextextended('shared-invite-issuer:'||a::text,0));
 IF (SELECT count(*) FROM (SELECT 1 FROM shared_expenses.invitations WHERE issuer_profile_id=a AND created_at>clock_timestamp()-interval '1 hour' LIMIT 50) q)>=50
 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.invitations SET state='rejected' WHERE context_id=ctx AND member_id=mid AND state IN ('open','awaiting_owner');
 INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,target_phone_hash)
 VALUES(id,ctx,mid,a,p->>'tokenHash',target) RETURNING expires_at INTO expiry;
 RETURN shared_expenses._finish(id,jsonb_build_object('invitationId',id,'contextId',ctx,'memberId',mid,'status','open','expiresAt',expiry));
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
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx AND state<>'declined')>=(CASE WHEN context_kind='direct' THEN 2 ELSE 200 END) THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023'; END IF;
 nm:=shared_expenses._clean_label(p_payload->>'displayName');
 PERFORM shared_expenses._assert_member_label(nm);
 PERFORM pg_advisory_xact_lock(hashtext(ctx::text));
 IF shared_expenses._label_taken(ctx,mid,nm) THEN RAISE EXCEPTION 'member_name_taken' USING ERRCODE='23505'; END IF;
 -- Friend names are the creator's own list; only the creator can learn about their other splits.
 IF context_kind='direct' AND a=creator THEN
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
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
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
  -- The friends list belongs to the creator: only the creator renaming their counterpart is checked
  -- against it, so nobody else can learn about (or be pointed at) another person's splits.
  IF ckind='direct' AND a=creator AND t.profile_id IS DISTINCT FROM creator THEN
   PERFORM pg_advisory_xact_lock(hashtext('friends:'||creator::text));
   ex:=shared_expenses._friend_context(creator,ctx,n);
   IF ex IS NOT NULL THEN RAISE EXCEPTION 'friend_name_taken' USING ERRCODE='23505',DETAIL=ex::text; END IF;
  END IF;
 END IF;
 UPDATE shared_expenses.members SET display_name=n WHERE context_id=ctx AND member_id=mid;
 seq:=shared_expenses._emit(ctx,'member.renamed',mid,jsonb_build_object('memberId',mid));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','renamed','memberId',mid,'displayName',n,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.respond_expense(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; exp uuid; rev uuid; r shared_expenses.expense_revisions; response jsonb; d text; status text; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload,ARRAY['contextId','expenseId','revisionId','decision']) THEN RAISE EXCEPTION 'invalid_response' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; exp:=(p_payload->>'expenseId')::uuid; rev:=(p_payload->>'revisionId')::uuid; d:=p_payload->>'decision';
 IF d NOT IN ('approve','reject') OR d IS NULL THEN RAISE EXCEPTION 'invalid_response' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 response:=shared_expenses._operation(p_operation_id,p_request_hash,'expense.respond',p_payload,ctx); IF response IS NOT NULL THEN RETURN response; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM shared_expenses.expense_revisions WHERE context_id=ctx AND expense_id=exp AND revision_id=rev;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND shared_expenses._review_profile(context_id,member_id,approver_profile_id)=a AND approval_required) THEN RAISE EXCEPTION 'revision_not_authorized' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_approvals WHERE context_id=ctx AND revision_id=rev AND actor_profile_id=a AND decision<>d) THEN RAISE EXCEPTION 'approval_conflict' USING ERRCODE='55000'; END IF;
 INSERT INTO shared_expenses.revision_approvals(context_id,revision_id,member_id,actor_profile_id,revision_hash,decision,operation_id)
 SELECT ctx,rev,member_id,a,r.revision_hash,d,p_operation_id FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND shared_expenses._review_profile(context_id,member_id,approver_profile_id)=a AND approval_required ON CONFLICT DO NOTHING;
 IF d='reject' THEN status:='rejected'; ELSE status:=shared_expenses._accept_revision(ctx,exp,rev); END IF;
 seq:=shared_expenses._emit(ctx,CASE WHEN status='accepted' THEN 'expense.accepted' ELSE 'expense.responded' END,rev,jsonb_build_object('expenseId',exp,'revisionId',rev,'status',status));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',status,'expenseId',exp,'revisionId',rev,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.report_settlement(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; sid uuid; payer uuid; receiver uuid; amount bigint; r jsonb; required text[]:=ARRAY['contextId','settlementId','payerMemberId','receiverMemberId','amountMinor','currency','method','paidOn']; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required||ARRAY['reference'])) OR octet_length(p_payload::text)>4096 THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; sid:=(p_payload->>'settlementId')::uuid; payer:=(p_payload->>'payerMemberId')::uuid; receiver:=(p_payload->>'receiverMemberId')::uuid;
 IF ctx IS NULL OR sid IS NULL OR payer IS NULL OR receiver IS NULL OR payer=receiver OR jsonb_typeof(p_payload->'amountMinor')<>'string' OR p_payload->>'amountMinor' !~ '^[1-9][0-9]{0,9}$' OR (p_payload->>'currency') IS DISTINCT FROM 'INR' OR p_payload->>'method' NOT IN ('upi','cash','bank') OR p_payload->>'paidOn' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR (p_payload ? 'reference' AND (jsonb_typeof(p_payload->'reference')<>'string' OR p_payload->>'reference' !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$')) THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 amount:=(p_payload->>'amountMinor')::bigint; IF amount>1000000000 THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'settlement.report',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx AND member_id IN (payer,receiver) AND state='active' AND profile_id IS NOT NULL)<>2 THEN RAISE EXCEPTION 'settlement_member_not_authorized' USING ERRCODE='42501'; END IF;
 INSERT INTO shared_expenses.settlement_reports(context_id,settlement_id,reporter_profile_id,payer_member_id,receiver_member_id,amount_minor,currency,method,paid_on) VALUES(ctx,sid,a,payer,receiver,amount,'INR',p_payload->>'method',(p_payload->>'paidOn')::date);
 IF p_payload ? 'reference' THEN INSERT INTO shared_expenses.settlement_private_references(context_id,settlement_id,owner_profile_id,reference) VALUES(ctx,sid,a,p_payload->>'reference'); END IF;
 seq:=shared_expenses._emit(ctx,'settlement.reported',sid,jsonb_build_object('settlementId',sid,'payerMemberId',payer,'receiverMemberId',receiver,'amountMinor',amount::text,'status','awaiting_receiver_confirmation'));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','awaiting_receiver_confirmation','settlementId',sid,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.respond_settlement(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; sid uuid; d text; report shared_expenses.settlement_reports; old shared_expenses.settlement_events; r jsonb; eid uuid; low uuid; high uuid; amount bigint; seq bigint; owed bigint; applied bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload,ARRAY['contextId','settlementId','decision']) THEN RAISE EXCEPTION 'invalid_settlement_response' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; sid:=(p_payload->>'settlementId')::uuid; d:=p_payload->>'decision';
 IF d IS NULL OR d NOT IN ('confirm','reject') THEN RAISE EXCEPTION 'invalid_settlement_response' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'settlement.respond',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO report FROM shared_expenses.settlement_reports WHERE context_id=ctx AND settlement_id=sid;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND member_id=report.receiver_member_id AND profile_id=a AND state='active') THEN RAISE EXCEPTION 'receiver_confirmation_required' USING ERRCODE='42501'; END IF;
 SELECT * INTO old FROM shared_expenses.settlement_events WHERE context_id=ctx AND settlement_id=sid AND kind IN ('confirmed','rejected');
 IF FOUND THEN
   IF old.kind<>(CASE WHEN d='confirm' THEN 'confirmed' ELSE 'rejected' END) THEN RAISE EXCEPTION 'settlement_terminal_conflict' USING ERRCODE='55000'; END IF;
   RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',old.kind,'settlementId',sid,'eventId',old.event_id));
 END IF;
 IF d='confirm' AND (SELECT count(*) FROM shared_expenses.members
   WHERE context_id=ctx AND member_id IN (report.payer_member_id,report.receiver_member_id)
     AND state='active' AND profile_id IS NOT NULL)<>2 THEN
   RAISE EXCEPTION 'settlement_member_not_authorized' USING ERRCODE='42501';
 END IF;
 IF d='confirm' AND NOT EXISTS(SELECT FROM shared_expenses.settings WHERE accepted_writes_enabled AND settlements_enabled) THEN RAISE EXCEPTION 'feature_disabled' USING ERRCODE='55000'; END IF;
 eid:=gen_random_uuid();
 INSERT INTO shared_expenses.settlement_events(context_id,settlement_id,event_id,actor_profile_id,kind,amount_minor,operation_id) VALUES(ctx,sid,eid,a,CASE WHEN d='confirm' THEN 'confirmed' ELSE 'rejected' END,report.amount_minor,p_operation_id);
 IF d='confirm' THEN
   low:=least(report.payer_member_id,report.receiver_member_id); high:=greatest(report.payer_member_id,report.receiver_member_id);
   SELECT balance_minor*CASE WHEN report.receiver_member_id=low THEN 1 ELSE -1 END INTO owed FROM shared_expenses.pair_balances WHERE context_id=ctx AND currency='INR' AND low_member_id=low AND high_member_id=high;
   applied:=least(report.amount_minor,greatest(coalesce(owed,0),0));
   amount:=report.amount_minor*CASE WHEN report.payer_member_id=low THEN 1 ELSE -1 END;
   PERFORM shared_expenses._post_pair(ctx,eid,0::smallint,low,high,amount,'settlement',sid);
   IF (SELECT coalesce(sum(abs(balance_minor::numeric)),0) FROM shared_expenses.pair_balances WHERE context_id=ctx)>9007199254740991 THEN RAISE EXCEPTION 'aggregate_limit_exceeded' USING ERRCODE='22003'; END IF;
   IF applied>0 THEN INSERT INTO shared_expenses.settlement_allocations(context_id,event_id,ordinal,amount_minor,kind) VALUES(ctx,eid,0,applied,'pair_balance'); END IF;
   IF report.amount_minor>applied THEN INSERT INTO shared_expenses.settlement_allocations(context_id,event_id,ordinal,amount_minor,kind) VALUES(ctx,eid,1,report.amount_minor-applied,'pair_credit'); END IF;
   -- This bounded foundation settles only the explicit pair/context balance.
   -- Expense-level allocation and mutual reversal remain separate gated commands;
   -- no payment is silently reassigned after an expense revision.
 END IF;
 seq:=shared_expenses._emit(ctx,CASE WHEN d='confirm' THEN 'settlement.confirmed' ELSE 'settlement.rejected' END,sid,jsonb_build_object('settlementId',sid,'eventId',eid,'payerMemberId',report.payer_member_id,'receiverMemberId',report.receiver_member_id,'amountMinor',report.amount_minor::text));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',CASE WHEN d='confirm' THEN 'confirmed' ELSE 'rejected' END,'settlementId',sid,'eventId',eid,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.transfer_owner(p_context uuid,p_member uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; t shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.operation_receipts
   WHERE actor_profile_id=a AND operation_id=p_operation AND command_kind='owner.transfer' AND context_id=p_context)
 THEN
  IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'owner.transfer',jsonb_build_object('contextId',p_context,'memberId',p_member),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO t FROM shared_expenses.members WHERE context_id=p_context AND member_id=p_member FOR UPDATE;
 IF NOT FOUND OR t.state<>'active' OR t.profile_id IS NULL OR t.profile_id=a THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='23505'; END IF;
 UPDATE shared_expenses.members SET role='member' WHERE context_id=p_context AND profile_id=a;
 UPDATE shared_expenses.members SET role='owner' WHERE context_id=p_context AND member_id=p_member;
 seq:=shared_expenses._emit(p_context,'member.owner_changed',p_member,jsonb_build_object('memberId',p_member,'status','owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','owner','memberId',p_member,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.take_over_ownership(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; me shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO me FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR me.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'owner.take_over',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO me FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR me.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 -- Only when no owner with a live account remains.
 IF EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND role='owner' AND state='active' AND profile_id IS NOT NULL)
 THEN RAISE EXCEPTION 'owner_still_present' USING ERRCODE='55000'; END IF;
 UPDATE shared_expenses.members SET role='member' WHERE context_id=p_context AND role='owner';
 UPDATE shared_expenses.members SET role='owner' WHERE context_id=p_context AND member_id=me.member_id;
 seq:=shared_expenses._emit(p_context,'member.owner_changed',me.member_id,jsonb_build_object('memberId',me.member_id,'status','owner'));
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','owner','memberId',me.member_id,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.leave_context(p_context uuid,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; m shared_expenses.members; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.operation_receipts
   WHERE actor_profile_id=a AND operation_id=p_operation AND command_kind='context.leave' AND context_id=p_context)
 THEN
  SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR m.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 END IF;
 r:=shared_expenses._operation(p_operation,p_hash,'context.leave',jsonb_build_object('contextId',p_context),p_context);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a;
 IF NOT FOUND OR m.state<>'active' THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
 IF m.role='owner' THEN RAISE EXCEPTION 'owner_cannot_leave' USING ERRCODE='55000'; END IF;
 IF EXISTS(
   SELECT FROM shared_expenses.pair_balances
   WHERE context_id=p_context AND m.member_id IN (low_member_id,high_member_id) AND balance_minor<>0
 ) OR EXISTS(
   SELECT FROM shared_expenses.settlement_reports sr
   WHERE sr.context_id=p_context AND m.member_id IN (sr.payer_member_id,sr.receiver_member_id)
     AND NOT EXISTS(SELECT FROM shared_expenses.settlement_events se
       WHERE se.context_id=sr.context_id AND se.settlement_id=sr.settlement_id
         AND se.kind IN ('confirmed','rejected'))
 ) OR EXISTS(
   SELECT FROM shared_expenses.revision_members rm
   JOIN shared_expenses.expense_revisions r USING(context_id,expense_id,revision_id)
   JOIN shared_expenses.expenses e USING(context_id,expense_id)
   WHERE rm.context_id=p_context AND rm.member_id=m.member_id AND rm.approval_required
     AND e.accepted_revision_id IS NOT DISTINCT FROM r.expected_head_revision_id
     AND NOT EXISTS(SELECT FROM shared_expenses.revision_approvals ra
       WHERE ra.context_id=r.context_id AND ra.revision_id=r.revision_id AND ra.decision='reject')
 )
 THEN RAISE EXCEPTION 'settle_first' USING ERRCODE='55000'; END IF;
 -- Emit while still active so the leaving person's own device receives the event.
 seq:=shared_expenses._emit(p_context,'membership.left',m.member_id,jsonb_build_object('memberId',m.member_id,'status','left'));
 UPDATE shared_expenses.members SET state='left' WHERE context_id=p_context AND member_id=m.member_id;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('status','left','memberId',m.member_id,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.submit_proposal(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; exp uuid; rev uuid; previous uuid; old shared_expenses.expenses; projected jsonb; r jsonb; h text; status text; seq bigint;
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload-'bill',ARRAY['contextId','expenseId','revisionId','expectedHeadRevisionId','snapshot','title','occurredOn','sources','void']) OR octet_length(p_payload::text)>65536 THEN RAISE EXCEPTION 'invalid_proposal' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; exp:=(p_payload->>'expenseId')::uuid; rev:=(p_payload->>'revisionId')::uuid; previous:=(p_payload->>'expectedHeadRevisionId')::uuid;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'expense.propose',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 IF ctx IS NULL OR exp IS NULL OR rev IS NULL OR jsonb_typeof(p_payload->'void')<>'boolean' OR jsonb_typeof(p_payload->'title')<>'string' OR length(btrim(p_payload->>'title')) NOT BETWEEN 1 AND 200 OR p_payload->>'occurredOn' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR jsonb_typeof(p_payload->'sources')<>'array' OR jsonb_array_length(p_payload->'sources')>8 THEN RAISE EXCEPTION 'invalid_proposal' USING ERRCODE='22023'; END IF;
 IF (p_payload->>'void')::boolean THEN
   IF p_payload->'snapshot'<>'null'::jsonb OR previous IS NULL OR jsonb_array_length(p_payload->'sources')<>0 THEN RAISE EXCEPTION 'invalid_void' USING ERRCODE='22023'; END IF;
   projected:=jsonb_build_object('currency','INR','totalMinor','0','positions','[]'::jsonb,'obligations','[]'::jsonb);
 ELSE projected:=shared_expenses._project_snapshot(p_payload->'snapshot'); END IF;
 IF p_payload ? 'bill' THEN
   IF (p_payload->>'void')::boolean THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
   PERFORM shared_expenses._validate_bill(p_payload->'bill',p_payload->'snapshot');
   IF EXISTS(SELECT FROM jsonb_array_elements(p_payload->'bill'->'contributions') p WHERE NOT EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=ctx AND m.member_id=(p->>'memberId')::uuid AND m.state IN ('active','invited'))) THEN RAISE EXCEPTION 'member_not_authorized' USING ERRCODE='42501'; END IF;
 END IF;
 INSERT INTO shared_expenses.expenses(context_id,expense_id,created_by) VALUES(ctx,exp,a) ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT old FROM shared_expenses.expenses WHERE context_id=ctx AND expense_id=exp FOR UPDATE;
 IF old.accepted_revision_id IS DISTINCT FROM previous THEN RAISE EXCEPTION 'revision_head_conflict' USING ERRCODE='40001'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx AND state IN ('active','invited'))>200 THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(projected->'positions') p WHERE NOT EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=ctx AND m.member_id=(p->>'memberId')::uuid AND m.state IN ('active','invited'))) THEN RAISE EXCEPTION 'member_not_authorized' USING ERRCODE='42501'; END IF;
 -- Funding references have a closed shape but remain unaccepted pending the
 -- source guard packet. No client alias/version is used as funding evidence.
 IF EXISTS(SELECT FROM jsonb_array_elements(p_payload->'sources') s WHERE NOT shared_expenses._closed(s,ARRAY['payerMemberId','amountMinor','reference']) OR jsonb_typeof(s->'payerMemberId') IS DISTINCT FROM 'string' OR s->>'payerMemberId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' OR jsonb_typeof(s->'amountMinor') IS DISTINCT FROM 'string' OR s->>'amountMinor' !~ '^[1-9][0-9]{0,9}$' OR (s->>'amountMinor')::bigint>1000000000 OR NOT shared_expenses._valid_source_reference(s->'reference')) THEN RAISE EXCEPTION 'invalid_source_link' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(p_payload->'sources') s LEFT JOIN shared_expenses.members m ON m.context_id=ctx AND m.member_id=(s->>'payerMemberId')::uuid WHERE m.profile_id IS NULL OR m.profile_id::text IS DISTINCT FROM s->'reference'->>'ownerAccountId') OR EXISTS(
   SELECT FROM (SELECT s->>'payerMemberId' payer,sum((s->>'amountMinor')::bigint) amount FROM jsonb_array_elements(p_payload->'sources') s GROUP BY s->>'payerMemberId') totals LEFT JOIN jsonb_array_elements(projected->'positions') p ON p->>'memberId'=totals.payer WHERE totals.amount>coalesce((p->>'paidMinor')::bigint,0)
 ) THEN RAISE EXCEPTION 'source_overallocated' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
 INSERT INTO shared_expenses.expense_revisions(context_id,expense_id,revision_id,author_profile_id,expected_head_revision_id,revision_hash,title,occurred_on,total_minor,is_void,snapshot,source_links,projected_edges,bill)
 VALUES(ctx,exp,rev,a,previous,h,btrim(p_payload->>'title'),(p_payload->>'occurredOn')::date,(projected->>'totalMinor')::bigint,(p_payload->>'void')::boolean,nullif(p_payload->'snapshot','null'::jsonb),p_payload->'sources',projected->'obligations',p_payload->'bill');
 -- Conservatively require every previously/newly involved identity to review
 -- the exact whole revision, including payer-only/excluded participants.
 INSERT INTO shared_expenses.revision_members(context_id,expense_id,revision_id,member_id,approver_profile_id,ordinal,paid_minor,share_minor,approval_required)
 SELECT ctx,exp,rev,m.member_id,m.profile_id,(row_number() OVER(ORDER BY m.member_id)-1)::smallint,
 coalesce((p.value->>'paidMinor')::bigint,0),coalesce((p.value->>'shareMinor')::bigint,0),
 coalesce((p.value->>'paidMinor')::bigint,0)>0 OR coalesce((p.value->>'shareMinor')::bigint,0)>0 OR coalesce(pm.paid_minor,0)>0 OR coalesce(pm.share_minor,0)>0 OR coalesce(pm.approval_required,false) OR EXISTS(SELECT FROM jsonb_array_elements(p_payload->'bill'->'contributions') f WHERE (f->>'memberId')::uuid=m.member_id)
 FROM shared_expenses.members m LEFT JOIN jsonb_array_elements(projected->'positions') p ON (p.value->>'memberId')::uuid=m.member_id LEFT JOIN shared_expenses.revision_members pm ON pm.context_id=ctx AND pm.revision_id=previous AND pm.member_id=m.member_id
 WHERE m.context_id=ctx AND (p.value IS NOT NULL OR pm.member_id IS NOT NULL OR EXISTS(SELECT FROM jsonb_array_elements(p_payload->'bill'->'contributions') f WHERE (f->>'memberId')::uuid=m.member_id));
 -- Author's explicit submit approves only their own identities; no friend is
 -- silently approved and account membership itself is never financial consent.
 INSERT INTO shared_expenses.revision_approvals(context_id,revision_id,member_id,actor_profile_id,revision_hash,decision,operation_id)
 SELECT ctx,rev,member_id,a,h,'approve',p_operation_id FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND approver_profile_id=a AND approval_required;
 status:=shared_expenses._accept_revision(ctx,exp,rev);
 seq:=shared_expenses._emit(ctx,CASE WHEN status='accepted' THEN 'expense.accepted' ELSE 'expense.proposed' END,rev,jsonb_build_object('expenseId',exp,'revisionId',rev,'status',status));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',status,'expenseId',exp,'revisionId',rev,'revisionHash',h,'sequence',seq::text));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses._project_snapshot(p_snapshot jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE row jsonb; total bigint; positions jsonb; edges jsonb; n int; BEGIN
 IF NOT shared_expenses._closed(p_snapshot,ARRAY['currency','totalMinor','contributions','shares','memberOrder']) OR (p_snapshot->>'currency') IS DISTINCT FROM 'INR' OR jsonb_typeof(p_snapshot->'totalMinor')<>'string' OR p_snapshot->>'totalMinor' !~ '^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'invalid_snapshot' USING ERRCODE='22023'; END IF;
 total:=(p_snapshot->>'totalMinor')::bigint;
 IF total>1000000000 OR jsonb_typeof(p_snapshot->'contributions')<>'array' OR jsonb_array_length(p_snapshot->'contributions') NOT BETWEEN 1 AND 8 OR jsonb_typeof(p_snapshot->'shares')<>'array' OR jsonb_array_length(p_snapshot->'shares') NOT BETWEEN 1 AND 50 OR jsonb_typeof(p_snapshot->'memberOrder')<>'array' OR jsonb_array_length(p_snapshot->'memberOrder') NOT BETWEEN 1 AND 58 THEN RAISE EXCEPTION 'invalid_snapshot' USING ERRCODE='22023'; END IF;
 FOR row IN SELECT value FROM jsonb_array_elements((p_snapshot->'contributions')||(p_snapshot->'shares')) LOOP
   IF NOT shared_expenses._closed(row,ARRAY['memberId','amountMinor']) OR jsonb_typeof(row->'memberId')<>'string' OR row->>'memberId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' OR jsonb_typeof(row->'amountMinor')<>'string' OR row->>'amountMinor' !~ '^(0|[1-9][0-9]{0,9})$' OR (row->>'amountMinor')::bigint>1000000000 THEN RAISE EXCEPTION 'invalid_snapshot' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(p_snapshot->'contributions') r GROUP BY r->>'memberId' HAVING count(*)>1) OR EXISTS(SELECT FROM jsonb_array_elements(p_snapshot->'shares') r GROUP BY r->>'memberId' HAVING count(*)>1) OR (SELECT sum((r->>'amountMinor')::bigint) FROM jsonb_array_elements(p_snapshot->'contributions') r)<>total OR (SELECT sum((r->>'amountMinor')::bigint) FROM jsonb_array_elements(p_snapshot->'shares') r)<>total THEN RAISE EXCEPTION 'snapshot_total_mismatch' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(p_snapshot->'memberOrder') r WHERE jsonb_typeof(r)<>'string' OR r#>>'{}' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') OR EXISTS(SELECT FROM jsonb_array_elements_text(p_snapshot->'memberOrder') r GROUP BY r HAVING count(*)>1) THEN RAISE EXCEPTION 'invalid_member_order' USING ERRCODE='22023'; END IF;
 SELECT count(DISTINCT r->>'memberId') INTO n FROM jsonb_array_elements((p_snapshot->'contributions')||(p_snapshot->'shares')) r;
 IF n<>jsonb_array_length(p_snapshot->'memberOrder') OR EXISTS(SELECT FROM jsonb_array_elements_text(p_snapshot->'memberOrder') o WHERE NOT EXISTS(SELECT FROM jsonb_array_elements((p_snapshot->'contributions')||(p_snapshot->'shares')) r WHERE r->>'memberId'=o)) THEN RAISE EXCEPTION 'invalid_member_order' USING ERRCODE='22023'; END IF;
 WITH paid AS(SELECT r->>'memberId' id,(r->>'amountMinor')::bigint amount FROM jsonb_array_elements(p_snapshot->'contributions') r), shares AS(SELECT r->>'memberId' id,(r->>'amountMinor')::bigint amount FROM jsonb_array_elements(p_snapshot->'shares') r)
 SELECT jsonb_agg(jsonb_build_object('memberId',coalesce(p.id,s.id),'paidMinor',coalesce(p.amount,0)::text,'shareMinor',coalesce(s.amount,0)::text,'balanceMinor',(coalesce(p.amount,0)-coalesce(s.amount,0))::text) ORDER BY coalesce(p.id,s.id)) INTO positions FROM paid p FULL JOIN shares s USING(id);
 WITH ordered AS(SELECT p.value->>'memberId' id,(p.value->>'balanceMinor')::bigint balance,o.ordinality rank FROM jsonb_array_elements(positions) p JOIN jsonb_array_elements_text(p_snapshot->'memberOrder') WITH ORDINALITY o(id,ordinality) ON o.id=p.value->>'memberId'),
 creditors AS(SELECT id,balance,sum(balance) OVER(ORDER BY rank)-balance start_at,sum(balance) OVER(ORDER BY rank) end_at FROM ordered WHERE balance>0),
 debtors AS(SELECT id,-balance amount,sum(-balance) OVER(ORDER BY rank)+balance start_at,sum(-balance) OVER(ORDER BY rank) end_at FROM ordered WHERE balance<0),
 edge_intervals AS(SELECT d.id debtor,c.id creditor,greatest(d.start_at,c.start_at) rank,least(d.end_at,c.end_at)-greatest(d.start_at,c.start_at) amount FROM debtors d CROSS JOIN creditors c WHERE least(d.end_at,c.end_at)>greatest(d.start_at,c.start_at))
 SELECT coalesce(jsonb_agg(jsonb_build_object('debtorId',debtor,'creditorId',creditor,'amountMinor',amount::bigint::text) ORDER BY rank),'[]'::jsonb) INTO edges FROM edge_intervals;
 RETURN jsonb_build_object('currency','INR','totalMinor',total::text,'positions',positions,'obligations',edges);
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
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=i.context_id AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id FOR UPDATE;
 IF i.state NOT IN ('open','awaiting_owner') OR i.expires_at<=clock_timestamp() OR p_approve IS NULL
 OR (p_approve AND i.claimed_profile_id IS NULL) THEN RAISE EXCEPTION 'invitation_conflict' USING ERRCODE='55000';END IF;
 IF p_approve THEN PERFORM shared_expenses._bind_invitation(p_id,i.claimed_profile_id);
 ELSE UPDATE shared_expenses.invitations SET state='rejected' WHERE invitation_id=p_id;
  IF i.via_group_link THEN UPDATE shared_expenses.members SET state='declined' WHERE context_id=i.context_id AND member_id=i.member_id AND profile_id IS NULL AND state='invited'; END IF;END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status',CASE WHEN p_approve THEN 'joined' ELSE 'rejected' END));
END $$;

CREATE OR REPLACE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=a AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 PERFORM shared_expenses._purge_lazy(a,NULL);
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',shared_expenses._clean_label(q.display_name),
  'status',CASE WHEN q.declined_at IS NOT NULL THEN 'declined' WHEN q.state IN ('open','awaiting_owner') AND q.expires_at<=clock_timestamp() THEN 'expired' ELSE q.state END,
  'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,
  'claimantName',NULLIF(shared_expenses._clean_label((SELECT p.display_name FROM public.profiles p WHERE p.id=q.claimed_profile_id)),''),
  'expiresAt',q.expires_at,'createdAt',q.created_at,'claimantPhone',shared_expenses._claimant_phone_json(q.inv,a)) ORDER BY q.created_at DESC,q.invitation_id DESC),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name,i AS inv FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR (i.created_at,i.invitation_id) <
   (SELECT anchor.created_at,anchor.invitation_id FROM shared_expenses.invitations anchor
    WHERE anchor.context_id=p_context AND anchor.invitation_id=p_after)) ORDER BY i.created_at DESC,i.invitation_id DESC LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;
