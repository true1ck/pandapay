-- Full bill metadata is immutable consent data; old revisions remain unknown.
ALTER TABLE shared_expenses.expense_revisions ADD COLUMN bill jsonb;
GRANT SELECT(bill) ON shared_expenses.expense_revisions TO app_user;

CREATE FUNCTION shared_expenses._validate_bill(b jsonb,s jsonb) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE allocation jsonb; mode text; total bigint; shared bigint; weight_total numeric; actual jsonb; expected jsonb; row jsonb;
BEGIN
 IF NOT coalesce(shared_expenses._closed(b,ARRAY['currency','totalMinor','contributions','allocation']),false)
   OR b->>'currency' IS DISTINCT FROM 'INR' OR jsonb_typeof(b->'totalMinor') IS DISTINCT FROM 'string'
   OR b->>'totalMinor' !~ '^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 total:=(b->>'totalMinor')::bigint; shared:=(s->>'totalMinor')::bigint;
 IF total>1000000000 OR total<shared OR jsonb_typeof(b->'contributions') IS DISTINCT FROM 'array'
   OR jsonb_array_length(b->'contributions') NOT BETWEEN 1 AND 8 THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(b->'contributions') LOOP
  IF NOT coalesce(shared_expenses._closed(row,ARRAY['memberId','amountMinor']),false)
    OR jsonb_typeof(row->'memberId') IS DISTINCT FROM 'string' OR row->>'memberId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    OR jsonb_typeof(row->'amountMinor') IS DISTINCT FROM 'string' OR row->>'amountMinor' !~ '^[1-9][0-9]{0,9}$'
    OR (row->>'amountMinor')::bigint>1000000000 THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF (SELECT count(*)<>count(DISTINCT value->>'memberId') OR sum((value->>'amountMinor')::bigint)<>total FROM jsonb_array_elements(b->'contributions'))
   OR EXISTS(SELECT FROM jsonb_array_elements(s->'contributions') p LEFT JOIN jsonb_array_elements(b->'contributions') f ON f->>'memberId'=p->>'memberId' WHERE coalesce((f->>'amountMinor')::bigint,0)<(p->>'amountMinor')::bigint)
   THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 allocation:=b->'allocation'; mode:=allocation->>'mode';
 IF NOT coalesce(shared_expenses._closed(allocation,ARRAY['mode','participants','tieOrder']),false)
   OR mode IS NULL OR mode NOT IN ('equal','exact','percentage','shares')
   OR jsonb_typeof(allocation->'participants') IS DISTINCT FROM 'array' OR jsonb_array_length(allocation->'participants') NOT BETWEEN 1 AND 50
   OR jsonb_typeof(allocation->'tieOrder') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(allocation->'participants') LOOP
  IF NOT coalesce(shared_expenses._closed(row,CASE mode WHEN 'equal' THEN ARRAY['memberId'] WHEN 'exact' THEN ARRAY['memberId','amountMinor'] ELSE ARRAY['memberId','weight'] END),false)
    OR jsonb_typeof(row->'memberId') IS DISTINCT FROM 'string' OR row->>'memberId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
  IF mode='exact' AND (jsonb_typeof(row->'amountMinor') IS DISTINCT FROM 'string' OR row->>'amountMinor' !~ '^(0|[1-9][0-9]{0,9})$' OR (row->>'amountMinor')::bigint>1000000000)
    THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
  IF mode IN ('percentage','shares') AND (jsonb_typeof(row->'weight') IS DISTINCT FROM 'string' OR row->>'weight' !~ '^(0|[1-9][0-9]{0,6})$' OR (row->>'weight')::bigint>CASE mode WHEN 'percentage' THEN 10000 ELSE 1000000 END)
    THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF (SELECT count(*)<>count(DISTINCT value->>'memberId') FROM jsonb_array_elements(allocation->'participants'))
   OR jsonb_array_length(allocation->'tieOrder')<>jsonb_array_length(allocation->'participants')
   OR (SELECT count(*)<>count(DISTINCT value) FROM jsonb_array_elements(allocation->'tieOrder'))
   OR EXISTS(SELECT FROM jsonb_array_elements(allocation->'tieOrder') t WHERE jsonb_typeof(t) IS DISTINCT FROM 'string' OR NOT EXISTS(SELECT FROM jsonb_array_elements(allocation->'participants') p WHERE p->'memberId'=t))
   THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 SELECT sum(CASE mode WHEN 'equal' THEN 1 WHEN 'exact' THEN (value->>'amountMinor')::numeric ELSE (value->>'weight')::numeric END) INTO weight_total FROM jsonb_array_elements(allocation->'participants');
 IF weight_total<=0 OR (mode='percentage' AND weight_total<>10000) OR (mode='exact' AND weight_total<>shared)
   THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
 WITH weights AS (
   SELECT p->>'memberId' id,CASE mode WHEN 'equal' THEN 1 WHEN 'exact' THEN (p->>'amountMinor')::numeric ELSE (p->>'weight')::numeric END weight,t.ordinality rank
   FROM jsonb_array_elements(allocation->'participants') p JOIN jsonb_array_elements(allocation->'tieOrder') WITH ORDINALITY t(value,ordinality) ON p->'memberId'=t.value
 ), bases AS (
   SELECT *,CASE WHEN mode='exact' THEN weight ELSE floor(shared*weight/weight_total) END amount,
     CASE WHEN mode='exact' THEN 0 ELSE mod(shared*weight,weight_total) END remainder FROM weights
 ), ranked AS (
   SELECT *,row_number() OVER(ORDER BY remainder DESC,rank) remainder_rank,shared-sum(amount) OVER() leftover FROM bases
 ) SELECT jsonb_object_agg(id,(amount+CASE WHEN remainder_rank<=leftover THEN 1 ELSE 0 END)::bigint::text) INTO actual FROM ranked;
 SELECT jsonb_object_agg(value->>'memberId',value->>'amountMinor') INTO expected FROM jsonb_array_elements(s->'shares');
 IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023'; END IF;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
 RAISE EXCEPTION 'invalid_bill' USING ERRCODE='22023';
END $$;
ALTER FUNCTION shared_expenses._validate_bill(jsonb,jsonb) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._validate_bill(jsonb,jsonb) FROM PUBLIC,app_user;

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
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx)>200 THEN RAISE EXCEPTION 'context_member_limit' USING ERRCODE='22023'; END IF;
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
ALTER FUNCTION shared_expenses.submit_proposal(jsonb,uuid,text) OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses.submit_proposal(jsonb,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION shared_expenses.submit_proposal(jsonb,uuid,text) TO app_user;
