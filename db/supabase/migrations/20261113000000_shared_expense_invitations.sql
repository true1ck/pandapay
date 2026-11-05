-- Link secrets and phone lookup values are purpose-bound hashes from the API.
-- Joining never approves expenses, changes allocations or posts money.
CREATE TABLE shared_expenses.invitations (
 invitation_id uuid PRIMARY KEY, context_id uuid NOT NULL, member_id uuid NOT NULL,
 issuer_profile_id uuid NOT NULL, token_hash text NOT NULL UNIQUE CHECK(token_hash~'^[a-f0-9]{64}$'),
 target_phone_hash text CHECK(target_phone_hash~'^[a-f0-9]{64}$'),
 claimed_profile_id uuid, verified_phone_suffix text CHECK(verified_phone_suffix~'^[0-9]{4}$'),
 state text NOT NULL DEFAULT 'open' CHECK(state IN ('open','awaiting_owner','joined','rejected')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '7 days',
 FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE INDEX shared_invitations_context_page ON shared_expenses.invitations(context_id,invitation_id);
CREATE INDEX shared_invitations_sender_rate ON shared_expenses.invitations(issuer_profile_id,created_at DESC);
CREATE TABLE shared_expenses.member_identity_bindings (
 context_id uuid NOT NULL, member_id uuid NOT NULL, profile_id uuid NOT NULL,
 invitation_id uuid NOT NULL REFERENCES shared_expenses.invitations(invitation_id),
 bound_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(context_id,member_id),UNIQUE(context_id,profile_id),
 FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
ALTER TABLE shared_expenses.invitations OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.member_identity_bindings OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.invitations FORCE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.member_identity_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.member_identity_bindings FORCE ROW LEVEL SECURITY;
CREATE POLICY invitation_owner ON shared_expenses.invitations FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
CREATE POLICY binding_owner ON shared_expenses.member_identity_bindings FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true);
REVOKE ALL ON shared_expenses.invitations,shared_expenses.member_identity_bindings FROM PUBLIC,app_user;

CREATE FUNCTION shared_expenses._bind_invitation(p_id uuid,p_actor uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE i shared_expenses.invitations; m shared_expenses.members; BEGIN
 SELECT * INTO STRICT i FROM shared_expenses.invitations WHERE invitation_id=p_id;
 SELECT * INTO STRICT m FROM shared_expenses.members WHERE context_id=i.context_id AND member_id=i.member_id;
 IF m.state<>'invited' OR (m.profile_id IS NOT NULL AND m.profile_id<>p_actor)
 OR EXISTS(SELECT FROM shared_expenses.members WHERE context_id=i.context_id AND profile_id=p_actor AND member_id<>i.member_id)
 OR EXISTS(SELECT FROM shared_expenses.member_identity_bindings WHERE context_id=i.context_id AND member_id=i.member_id)
 THEN RAISE EXCEPTION 'invitation_conflict' USING ERRCODE='55000'; END IF;
 INSERT INTO shared_expenses.member_identity_bindings(context_id,member_id,profile_id,invitation_id) VALUES(i.context_id,i.member_id,p_actor,p_id);
 UPDATE shared_expenses.members SET profile_id=p_actor,state='active' WHERE context_id=i.context_id AND member_id=i.member_id;
 UPDATE shared_expenses.invitations SET state='joined' WHERE invitation_id=p_id;
 PERFORM shared_expenses._emit(i.context_id,'membership.claimed',i.member_id,jsonb_build_object('memberId',i.member_id,'status','joined'));
END $$;

CREATE FUNCTION shared_expenses.create_invitation(p jsonb,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); id uuid:=(p->>'invitationId')::uuid; ctx uuid:=(p->>'contextId')::uuid; mid uuid:=(p->>'memberId')::uuid; r jsonb; expiry timestamptz; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND profile_id=a AND role='owner' AND state='active') THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(id,p_hash,'invitation.create',p,ctx);IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000';END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND member_id=mid AND state='invited' AND profile_id IS NULL)
 THEN RAISE EXCEPTION 'invitation_conflict' USING ERRCODE='55000';END IF;
 IF (SELECT count(*) FROM (SELECT 1 FROM shared_expenses.invitations WHERE issuer_profile_id=a AND created_at>clock_timestamp()-interval '1 hour' LIMIT 50) q)>=50
 THEN RAISE EXCEPTION 'invitation_rate_limited' USING ERRCODE='55000'; END IF;
 -- One outstanding link per person. Replays of the same ID return above;
 -- replacing a link invalidates every earlier token without changing the member.
 UPDATE shared_expenses.invitations SET state='rejected' WHERE context_id=ctx AND member_id=mid AND state IN ('open','awaiting_owner');
 INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,target_phone_hash)
 VALUES(id,ctx,mid,a,p->>'tokenHash',p->>'targetPhoneHash') RETURNING expires_at INTO expiry;
 RETURN shared_expenses._finish(id,jsonb_build_object('invitationId',id,'contextId',ctx,'memberId',mid,'status','open','expiresAt',expiry));
END $$;

CREATE FUNCTION shared_expenses.preview_invitation(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE i shared_expenses.invitations; BEGIN
 PERFORM shared_expenses._actor();PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND OR i.state='rejected' OR i.expires_at<=clock_timestamp()
 OR NOT EXISTS(SELECT FROM shared_expenses.contexts WHERE context_id=i.context_id AND state='active')
 THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('invitationId',i.invitation_id,'contextId',i.context_id,'memberId',i.member_id,
 'contextName',(SELECT name FROM shared_expenses.contexts WHERE context_id=i.context_id),
 'memberName',(SELECT display_name FROM shared_expenses.members WHERE context_id=i.context_id AND member_id=i.member_id),
 'phoneBound',i.target_phone_hash IS NOT NULL,'status',i.state,'expiresAt',i.expires_at);
END $$;

CREATE FUNCTION shared_expenses.claim_invitation(p_token text,p_phone text,p_suffix text,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor();i shared_expenses.invitations;r jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 SELECT * INTO i FROM shared_expenses.invitations WHERE token_hash=p_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE='42501';END IF;
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

CREATE FUNCTION shared_expenses.respond_invitation(p_id uuid,p_approve boolean,p_operation uuid,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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
 ELSE UPDATE shared_expenses.invitations SET state='rejected' WHERE invitation_id=p_id;END IF;
 RETURN shared_expenses._finish(p_operation,jsonb_build_object('contextId',i.context_id,'memberId',i.member_id,'status',CASE WHEN p_approve THEN 'joined' ELSE 'rejected' END));
END $$;

CREATE FUNCTION shared_expenses.list_invitations(p_context uuid,p_after uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ DECLARE rows jsonb;BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=shared_expenses._actor() AND role='owner' AND state='active')
 THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('invitationId',q.invitation_id,'memberId',q.member_id,'memberName',q.display_name,'status',q.state,'phoneBound',q.target_phone_hash IS NOT NULL,'verifiedPhoneSuffix',q.verified_phone_suffix,'expiresAt',q.expires_at) ORDER BY q.invitation_id),'[]'::jsonb) INTO rows
 FROM (SELECT i.*,m.display_name FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.context_id=p_context AND (p_after IS NULL OR i.invitation_id>p_after) ORDER BY i.invitation_id LIMIT 51) q;
 RETURN jsonb_build_object('items',CASE WHEN jsonb_array_length(rows)>50 THEN rows-50 ELSE rows END,'hasMore',jsonb_array_length(rows)>50,'nextCursor',CASE WHEN jsonb_array_length(rows)>50 THEN rows->49->>'invitationId' ELSE NULL END);
END $$;

-- A formerly unregistered member keeps the same member ID and every historical
-- revision. Identity binding supplies only the missing reviewer; it is never an
-- approval. Every financially affected person must still approve the exact hash.
CREATE FUNCTION shared_expenses._review_profile(p_context uuid,p_member uuid,p_frozen uuid) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
 SELECT CASE WHEN shared_expenses._can_read_context(p_context) THEN coalesce(p_frozen,(SELECT b.profile_id FROM shared_expenses.member_identity_bindings b JOIN shared_expenses.members m USING(context_id,member_id) WHERE b.context_id=p_context AND b.member_id=p_member AND m.profile_id=b.profile_id AND m.state='active')) ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION shared_expenses._can_read_revision(p_context uuid,p_revision uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
 SELECT shared_expenses._can_read_context(p_context) AND EXISTS(SELECT FROM shared_expenses.expense_revisions r WHERE r.context_id=p_context AND r.revision_id=p_revision AND (r.author_profile_id=pandapay.uid() OR EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id)=pandapay.uid()) OR EXISTS(SELECT FROM shared_expenses.expenses e WHERE e.context_id=p_context AND e.expense_id=r.expense_id AND e.accepted_revision_id=p_revision)))
$$;

CREATE OR REPLACE FUNCTION shared_expenses._accept_revision(p_context uuid,p_expense uuid,p_revision uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE e shared_expenses.expenses; r shared_expenses.expense_revisions; old_edges jsonb:='[]'; line record; no smallint:=0; BEGIN
 SELECT * INTO STRICT e FROM shared_expenses.expenses WHERE context_id=p_context AND expense_id=p_expense FOR UPDATE;
 SELECT * INTO STRICT r FROM shared_expenses.expense_revisions WHERE context_id=p_context AND expense_id=p_expense AND revision_id=p_revision;
 IF e.accepted_revision_id=p_revision THEN RETURN 'accepted'; END IF;
 IF e.accepted_revision_id IS DISTINCT FROM r.expected_head_revision_id THEN RAISE EXCEPTION 'revision_head_conflict' USING ERRCODE='40001'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND m.approval_required AND (shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id) IS NULL OR NOT EXISTS(SELECT FROM shared_expenses.revision_approvals a WHERE a.context_id=m.context_id AND a.revision_id=m.revision_id AND a.member_id=m.member_id AND a.actor_profile_id=shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id) AND a.revision_hash=r.revision_hash AND a.decision='approve'))) THEN RETURN 'awaiting_approval'; END IF;
 IF NOT EXISTS(SELECT FROM shared_expenses.settings WHERE accepted_writes_enabled) THEN RETURN 'awaiting_activation'; END IF;
 -- Source-linked proposals are durable but never funded until the source writer
 -- guard / reservation transaction is independently verified and integrated.
 IF jsonb_array_length(r.source_links)>0 THEN RETURN 'awaiting_source_authorization'; END IF;
 IF e.accepted_revision_id IS NOT NULL THEN SELECT projected_edges INTO old_edges FROM shared_expenses.expense_revisions WHERE context_id=p_context AND expense_id=p_expense AND revision_id=e.accepted_revision_id; END IF;
 FOR line IN WITH signed_edges AS(
   SELECT value edge,1 sign FROM jsonb_array_elements(r.projected_edges)
   UNION ALL SELECT value,-1 FROM jsonb_array_elements(old_edges)
 ), normalized AS(SELECT least((edge->>'debtorId')::uuid,(edge->>'creditorId')::uuid) low,greatest((edge->>'debtorId')::uuid,(edge->>'creditorId')::uuid) high,(edge->>'amountMinor')::bigint*sign*CASE WHEN (edge->>'creditorId')::uuid<(edge->>'debtorId')::uuid THEN 1 ELSE -1 END amount FROM signed_edges)
 SELECT low,high,sum(amount)::bigint amount FROM normalized GROUP BY low,high HAVING sum(amount)<>0 ORDER BY low,high LOOP
   PERFORM shared_expenses._post_pair(p_context,p_revision,no,line.low,line.high,line.amount,'revision',p_revision); no:=no+1;
 END LOOP;
 IF (SELECT coalesce(sum(abs(balance_minor::numeric)),0) FROM shared_expenses.pair_balances WHERE context_id=p_context)>9007199254740991 THEN RAISE EXCEPTION 'aggregate_limit_exceeded' USING ERRCODE='22003'; END IF;
 INSERT INTO shared_expenses.obligation_edges(context_id,revision_id,edge_no,debtor_member_id,creditor_member_id,amount_minor) SELECT p_context,p_revision,(ordinality-1)::smallint,(value->>'debtorId')::uuid,(value->>'creditorId')::uuid,(value->>'amountMinor')::bigint FROM jsonb_array_elements(r.projected_edges) WITH ORDINALITY;
 UPDATE shared_expenses.expenses SET accepted_revision_id=p_revision,head_version=head_version+1 WHERE context_id=p_context AND expense_id=p_expense;
 -- Personal cost is a separate private fact; neither bank debit nor rewards
 -- is rewritten. Old paid payments are independent immutable events.
 DELETE FROM shared_expenses.private_cost_facts WHERE context_id=p_context AND expense_id=p_expense;
 INSERT INTO shared_expenses.private_cost_facts(profile_id,context_id,expense_id,revision_id,member_id,currency,share_minor,source_linked_minor,occurred_on)
 SELECT shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id),p_context,p_expense,p_revision,m.member_id,'INR',m.share_minor,0,r.occurred_on FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id) IS NOT NULL;
 RETURN 'accepted';
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
 SELECT * INTO r FROM shared_expenses.expense_revisions WHERE context_id=ctx AND expense_id=exp AND revision_id=rev;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND shared_expenses._review_profile(context_id,member_id,approver_profile_id)=a AND approval_required) THEN RAISE EXCEPTION 'revision_not_authorized' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_approvals WHERE context_id=ctx AND revision_id=rev AND actor_profile_id=a AND decision<>d) THEN RAISE EXCEPTION 'approval_conflict' USING ERRCODE='55000'; END IF;
 INSERT INTO shared_expenses.revision_approvals(context_id,revision_id,member_id,actor_profile_id,revision_hash,decision,operation_id)
 SELECT ctx,rev,member_id,a,r.revision_hash,d,p_operation_id FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND shared_expenses._review_profile(context_id,member_id,approver_profile_id)=a AND approval_required ON CONFLICT DO NOTHING;
 IF d='reject' THEN status:='rejected'; ELSE status:=shared_expenses._accept_revision(ctx,exp,rev); END IF;
 seq:=shared_expenses._emit(ctx,CASE WHEN status='accepted' THEN 'expense.accepted' ELSE 'expense.responded' END,rev,jsonb_build_object('expenseId',exp,'revisionId',rev,'status',status));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',status,'expenseId',exp,'revisionId',rev,'sequence',seq::text));
END $$;

ALTER FUNCTION shared_expenses._bind_invitation(uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.create_invitation(jsonb,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.preview_invitation(text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.claim_invitation(text,text,text,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.respond_invitation(uuid,boolean,uuid,text) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.list_invitations(uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._review_profile(uuid,uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._can_read_revision(uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses._accept_revision(uuid,uuid,uuid) OWNER TO shared_expenses_owner;
ALTER FUNCTION shared_expenses.respond_expense(jsonb,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._bind_invitation(uuid,uuid),shared_expenses.create_invitation(jsonb,text),shared_expenses.preview_invitation(text),shared_expenses.claim_invitation(text,text,text,uuid,text),shared_expenses.respond_invitation(uuid,boolean,uuid,text),shared_expenses.list_invitations(uuid,uuid),shared_expenses._review_profile(uuid,uuid,uuid) FROM PUBLIC,app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.create_invitation(jsonb,text),shared_expenses.preview_invitation(text),shared_expenses.claim_invitation(text,text,text,uuid,text),shared_expenses.respond_invitation(uuid,boolean,uuid,text),shared_expenses.list_invitations(uuid,uuid),shared_expenses._review_profile(uuid,uuid,uuid) TO app_user;
