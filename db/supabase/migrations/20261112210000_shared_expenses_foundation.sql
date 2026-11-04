-- Additive shared-obligation boundary. The existing personal bank ledger and
-- legacy category splits are untouched. Flags remain off until integration gates.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='shared_expenses_owner') THEN
    CREATE ROLE shared_expenses_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
  ELSIF EXISTS(SELECT FROM pg_roles WHERE rolname='shared_expenses_owner' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolreplication)) THEN
    RAISE EXCEPTION 'unsafe_shared_expenses_owner';
  END IF;
END $$;
CREATE SCHEMA shared_expenses AUTHORIZATION shared_expenses_owner;
REVOKE ALL ON SCHEMA shared_expenses FROM PUBLIC;
GRANT USAGE ON SCHEMA shared_expenses TO app_user;
GRANT USAGE ON SCHEMA public,pandapay TO shared_expenses_owner;
GRANT EXECUTE ON FUNCTION pandapay.uid() TO shared_expenses_owner;
GRANT SELECT ON public.profiles,public.transactions,public.sms_v2_events,public.sms_v2_ledger_entries,public.sms_v2_instruments,public.foreign_payments TO shared_expenses_owner;

CREATE TABLE shared_expenses.settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  reads_enabled boolean NOT NULL DEFAULT false,
  proposals_enabled boolean NOT NULL DEFAULT false,
  accepted_writes_enabled boolean NOT NULL DEFAULT false,
  settlements_enabled boolean NOT NULL DEFAULT false,
  source_guards_enabled boolean NOT NULL DEFAULT false
);
INSERT INTO shared_expenses.settings(singleton) VALUES(true);
CREATE TABLE shared_expenses.contexts (
  context_id uuid PRIMARY KEY,
  kind text NOT NULL CHECK(kind IN ('group','direct')),
  name text NOT NULL CHECK(length(name) BETWEEN 1 AND 120),
  created_by uuid NOT NULL,
  currency text NOT NULL DEFAULT 'INR' CHECK(currency='INR'),
  state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','archived')),
  committed_sequence bigint NOT NULL DEFAULT 0 CHECK(committed_sequence BETWEEN 0 AND 9007199254740991),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE shared_expenses.members (
  context_id uuid NOT NULL REFERENCES shared_expenses.contexts(context_id),
  member_id uuid NOT NULL,
  profile_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  role text NOT NULL CHECK(role IN ('owner','member')),
  state text NOT NULL CHECK(state IN ('invited','active','declined','left','erased')),
  display_name text CHECK(length(display_name) BETWEEN 1 AND 120),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,member_id),
  UNIQUE(context_id,profile_id)
);
CREATE INDEX shared_members_profile ON shared_expenses.members(profile_id,context_id) WHERE profile_id IS NOT NULL;
CREATE TABLE shared_expenses.expenses (
  context_id uuid NOT NULL REFERENCES shared_expenses.contexts(context_id),
  expense_id uuid NOT NULL,
  created_by uuid NOT NULL,
  accepted_revision_id uuid,
  head_version bigint NOT NULL DEFAULT 0 CHECK(head_version BETWEEN 0 AND 9007199254740991),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,expense_id)
);
CREATE INDEX shared_expenses_context_page ON shared_expenses.expenses(context_id,created_at DESC,expense_id DESC);
CREATE INDEX shared_expenses_accepted_head ON shared_expenses.expenses(context_id,accepted_revision_id) WHERE accepted_revision_id IS NOT NULL;
CREATE TABLE shared_expenses.expense_revisions (
  context_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  author_profile_id uuid NOT NULL,
  expected_head_revision_id uuid,
  revision_hash text NOT NULL CHECK(revision_hash ~ '^[a-f0-9]{64}$'),
  projection_version text NOT NULL DEFAULT 'pair_v1' CHECK(projection_version='pair_v1'),
  title text NOT NULL CHECK(length(title) BETWEEN 1 AND 200),
  occurred_on date NOT NULL,
  currency text NOT NULL DEFAULT 'INR' CHECK(currency='INR'),
  total_minor bigint NOT NULL CHECK(total_minor BETWEEN 0 AND 1000000000),
  is_void boolean NOT NULL DEFAULT false,
  snapshot jsonb,
  source_links jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(source_links)='array' AND jsonb_array_length(source_links)<=8),
  projected_edges jsonb NOT NULL CHECK(jsonb_typeof(projected_edges)='array' AND jsonb_array_length(projected_edges)<=57),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,expense_id,revision_id),
  UNIQUE(context_id,revision_id),
  FOREIGN KEY(context_id,expense_id) REFERENCES shared_expenses.expenses(context_id,expense_id),
  CHECK((is_void AND snapshot IS NULL AND total_minor=0) OR (NOT is_void AND snapshot IS NOT NULL AND total_minor>0))
);
ALTER TABLE shared_expenses.expenses ADD CONSTRAINT shared_accepted_revision_fk FOREIGN KEY(context_id,expense_id,accepted_revision_id) REFERENCES shared_expenses.expense_revisions(context_id,expense_id,revision_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE shared_expenses.revision_members (
  context_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  member_id uuid NOT NULL,
  approver_profile_id uuid,
  ordinal smallint NOT NULL CHECK(ordinal BETWEEN 0 AND 199),
  paid_minor bigint NOT NULL CHECK(paid_minor BETWEEN 0 AND 1000000000),
  share_minor bigint NOT NULL CHECK(share_minor BETWEEN 0 AND 1000000000),
  approval_required boolean NOT NULL,
  PRIMARY KEY(context_id,revision_id,member_id),
  FOREIGN KEY(context_id,expense_id,revision_id) REFERENCES shared_expenses.expense_revisions(context_id,expense_id,revision_id),
  FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE INDEX shared_revision_review_profile ON shared_expenses.revision_members(approver_profile_id,context_id,revision_id) WHERE approval_required AND approver_profile_id IS NOT NULL;
CREATE TABLE shared_expenses.revision_approvals (
  context_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  member_id uuid NOT NULL,
  actor_profile_id uuid NOT NULL,
  revision_hash text NOT NULL CHECK(revision_hash ~ '^[a-f0-9]{64}$'),
  decision text NOT NULL CHECK(decision IN ('approve','reject')),
  operation_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,revision_id,member_id),
  FOREIGN KEY(context_id,revision_id,member_id) REFERENCES shared_expenses.revision_members(context_id,revision_id,member_id)
);
CREATE TABLE shared_expenses.source_resources (
  resource_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_profile_id uuid NOT NULL,
  canonical_transaction_id uuid NOT NULL,
  source_version text NOT NULL CHECK(source_version ~ '^[a-f0-9]{64}$'),
  eligible_minor bigint NOT NULL CHECK(eligible_minor BETWEEN 1 AND 1000000000),
  currency text NOT NULL DEFAULT 'INR' CHECK(currency='INR'),
  state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','retracted','review')),
  private_snapshot jsonb NOT NULL,
  UNIQUE(owner_profile_id,canonical_transaction_id),
  UNIQUE(resource_id,owner_profile_id)
);
CREATE TABLE shared_expenses.source_aliases (
  owner_profile_id uuid NOT NULL,
  kind text NOT NULL CHECK(kind IN ('legacy_transaction','sms_v2_event','confirmed_foreign_payment')),
  alias_id text NOT NULL CHECK(length(alias_id) BETWEEN 1 AND 128),
  resource_id uuid NOT NULL,
  PRIMARY KEY(owner_profile_id,kind,alias_id),
  FOREIGN KEY(resource_id,owner_profile_id) REFERENCES shared_expenses.source_resources(resource_id,owner_profile_id)
);
CREATE TABLE shared_expenses.source_reservations (
  resource_id uuid NOT NULL REFERENCES shared_expenses.source_resources(resource_id),
  context_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  payer_member_id uuid NOT NULL,
  amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 1 AND 1000000000),
  source_version text NOT NULL CHECK(source_version ~ '^[a-f0-9]{64}$'),
  state text NOT NULL CHECK(state IN ('proposed','accepted','released','review')),
  PRIMARY KEY(resource_id,context_id,expense_id,revision_id),
  FOREIGN KEY(context_id,expense_id,revision_id) REFERENCES shared_expenses.expense_revisions(context_id,expense_id,revision_id),
  FOREIGN KEY(context_id,payer_member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE INDEX shared_source_reservation_active ON shared_expenses.source_reservations(resource_id) WHERE state IN ('proposed','accepted','review');
CREATE TABLE shared_expenses.settlement_reports (
  context_id uuid NOT NULL REFERENCES shared_expenses.contexts(context_id),
  settlement_id uuid NOT NULL,
  reporter_profile_id uuid NOT NULL,
  payer_member_id uuid NOT NULL,
  receiver_member_id uuid NOT NULL,
  amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 1 AND 1000000000),
  currency text NOT NULL CHECK(currency='INR'),
  method text NOT NULL CHECK(method IN ('upi','cash','bank')),
  paid_on date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,settlement_id),
  FOREIGN KEY(context_id,payer_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  FOREIGN KEY(context_id,receiver_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  CHECK(payer_member_id<>receiver_member_id)
);
CREATE INDEX shared_settlement_report_page ON shared_expenses.settlement_reports(context_id,created_at DESC,settlement_id DESC);
-- Optional bank/UPI references are private and erasable. They are separate
-- from immutable financial report/payment facts and never appear in a feed.
CREATE TABLE shared_expenses.settlement_private_references (
  context_id uuid NOT NULL,
  settlement_id uuid NOT NULL,
  owner_profile_id uuid NOT NULL,
  reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 128),
  PRIMARY KEY(context_id,settlement_id),
  FOREIGN KEY(context_id,settlement_id) REFERENCES shared_expenses.settlement_reports(context_id,settlement_id)
);
CREATE INDEX shared_settlement_private_owner ON shared_expenses.settlement_private_references(owner_profile_id,context_id,settlement_id);
CREATE TABLE shared_expenses.settlement_events (
  context_id uuid NOT NULL,
  settlement_id uuid NOT NULL,
  event_id uuid NOT NULL DEFAULT gen_random_uuid(),
  actor_profile_id uuid NOT NULL,
  kind text NOT NULL CHECK(kind IN ('confirmed','rejected','reversed')),
  original_event_id uuid,
  amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 1 AND 1000000000),
  operation_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,event_id),
  UNIQUE(context_id,settlement_id,kind),
  FOREIGN KEY(context_id,settlement_id) REFERENCES shared_expenses.settlement_reports(context_id,settlement_id)
);
CREATE UNIQUE INDEX shared_settlement_terminal ON shared_expenses.settlement_events(context_id,settlement_id) WHERE kind IN ('confirmed','rejected');
CREATE TABLE shared_expenses.journal_entries (
  context_id uuid NOT NULL REFERENCES shared_expenses.contexts(context_id),
  effect_id uuid NOT NULL,
  line_no smallint NOT NULL CHECK(line_no BETWEEN 0 AND 399),
  currency text NOT NULL CHECK(currency='INR'),
  low_member_id uuid NOT NULL,
  high_member_id uuid NOT NULL CHECK(high_member_id > low_member_id),
  balance_minor bigint NOT NULL CHECK(balance_minor BETWEEN -9007199254740991 AND 9007199254740991 AND balance_minor<>0),
  kind text NOT NULL CHECK(kind IN ('revision','settlement','settlement_reversal')),
  origin_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,effect_id,line_no),
  FOREIGN KEY(context_id,low_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  FOREIGN KEY(context_id,high_member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE INDEX shared_journal_origin ON shared_expenses.journal_entries(context_id,origin_id,low_member_id,high_member_id);
CREATE TABLE shared_expenses.obligation_edges (
  context_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  edge_no smallint NOT NULL CHECK(edge_no BETWEEN 0 AND 56),
  debtor_member_id uuid NOT NULL,
  creditor_member_id uuid NOT NULL,
  amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 1 AND 1000000000),
  PRIMARY KEY(context_id,revision_id,edge_no),
  FOREIGN KEY(context_id,revision_id) REFERENCES shared_expenses.expense_revisions(context_id,revision_id),
  FOREIGN KEY(context_id,debtor_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  FOREIGN KEY(context_id,creditor_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  CHECK(debtor_member_id<>creditor_member_id)
);
CREATE TABLE shared_expenses.settlement_allocations (
  context_id uuid NOT NULL,
  event_id uuid NOT NULL,
  ordinal smallint NOT NULL CHECK(ordinal BETWEEN 0 AND 100),
  revision_id uuid,
  edge_no smallint,
  amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 1 AND 1000000000),
  kind text NOT NULL CHECK(kind IN ('obligation','pair_balance','pair_credit')),
  PRIMARY KEY(context_id,event_id,ordinal),
  FOREIGN KEY(context_id,event_id) REFERENCES shared_expenses.settlement_events(context_id,event_id),
  FOREIGN KEY(context_id,revision_id,edge_no) REFERENCES shared_expenses.obligation_edges(context_id,revision_id,edge_no),
  CHECK((kind='obligation' AND revision_id IS NOT NULL AND edge_no IS NOT NULL) OR (kind IN ('pair_balance','pair_credit') AND revision_id IS NULL AND edge_no IS NULL))
);
CREATE TABLE shared_expenses.operation_receipts (
  actor_profile_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  command_kind text NOT NULL,
  request_hash text NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
  input_hash text NOT NULL CHECK(input_hash ~ '^[a-f0-9]{64}$'),
  context_id uuid,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(actor_profile_id,operation_id)
);
CREATE TABLE shared_expenses.context_events (
  context_id uuid NOT NULL REFERENCES shared_expenses.contexts(context_id),
  sequence bigint NOT NULL CHECK(sequence BETWEEN 1 AND 9007199254740991),
  event_id uuid NOT NULL DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  origin_id uuid NOT NULL,
  actor_profile_id uuid NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(context_id,sequence),
  UNIQUE(context_id,event_id)
);
CREATE TABLE shared_expenses.profile_stream_heads (
  profile_id uuid PRIMARY KEY,
  committed_sequence bigint NOT NULL DEFAULT 0 CHECK(committed_sequence BETWEEN 0 AND 9007199254740991)
);
CREATE TABLE shared_expenses.profile_events (
  profile_id uuid NOT NULL REFERENCES shared_expenses.profile_stream_heads(profile_id),
  sequence bigint NOT NULL CHECK(sequence BETWEEN 1 AND 9007199254740991),
  context_id uuid NOT NULL,
  context_sequence bigint NOT NULL,
  PRIMARY KEY(profile_id,sequence),
  UNIQUE(profile_id,context_id,context_sequence),
  FOREIGN KEY(context_id,context_sequence) REFERENCES shared_expenses.context_events(context_id,sequence)
);
CREATE TABLE shared_expenses.member_balances (
  context_id uuid NOT NULL,
  member_id uuid NOT NULL,
  currency text NOT NULL CHECK(currency='INR'),
  balance_minor bigint NOT NULL CHECK(balance_minor BETWEEN -9007199254740991 AND 9007199254740991),
  PRIMARY KEY(context_id,member_id,currency),
  FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE TABLE shared_expenses.pair_balances (
  context_id uuid NOT NULL,
  currency text NOT NULL CHECK(currency='INR'),
  low_member_id uuid NOT NULL,
  high_member_id uuid NOT NULL CHECK(high_member_id > low_member_id),
  balance_minor bigint NOT NULL CHECK(balance_minor BETWEEN -9007199254740991 AND 9007199254740991 AND balance_minor<>0),
  PRIMARY KEY(context_id,currency,low_member_id,high_member_id),
  FOREIGN KEY(context_id,low_member_id) REFERENCES shared_expenses.members(context_id,member_id),
  FOREIGN KEY(context_id,high_member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE TABLE shared_expenses.private_cost_facts (
  profile_id uuid NOT NULL,
  context_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  revision_id uuid NOT NULL,
  member_id uuid NOT NULL,
  currency text NOT NULL CHECK(currency='INR'),
  share_minor bigint NOT NULL CHECK(share_minor BETWEEN 0 AND 1000000000),
  source_linked_minor bigint NOT NULL CHECK(source_linked_minor BETWEEN 0 AND 1000000000),
  occurred_on date NOT NULL,
  PRIMARY KEY(profile_id,context_id,expense_id),
  FOREIGN KEY(context_id,expense_id,revision_id) REFERENCES shared_expenses.expense_revisions(context_id,expense_id,revision_id),
  FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
CREATE INDEX shared_private_cost_period ON shared_expenses.private_cost_facts(profile_id,occurred_on,context_id,expense_id);

-- Immutability is not just API convention: accepted history/proposals/payments
-- cannot be rewritten or cascaded away by runtime financial operations.
CREATE FUNCTION shared_expenses._immutable() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  RAISE EXCEPTION 'immutable financial record' USING ERRCODE='55000';
END $$;
DO $$ DECLARE n text; BEGIN
  FOR n IN SELECT tablename FROM pg_tables WHERE schemaname='shared_expenses' LOOP
    EXECUTE format('ALTER TABLE shared_expenses.%I OWNER TO shared_expenses_owner',n);
    EXECUTE format('ALTER TABLE shared_expenses.%I ENABLE ROW LEVEL SECURITY',n);
    EXECUTE format('ALTER TABLE shared_expenses.%I FORCE ROW LEVEL SECURITY',n);
    EXECUTE format('CREATE POLICY shared_owner ON shared_expenses.%I FOR ALL TO shared_expenses_owner USING(true) WITH CHECK(true)',n);
  END LOOP;
  FOREACH n IN ARRAY ARRAY['expense_revisions','revision_members','revision_approvals','journal_entries','obligation_edges','settlement_reports','settlement_events','settlement_allocations','context_events','profile_events'] LOOP
    EXECUTE format('CREATE TRIGGER shared_immutable BEFORE UPDATE OR DELETE ON shared_expenses.%I FOR EACH ROW EXECUTE FUNCTION shared_expenses._immutable()',n);
  END LOOP;
END $$;

CREATE FUNCTION shared_expenses._actor() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=pandapay.uid(); BEGIN
  IF a IS NULL OR NOT EXISTS(SELECT FROM public.profiles WHERE id=a) THEN RAISE EXCEPTION 'authentication_required' USING ERRCODE='42501'; END IF;
  RETURN a;
END $$;
CREATE FUNCTION shared_expenses._can_read_context(p_context uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
  SELECT EXISTS(SELECT FROM shared_expenses.settings WHERE reads_enabled) AND EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=pandapay.uid() AND state='active')
$$;
CREATE FUNCTION shared_expenses._can_read_invitation(p_context uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
 SELECT EXISTS(SELECT FROM shared_expenses.settings WHERE reads_enabled) AND EXISTS(SELECT FROM shared_expenses.members WHERE context_id=p_context AND profile_id=pandapay.uid() AND state='invited')
$$;
CREATE FUNCTION shared_expenses.capabilities() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  PERFORM shared_expenses._actor();
  RETURN (SELECT jsonb_build_object('schemaVersion',1,'reads',reads_enabled,'proposals',proposals_enabled,'acceptedWrites',accepted_writes_enabled,'settlements',settlements_enabled,'sourceFunding',false) FROM shared_expenses.settings WHERE singleton);
END $$;
CREATE FUNCTION shared_expenses._require_proposals() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  IF NOT EXISTS(SELECT FROM shared_expenses.settings WHERE reads_enabled AND proposals_enabled) THEN RAISE EXCEPTION 'feature_disabled' USING ERRCODE='55000'; END IF;
END $$;
CREATE FUNCTION shared_expenses._operation(p_operation uuid,p_hash text,p_kind text,p_input jsonb,p_context uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r shared_expenses.operation_receipts; h text; BEGIN
  IF p_operation IS NULL OR p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'invalid_operation' USING ERRCODE='22023'; END IF;
  h:=encode(sha256(convert_to(p_input::text,'UTF8')),'hex');
  INSERT INTO shared_expenses.operation_receipts(actor_profile_id,operation_id,command_kind,request_hash,input_hash,context_id) VALUES(a,p_operation,p_kind,p_hash,h,p_context) ON CONFLICT DO NOTHING;
  SELECT * INTO STRICT r FROM shared_expenses.operation_receipts WHERE actor_profile_id=a AND operation_id=p_operation FOR UPDATE;
  IF r.command_kind<>p_kind OR r.request_hash<>p_hash OR r.input_hash<>h OR r.context_id IS DISTINCT FROM p_context THEN RAISE EXCEPTION 'operation_conflict' USING ERRCODE='23505'; END IF;
  RETURN r.result;
END $$;
CREATE FUNCTION shared_expenses._finish(p_operation uuid,p_result jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  UPDATE shared_expenses.operation_receipts SET result=p_result WHERE actor_profile_id=shared_expenses._actor() AND operation_id=p_operation AND result IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'operation_already_finished' USING ERRCODE='55000'; END IF;
  RETURN p_result;
END $$;
CREATE FUNCTION shared_expenses._emit(p_context uuid,p_kind text,p_origin uuid,p_payload jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE s bigint; m record; ps bigint; BEGIN
  -- Context row lock serializes context commits. Profile stream locks are taken
  -- in UUID order before incrementing so sequences never skip an uncommitted event.
  UPDATE shared_expenses.contexts SET committed_sequence=committed_sequence+1 WHERE context_id=p_context RETURNING committed_sequence INTO STRICT s;
  INSERT INTO shared_expenses.context_events(context_id,sequence,kind,origin_id,actor_profile_id,payload) VALUES(p_context,s,p_kind,p_origin,shared_expenses._actor(),p_payload);
  FOR m IN SELECT DISTINCT profile_id FROM shared_expenses.members WHERE context_id=p_context AND profile_id IS NOT NULL AND (state='active' OR (p_kind='member.invited' AND member_id=p_origin AND state='invited')) ORDER BY profile_id LOOP
    INSERT INTO shared_expenses.profile_stream_heads(profile_id) VALUES(m.profile_id) ON CONFLICT DO NOTHING;
    UPDATE shared_expenses.profile_stream_heads SET committed_sequence=committed_sequence+1 WHERE profile_id=m.profile_id RETURNING committed_sequence INTO ps;
    INSERT INTO shared_expenses.profile_events(profile_id,sequence,context_id,context_sequence) VALUES(m.profile_id,ps,p_context,s);
  END LOOP;
  RETURN s;
END $$;
CREATE FUNCTION shared_expenses.create_context(p_context_id uuid,p_kind text,p_name text,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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
CREATE FUNCTION shared_expenses.respond_membership(p_context_id uuid,p_member_id uuid,p_accept boolean,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); r jsonb; m shared_expenses.members; seq bigint; BEGIN
  PERFORM shared_expenses._require_proposals();
  SELECT * INTO m FROM shared_expenses.members WHERE context_id=p_context_id AND member_id=p_member_id AND profile_id=a;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership_not_authorized' USING ERRCODE='42501'; END IF;
  r:=shared_expenses._operation(p_operation_id,p_request_hash,'membership.respond',jsonb_build_object('contextId',p_context_id,'memberId',p_member_id,'accept',p_accept),p_context_id);
  IF r IS NOT NULL THEN RETURN r; END IF;
  PERFORM 1 FROM shared_expenses.contexts WHERE context_id=p_context_id AND state='active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
  SELECT * INTO STRICT m FROM shared_expenses.members WHERE context_id=p_context_id AND member_id=p_member_id AND profile_id=a;
  IF p_accept IS NULL OR m.state<>'invited' THEN RAISE EXCEPTION 'membership_conflict' USING ERRCODE='55000'; END IF;
  UPDATE shared_expenses.members SET state=CASE WHEN p_accept THEN 'active' ELSE 'declined' END WHERE context_id=p_context_id AND member_id=p_member_id;
  seq:=shared_expenses._emit(p_context_id,'membership.responded',p_member_id,jsonb_build_object('memberId',p_member_id,'accepted',p_accept));
  RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',CASE WHEN p_accept THEN 'joined' ELSE 'declined' END,'sequence',seq::text));
END $$;

CREATE FUNCTION shared_expenses.invite_member(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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

CREATE FUNCTION shared_expenses._inspect_source(p_ref jsonb,p_expected boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp
SET TimeZone = 'UTC' AS $$
DECLARE a uuid:=shared_expenses._actor(); k text; cid uuid; eid text; fid uuid; t public.transactions; ev public.sms_v2_events; fx public.foreign_payments; legs jsonb; version text; snap jsonb; minor bigint; allowed text[]; v text; requires_review boolean:=false;
BEGIN
  IF jsonb_typeof(p_ref)<>'object' OR octet_length(p_ref::text)>4096 OR NOT (p_ref ?& ARRAY['kind','ownerAccountId']) THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
  k:=p_ref->>'kind';
  IF k NOT IN ('legacy_transaction','sms_v2_event','confirmed_foreign_payment') OR p_ref->>'ownerAccountId' IS DISTINCT FROM a::text THEN RAISE EXCEPTION 'source_not_authorized' USING ERRCODE='42501'; END IF;
  allowed:=CASE k WHEN 'legacy_transaction' THEN ARRAY['kind','ownerAccountId','canonicalTransactionId','sourceKey'] WHEN 'sms_v2_event' THEN ARRAY['kind','ownerAccountId','eventId','localProjectionId','canonicalTransactionId','sourceKey'] ELSE ARRAY['kind','ownerAccountId','canonicalTransactionId','foreignPaymentId','sourceKey'] END;
  IF p_expected THEN allowed:=array_append(allowed,'sourceVersion'); END IF;
  IF EXISTS(SELECT FROM jsonb_object_keys(p_ref) AS x(key) WHERE NOT key=ANY(allowed)) THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
  FOR v IN SELECT value FROM jsonb_each_text(p_ref) LOOP IF v IS NULL OR length(v)>128 THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF; END LOOP;
  IF p_ref ? 'canonicalTransactionId' THEN
    IF p_ref->>'canonicalTransactionId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
    cid:=(p_ref->>'canonicalTransactionId')::uuid;
  ELSIF k<>'sms_v2_event' THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
  IF p_expected AND (p_ref->>'sourceVersion' IS NULL OR p_ref->>'sourceVersion' !~ '^[a-f0-9]{64}$') THEN RAISE EXCEPTION 'source_version_mismatch' USING ERRCODE='40001'; END IF;
  IF p_ref ? 'sourceKey' AND (p_ref->>'sourceKey' !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$') THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('transaction-ingest:'||a::text,0));
  IF k='sms_v2_event' THEN
    eid:=p_ref->>'eventId';
    IF eid IS NULL OR eid !~ '^[a-f0-9]{64}$' OR (p_ref ? 'localProjectionId' AND p_ref->>'localProjectionId'<>'v2:'||eid) THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
    SELECT * INTO t FROM public.transactions WHERE profile_id=a AND event_id=eid AND pipeline_version=2;
    IF NOT FOUND OR (cid IS NOT NULL AND cid<>t.id) THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
    cid:=t.id;
  ELSE
    SELECT * INTO t FROM public.transactions WHERE profile_id=a AND id=cid;
    IF NOT FOUND THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
  END IF;
  IF t.status::text<>'active' OR t.entry_kind::text<>'spend' OR t.amount_inr IS NULL OR t.amount_inr*100<>trunc(t.amount_inr*100) OR t.amount_inr*100 NOT BETWEEN 1 AND 1000000000 THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
  IF p_ref ? 'sourceKey' AND p_ref->>'sourceKey' IS DISTINCT FROM t.source_key THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
  minor:=(t.amount_inr*100)::bigint;
  snap:=jsonb_build_object('canonicalTransactionId',cid,'amountMinor',minor::text,'occurredAt',t.occurred_at,'status',t.status::text,'entryKind',t.entry_kind::text,'source',t.source::text,'instrument',t.instrument::text,'updatedAt',t.updated_at,'pipelineVersion',t.pipeline_version,'eventId',t.event_id,'sourceKey',t.source_key);
  IF t.pipeline_version=2 THEN
    eid:=t.event_id;
    SELECT * INTO ev FROM public.sms_v2_events WHERE profile_id=a AND event_id=eid;
    IF NOT FOUND OR ev.type NOT IN ('purchase','subscription_charge','bill_payment') OR ev.status NOT IN ('complete','user_confirmed') OR ev.amount_minor<>minor THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
    IF (SELECT count(*) FROM public.sms_v2_ledger_entries WHERE profile_id=a AND event_id=eid)>200 THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
    -- Every counted INR leg must be a posted external purchase from an owned,
    -- confirmed instrument. Excludes P2P, cash withdrawal, own transfers and holds.
    IF NOT EXISTS(SELECT FROM public.sms_v2_ledger_entries WHERE profile_id=a AND event_id=eid AND unit='INR') OR EXISTS(
      SELECT FROM public.sms_v2_ledger_entries l LEFT JOIN public.sms_v2_instruments i ON i.profile_id=l.profile_id AND i.instrument_id=l.from_instrument_id
      WHERE l.profile_id=a AND l.event_id=eid AND l.unit='INR' AND (l.from_instrument_id IS NULL OR i.instrument_id IS NULL OR i.status<>'confirmed' OR l.from_external IS NOT NULL OR l.from_own_unresolved IS NOT NULL OR l.to_external IS NULL OR l.to_instrument_id IS NOT NULL OR l.to_own_unresolved IS NOT NULL OR NOT l.is_spend OR NOT l.counts_as_transaction)) OR
      (SELECT coalesce(sum(amount_minor),0) FROM public.sms_v2_ledger_entries WHERE profile_id=a AND event_id=eid AND unit='INR')<>minor
    THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
    SELECT jsonb_agg(jsonb_build_object('entryId',l.entry_id,'amountMinor',l.amount_minor::text,'fromInstrumentId',l.from_instrument_id,'toExternal',l.to_external,'unit',l.unit,'isSpend',l.is_spend,'counts',l.counts_as_transaction,'updatedAt',l.updated_at,'instrumentStatus',i.status,'instrumentUpdatedAt',i.updated_at) ORDER BY l.entry_id) INTO legs
      FROM public.sms_v2_ledger_entries l LEFT JOIN public.sms_v2_instruments i ON i.profile_id=l.profile_id AND i.instrument_id=l.from_instrument_id WHERE l.profile_id=a AND l.event_id=eid;
    snap:=snap||jsonb_build_object('event',jsonb_build_object('id',eid,'type',ev.type,'status',ev.status,'amountMinor',ev.amount_minor::text,'updatedAt',ev.updated_at),'ledger',legs);
  ELSE
    -- Legacy spend is not sufficient purchase evidence. A reviewed source
    -- classification certificate is a separate integration gate.
    requires_review:=true;
  END IF;
  IF k='confirmed_foreign_payment' THEN
    IF p_ref->>'foreignPaymentId' IS NULL OR p_ref->>'foreignPaymentId' !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' THEN RAISE EXCEPTION 'invalid_source_reference' USING ERRCODE='22023'; END IF;
    fid:=(p_ref->>'foreignPaymentId')::uuid;
  END IF;
  -- Resolve FX by its canonical transaction for every alias, producing one
  -- fingerprint and preventing a legacy/v2 alias bypassing valuation checks.
  SELECT * INTO fx FROM public.foreign_payments WHERE profile_id=a AND transaction_id=cid;
  IF FOUND THEN
    IF (fid IS NOT NULL AND fid<>fx.id) OR fx.valuation_status<>'confirmed' OR fx.direction<>'spend' OR fx.confirmation_source IS NULL OR fx.billed_inr<>t.amount_inr OR fx.original_currency IS NULL OR fx.original_amount IS NULL OR fx.original_amount<=0 THEN RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000'; END IF;
    fid:=fx.id;
    snap:=snap||jsonb_build_object('foreignPaymentId',fid,'foreignRevision',fx.revision,'billedInr',fx.billed_inr::text,'originalCurrency',fx.original_currency,'originalAmount',fx.original_amount::text,'foreignUpdatedAt',fx.updated_at);
  ELSIF k='confirmed_foreign_payment' THEN
    RAISE EXCEPTION 'source_not_eligible' USING ERRCODE='55000';
  END IF;
  version:=encode(sha256(convert_to(snap::text,'UTF8')),'hex');
  IF p_expected AND p_ref->>'sourceVersion'<>version THEN RAISE EXCEPTION 'source_version_mismatch' USING ERRCODE='40001'; END IF;
  IF p_expected AND requires_review THEN RAISE EXCEPTION 'source_explicit_review_required' USING ERRCODE='55000'; END IF;
  RETURN jsonb_strip_nulls(jsonb_build_object('kind',k,'ownerAccountId',a,'canonicalTransactionId',cid,'sourceVersion',version,'currency','INR','eligibleMinor',minor::text,'eventId',eid,'foreignPaymentId',fid,'eligible',NOT requires_review,'requiresReview',requires_review,'reason',CASE WHEN requires_review THEN 'purchase_confirmation_required' END));
END $$;
CREATE FUNCTION shared_expenses.inspect_source(p_identity jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  PERFORM shared_expenses._require_proposals();
  RETURN shared_expenses._inspect_source(p_identity,false);
END $$;
CREATE FUNCTION shared_expenses.admit_source(p_ref jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ BEGIN
  PERFORM shared_expenses._require_proposals();
  RETURN shared_expenses._inspect_source(p_ref,true);
END $$;

CREATE FUNCTION shared_expenses._closed(p_value jsonb,p_keys text[]) RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
 SELECT jsonb_typeof(p_value)='object' AND p_value ?& p_keys AND NOT EXISTS(SELECT FROM jsonb_object_keys(p_value) x(k) WHERE NOT k=ANY(p_keys))
$$;
CREATE FUNCTION shared_expenses._valid_source_reference(p_ref jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
DECLARE k text; required text[]; allowed text[]; key text; value text;
BEGIN
 IF jsonb_typeof(p_ref) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
 k:=p_ref->>'kind';
 IF k='legacy_transaction' THEN required:=ARRAY['kind','ownerAccountId','canonicalTransactionId','sourceVersion']; allowed:=required||ARRAY['sourceKey'];
 ELSIF k='sms_v2_event' THEN required:=ARRAY['kind','ownerAccountId','eventId']; allowed:=required||ARRAY['canonicalTransactionId','sourceVersion','sourceKey','localProjectionId'];
 ELSIF k='confirmed_foreign_payment' THEN required:=ARRAY['kind','ownerAccountId','canonicalTransactionId','sourceVersion','foreignPaymentId']; allowed:=required||ARRAY['sourceKey'];
 ELSE RETURN false; END IF;
 IF NOT(p_ref ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_ref) x(k) WHERE NOT x.k=ANY(allowed)) THEN RETURN false; END IF;
 FOR key,value IN SELECT x.key,x.value FROM jsonb_each_text(p_ref) x LOOP
   IF jsonb_typeof(p_ref->key) IS DISTINCT FROM 'string' OR value IS NULL OR length(value)>128 THEN RETURN false; END IF;
   IF key IN ('ownerAccountId','canonicalTransactionId','foreignPaymentId') AND value !~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' THEN RETURN false; END IF;
   IF key IN ('sourceVersion','sourceKey') AND value !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$' THEN RETURN false; END IF;
 END LOOP;
 IF k='sms_v2_event' AND (p_ref->>'eventId' !~ '^[a-f0-9]{64}$' OR ((p_ref ? 'canonicalTransactionId')<>(p_ref ? 'sourceVersion')) OR (p_ref ? 'localProjectionId' AND p_ref->>'localProjectionId'<>'v2:'||(p_ref->>'eventId'))) THEN RETURN false; END IF;
 RETURN true;
END $$;
CREATE FUNCTION shared_expenses._project_snapshot(p_snapshot jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE row jsonb; total bigint; positions jsonb; edges jsonb; n int; BEGIN
 IF NOT shared_expenses._closed(p_snapshot,ARRAY['currency','totalMinor','contributions','shares','memberOrder']) OR p_snapshot->>'currency'<>'INR' OR jsonb_typeof(p_snapshot->'totalMinor')<>'string' OR p_snapshot->>'totalMinor' !~ '^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'invalid_snapshot' USING ERRCODE='22023'; END IF;
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

-- All posting helpers are private to the NOLOGIN owner. No runtime role can
-- submit arbitrary journal deltas; commands derive edges from stored snapshots.
CREATE FUNCTION shared_expenses._post_pair(p_context uuid,p_effect uuid,p_line smallint,p_low uuid,p_high uuid,p_amount bigint,p_kind text,p_origin uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE value bigint; BEGIN
 IF p_low>=p_high OR p_amount=0 THEN RAISE EXCEPTION 'invalid_pair' USING ERRCODE='22023'; END IF;
 INSERT INTO shared_expenses.journal_entries(context_id,effect_id,line_no,currency,low_member_id,high_member_id,balance_minor,kind,origin_id) VALUES(p_context,p_effect,p_line,'INR',p_low,p_high,p_amount,p_kind,p_origin);
 SELECT balance_minor INTO value FROM shared_expenses.pair_balances WHERE context_id=p_context AND currency='INR' AND low_member_id=p_low AND high_member_id=p_high;
 value:=coalesce(value,0)+p_amount;
 IF value=0 THEN DELETE FROM shared_expenses.pair_balances WHERE context_id=p_context AND currency='INR' AND low_member_id=p_low AND high_member_id=p_high;
 ELSE INSERT INTO shared_expenses.pair_balances(context_id,currency,low_member_id,high_member_id,balance_minor) VALUES(p_context,'INR',p_low,p_high,value) ON CONFLICT(context_id,currency,low_member_id,high_member_id) DO UPDATE SET balance_minor=excluded.balance_minor; END IF;
 INSERT INTO shared_expenses.member_balances(context_id,member_id,currency,balance_minor) VALUES(p_context,p_low,'INR',p_amount),(p_context,p_high,'INR',-p_amount) ON CONFLICT(context_id,member_id,currency) DO UPDATE SET balance_minor=shared_expenses.member_balances.balance_minor+excluded.balance_minor;
END $$;
CREATE FUNCTION shared_expenses._accept_revision(p_context uuid,p_expense uuid,p_revision uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE e shared_expenses.expenses; r shared_expenses.expense_revisions; old_edges jsonb:='[]'; line record; no smallint:=0; BEGIN
 SELECT * INTO STRICT e FROM shared_expenses.expenses WHERE context_id=p_context AND expense_id=p_expense FOR UPDATE;
 SELECT * INTO STRICT r FROM shared_expenses.expense_revisions WHERE context_id=p_context AND expense_id=p_expense AND revision_id=p_revision;
 IF e.accepted_revision_id=p_revision THEN RETURN 'accepted'; END IF;
 IF e.accepted_revision_id IS DISTINCT FROM r.expected_head_revision_id THEN RAISE EXCEPTION 'revision_head_conflict' USING ERRCODE='40001'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND m.approval_required AND (m.approver_profile_id IS NULL OR NOT EXISTS(SELECT FROM shared_expenses.revision_approvals a WHERE a.context_id=m.context_id AND a.revision_id=m.revision_id AND a.member_id=m.member_id AND a.actor_profile_id=m.approver_profile_id AND a.revision_hash=r.revision_hash AND a.decision='approve'))) THEN RETURN 'awaiting_approval'; END IF;
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
 SELECT m.approver_profile_id,p_context,p_expense,p_revision,m.member_id,'INR',m.share_minor,0,r.occurred_on FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND m.approver_profile_id IS NOT NULL;
 RETURN 'accepted';
END $$;
CREATE FUNCTION shared_expenses.submit_proposal(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
DECLARE a uuid:=shared_expenses._actor(); ctx uuid; exp uuid; rev uuid; previous uuid; old shared_expenses.expenses; projected jsonb; r jsonb; h text; status text; seq bigint;
BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload,ARRAY['contextId','expenseId','revisionId','expectedHeadRevisionId','snapshot','title','occurredOn','sources','void']) OR octet_length(p_payload::text)>65536 THEN RAISE EXCEPTION 'invalid_proposal' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; exp:=(p_payload->>'expenseId')::uuid; rev:=(p_payload->>'revisionId')::uuid; previous:=(p_payload->>'expectedHeadRevisionId')::uuid;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'expense.propose',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF ctx IS NULL OR exp IS NULL OR rev IS NULL OR jsonb_typeof(p_payload->'void')<>'boolean' OR jsonb_typeof(p_payload->'title')<>'string' OR length(btrim(p_payload->>'title')) NOT BETWEEN 1 AND 200 OR p_payload->>'occurredOn' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR jsonb_typeof(p_payload->'sources')<>'array' OR jsonb_array_length(p_payload->'sources')>8 THEN RAISE EXCEPTION 'invalid_proposal' USING ERRCODE='22023'; END IF;
 IF (p_payload->>'void')::boolean THEN
   IF p_payload->'snapshot'<>'null'::jsonb OR previous IS NULL OR jsonb_array_length(p_payload->'sources')<>0 THEN RAISE EXCEPTION 'invalid_void' USING ERRCODE='22023'; END IF;
   projected:=jsonb_build_object('currency','INR','totalMinor','0','positions','[]'::jsonb,'obligations','[]'::jsonb);
 ELSE projected:=shared_expenses._project_snapshot(p_payload->'snapshot'); END IF;
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
 INSERT INTO shared_expenses.expense_revisions(context_id,expense_id,revision_id,author_profile_id,expected_head_revision_id,revision_hash,title,occurred_on,total_minor,is_void,snapshot,source_links,projected_edges)
 VALUES(ctx,exp,rev,a,previous,h,btrim(p_payload->>'title'),(p_payload->>'occurredOn')::date,(projected->>'totalMinor')::bigint,(p_payload->>'void')::boolean,nullif(p_payload->'snapshot','null'::jsonb),p_payload->'sources',projected->'obligations');
 -- Conservatively require every previously/newly involved identity to review
 -- the exact whole revision, including payer-only/excluded participants.
 INSERT INTO shared_expenses.revision_members(context_id,expense_id,revision_id,member_id,approver_profile_id,ordinal,paid_minor,share_minor,approval_required)
 SELECT ctx,exp,rev,m.member_id,m.profile_id,(row_number() OVER(ORDER BY m.member_id)-1)::smallint,
 coalesce((p.value->>'paidMinor')::bigint,0),coalesce((p.value->>'shareMinor')::bigint,0),
 coalesce((p.value->>'paidMinor')::bigint,0)>0 OR coalesce((p.value->>'shareMinor')::bigint,0)>0 OR coalesce(pm.paid_minor,0)>0 OR coalesce(pm.share_minor,0)>0
 FROM shared_expenses.members m LEFT JOIN jsonb_array_elements(projected->'positions') p ON (p.value->>'memberId')::uuid=m.member_id LEFT JOIN shared_expenses.revision_members pm ON pm.context_id=ctx AND pm.revision_id=previous AND pm.member_id=m.member_id
 WHERE m.context_id=ctx AND (p.value IS NOT NULL OR pm.member_id IS NOT NULL);
 -- Author's explicit submit approves only their own identities; no friend is
 -- silently approved and account membership itself is never financial consent.
 INSERT INTO shared_expenses.revision_approvals(context_id,revision_id,member_id,actor_profile_id,revision_hash,decision,operation_id)
 SELECT ctx,rev,member_id,a,h,'approve',p_operation_id FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND approver_profile_id=a AND approval_required;
 status:=shared_expenses._accept_revision(ctx,exp,rev);
 seq:=shared_expenses._emit(ctx,CASE WHEN status='accepted' THEN 'expense.accepted' ELSE 'expense.proposed' END,rev,jsonb_build_object('expenseId',exp,'revisionId',rev,'status',status));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',status,'expenseId',exp,'revisionId',rev,'revisionHash',h,'sequence',seq::text));
END $$;
CREATE FUNCTION shared_expenses.respond_expense(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; exp uuid; rev uuid; r shared_expenses.expense_revisions; response jsonb; d text; status text; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload,ARRAY['contextId','expenseId','revisionId','decision']) THEN RAISE EXCEPTION 'invalid_response' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; exp:=(p_payload->>'expenseId')::uuid; rev:=(p_payload->>'revisionId')::uuid; d:=p_payload->>'decision';
 IF d NOT IN ('approve','reject') OR d IS NULL THEN RAISE EXCEPTION 'invalid_response' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 response:=shared_expenses._operation(p_operation_id,p_request_hash,'expense.respond',p_payload,ctx); IF response IS NOT NULL THEN RETURN response; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO r FROM shared_expenses.expense_revisions WHERE context_id=ctx AND expense_id=exp AND revision_id=rev;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND approver_profile_id=a AND approval_required) THEN RAISE EXCEPTION 'revision_not_authorized' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT FROM shared_expenses.revision_approvals WHERE context_id=ctx AND revision_id=rev AND actor_profile_id=a AND decision<>d) THEN RAISE EXCEPTION 'approval_conflict' USING ERRCODE='55000'; END IF;
 INSERT INTO shared_expenses.revision_approvals(context_id,revision_id,member_id,actor_profile_id,revision_hash,decision,operation_id)
 SELECT ctx,rev,member_id,a,r.revision_hash,d,p_operation_id FROM shared_expenses.revision_members WHERE context_id=ctx AND revision_id=rev AND approver_profile_id=a AND approval_required ON CONFLICT DO NOTHING;
 IF d='reject' THEN status:='rejected'; ELSE status:=shared_expenses._accept_revision(ctx,exp,rev); END IF;
 seq:=shared_expenses._emit(ctx,CASE WHEN status='accepted' THEN 'expense.accepted' ELSE 'expense.responded' END,rev,jsonb_build_object('expenseId',exp,'revisionId',rev,'status',status));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',status,'expenseId',exp,'revisionId',rev,'sequence',seq::text));
END $$;

CREATE FUNCTION shared_expenses.report_settlement(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; sid uuid; payer uuid; receiver uuid; amount bigint; r jsonb; required text[]:=ARRAY['contextId','settlementId','payerMemberId','receiverMemberId','amountMinor','currency','method','paidOn']; seq bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF jsonb_typeof(p_payload)<>'object' OR NOT(p_payload ?& required) OR EXISTS(SELECT FROM jsonb_object_keys(p_payload) x(k) WHERE NOT k=ANY(required||ARRAY['reference'])) OR octet_length(p_payload::text)>4096 THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; sid:=(p_payload->>'settlementId')::uuid; payer:=(p_payload->>'payerMemberId')::uuid; receiver:=(p_payload->>'receiverMemberId')::uuid;
 IF ctx IS NULL OR sid IS NULL OR payer IS NULL OR receiver IS NULL OR payer=receiver OR jsonb_typeof(p_payload->'amountMinor')<>'string' OR p_payload->>'amountMinor' !~ '^[1-9][0-9]{0,9}$' OR p_payload->>'currency'<>'INR' OR p_payload->>'method' NOT IN ('upi','cash','bank') OR p_payload->>'paidOn' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR (p_payload ? 'reference' AND (jsonb_typeof(p_payload->'reference')<>'string' OR p_payload->>'reference' !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$')) THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 amount:=(p_payload->>'amountMinor')::bigint; IF amount>1000000000 THEN RAISE EXCEPTION 'invalid_settlement' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'settlement.report',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 IF (SELECT count(*) FROM shared_expenses.members WHERE context_id=ctx AND member_id IN (payer,receiver) AND state='active' AND profile_id IS NOT NULL)<>2 THEN RAISE EXCEPTION 'settlement_member_not_authorized' USING ERRCODE='42501'; END IF;
 INSERT INTO shared_expenses.settlement_reports(context_id,settlement_id,reporter_profile_id,payer_member_id,receiver_member_id,amount_minor,currency,method,paid_on) VALUES(ctx,sid,a,payer,receiver,amount,'INR',p_payload->>'method',(p_payload->>'paidOn')::date);
 IF p_payload ? 'reference' THEN INSERT INTO shared_expenses.settlement_private_references(context_id,settlement_id,owner_profile_id,reference) VALUES(ctx,sid,a,p_payload->>'reference'); END IF;
 seq:=shared_expenses._emit(ctx,'settlement.reported',sid,jsonb_build_object('settlementId',sid,'payerMemberId',payer,'receiverMemberId',receiver,'amountMinor',amount::text,'status','awaiting_receiver_confirmation'));
 RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status','awaiting_receiver_confirmation','settlementId',sid,'sequence',seq::text));
END $$;
CREATE FUNCTION shared_expenses.respond_settlement(p_payload jsonb,p_operation_id uuid,p_request_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$ DECLARE a uuid:=shared_expenses._actor(); ctx uuid; sid uuid; d text; report shared_expenses.settlement_reports; old shared_expenses.settlement_events; r jsonb; eid uuid; low uuid; high uuid; amount bigint; seq bigint; owed bigint; applied bigint; BEGIN
 PERFORM shared_expenses._require_proposals();
 IF NOT shared_expenses._closed(p_payload,ARRAY['contextId','settlementId','decision']) THEN RAISE EXCEPTION 'invalid_settlement_response' USING ERRCODE='22023'; END IF;
 ctx:=(p_payload->>'contextId')::uuid; sid:=(p_payload->>'settlementId')::uuid; d:=p_payload->>'decision';
 IF d IS NULL OR d NOT IN ('confirm','reject') THEN RAISE EXCEPTION 'invalid_settlement_response' USING ERRCODE='22023'; END IF;
 IF NOT shared_expenses._can_read_context(ctx) THEN RAISE EXCEPTION 'context_not_authorized' USING ERRCODE='42501'; END IF;
 r:=shared_expenses._operation(p_operation_id,p_request_hash,'settlement.respond',p_payload,ctx); IF r IS NOT NULL THEN RETURN r; END IF;
 PERFORM 1 FROM shared_expenses.contexts WHERE context_id=ctx AND state='active' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'context_not_active' USING ERRCODE='55000'; END IF;
 SELECT * INTO report FROM shared_expenses.settlement_reports WHERE context_id=ctx AND settlement_id=sid;
 IF NOT FOUND OR NOT EXISTS(SELECT FROM shared_expenses.members WHERE context_id=ctx AND member_id=report.receiver_member_id AND profile_id=a AND state='active') THEN RAISE EXCEPTION 'receiver_confirmation_required' USING ERRCODE='42501'; END IF;
 SELECT * INTO old FROM shared_expenses.settlement_events WHERE context_id=ctx AND settlement_id=sid AND kind IN ('confirmed','rejected');
 IF FOUND THEN
   IF old.kind<>(CASE WHEN d='confirm' THEN 'confirmed' ELSE 'rejected' END) THEN RAISE EXCEPTION 'settlement_terminal_conflict' USING ERRCODE='55000'; END IF;
   RETURN shared_expenses._finish(p_operation_id,jsonb_build_object('status',old.kind,'settlementId',sid,'eventId',old.event_id));
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

-- Context-scoped reads are independently authorized. Proposals are visible
-- only to their author / required reviewer; accepted revisions to active members.
CREATE POLICY shared_context_read ON shared_expenses.contexts FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id) OR shared_expenses._can_read_invitation(context_id));
CREATE POLICY shared_members_read ON shared_expenses.members FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id) OR profile_id=pandapay.uid());
CREATE POLICY shared_expense_read ON shared_expenses.expenses FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id));
CREATE FUNCTION shared_expenses._can_read_revision(p_context uuid,p_revision uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, shared_expenses, pg_temp AS $$
 SELECT shared_expenses._can_read_context(p_context) AND EXISTS(SELECT FROM shared_expenses.expense_revisions r WHERE r.context_id=p_context AND r.revision_id=p_revision AND (r.author_profile_id=pandapay.uid() OR EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=p_context AND m.revision_id=p_revision AND m.approver_profile_id=pandapay.uid()) OR EXISTS(SELECT FROM shared_expenses.expenses e WHERE e.context_id=p_context AND e.expense_id=r.expense_id AND e.accepted_revision_id=p_revision)))
$$;
CREATE POLICY shared_revision_read ON shared_expenses.expense_revisions FOR SELECT TO app_user USING(shared_expenses._can_read_revision(context_id,revision_id));
CREATE POLICY shared_revision_member_read ON shared_expenses.revision_members FOR SELECT TO app_user USING(shared_expenses._can_read_revision(context_id,revision_id));
CREATE POLICY shared_revision_approval_read ON shared_expenses.revision_approvals FOR SELECT TO app_user USING(shared_expenses._can_read_revision(context_id,revision_id));
DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['journal_entries','obligation_edges','member_balances','pair_balances','settlement_events','settlement_allocations'] LOOP
   EXECUTE format('CREATE POLICY shared_financial_read ON shared_expenses.%I FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id))',n);
 END LOOP;
END $$;
CREATE POLICY shared_report_read ON shared_expenses.settlement_reports FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id) AND (reporter_profile_id=pandapay.uid() OR EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=settlement_reports.context_id AND m.member_id IN (settlement_reports.payer_member_id,settlement_reports.receiver_member_id) AND m.profile_id=pandapay.uid())));
-- No runtime SELECT grant is made for this table. The party predicate is
-- additional defense if a future reviewed reference-read capability is added.
CREATE POLICY shared_private_reference_party ON shared_expenses.settlement_private_references FOR SELECT TO app_user USING(owner_profile_id=pandapay.uid() OR (shared_expenses._can_read_context(context_id) AND EXISTS(SELECT FROM shared_expenses.settlement_reports r JOIN shared_expenses.members m ON m.context_id=r.context_id AND m.member_id IN (r.payer_member_id,r.receiver_member_id) WHERE r.context_id=settlement_private_references.context_id AND r.settlement_id=settlement_private_references.settlement_id AND m.profile_id=pandapay.uid())));
CREATE POLICY shared_receipt_read ON shared_expenses.operation_receipts FOR SELECT TO app_user USING(actor_profile_id=pandapay.uid());
CREATE POLICY shared_profile_event_read ON shared_expenses.profile_events FOR SELECT TO app_user USING(profile_id=pandapay.uid());
CREATE POLICY shared_profile_head_read ON shared_expenses.profile_stream_heads FOR SELECT TO app_user USING(profile_id=pandapay.uid());
CREATE POLICY shared_cost_read ON shared_expenses.private_cost_facts FOR SELECT TO app_user USING(profile_id=pandapay.uid() AND shared_expenses._can_read_context(context_id));
-- Source identities and reference snapshots remain private to their owner and
-- are not published in a group activity row or another member's bank passbook.
CREATE POLICY shared_source_read ON shared_expenses.source_resources FOR SELECT TO app_user USING(owner_profile_id=pandapay.uid());
CREATE POLICY shared_alias_read ON shared_expenses.source_aliases FOR SELECT TO app_user USING(owner_profile_id=pandapay.uid());
CREATE POLICY shared_reservation_read ON shared_expenses.source_reservations FOR SELECT TO app_user USING(EXISTS(SELECT FROM shared_expenses.source_resources r WHERE r.resource_id=source_reservations.resource_id AND r.owner_profile_id=pandapay.uid()));
CREATE POLICY shared_context_event_read ON shared_expenses.context_events FOR SELECT TO app_user USING((shared_expenses._can_read_context(context_id) AND (kind<>'expense.proposed' OR EXISTS(SELECT FROM shared_expenses.expense_revisions r WHERE r.context_id=context_events.context_id AND r.revision_id=context_events.origin_id AND shared_expenses._can_read_revision(r.context_id,r.revision_id)))) OR (kind='member.invited' AND shared_expenses._can_read_invitation(context_id) AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=context_events.context_id AND m.member_id=context_events.origin_id AND m.profile_id=pandapay.uid())));

-- Revoke defaults first; explicit named functions are the only write boundary.
REVOKE ALL ON ALL TABLES IN SCHEMA shared_expenses FROM PUBLIC, app_user;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA shared_expenses FROM PUBLIC, app_user;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA shared_expenses FROM PUBLIC, app_user;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS identity FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='shared_expenses' LOOP
   EXECUTE format('ALTER FUNCTION %s OWNER TO shared_expenses_owner',f.identity);
 END LOOP;
END $$;
GRANT SELECT ON shared_expenses.contexts,shared_expenses.members,shared_expenses.expenses,shared_expenses.revision_members,shared_expenses.revision_approvals,shared_expenses.journal_entries,shared_expenses.obligation_edges,shared_expenses.settlement_events,shared_expenses.settlement_allocations,shared_expenses.operation_receipts,shared_expenses.context_events,shared_expenses.profile_events,shared_expenses.profile_stream_heads,shared_expenses.member_balances,shared_expenses.pair_balances,shared_expenses.private_cost_facts,shared_expenses.source_resources,shared_expenses.source_aliases,shared_expenses.source_reservations TO app_user;
GRANT SELECT(context_id,settlement_id,reporter_profile_id,payer_member_id,receiver_member_id,amount_minor,currency,method,paid_on,created_at) ON shared_expenses.settlement_reports TO app_user;
-- Column ACL prevents private funding source refs leaking to another approver.
GRANT SELECT(context_id,expense_id,revision_id,author_profile_id,expected_head_revision_id,revision_hash,projection_version,title,occurred_on,currency,total_minor,is_void,snapshot,projected_edges,created_at) ON shared_expenses.expense_revisions TO app_user;
GRANT EXECUTE ON FUNCTION shared_expenses.capabilities(),shared_expenses.create_context(uuid,text,text,uuid,text),shared_expenses.respond_membership(uuid,uuid,boolean,uuid,text),shared_expenses.invite_member(jsonb,uuid,text),shared_expenses.inspect_source(jsonb),shared_expenses.admit_source(jsonb),shared_expenses.submit_proposal(jsonb,uuid,text),shared_expenses.respond_expense(jsonb,uuid,text),shared_expenses.report_settlement(jsonb,uuid,text),shared_expenses.respond_settlement(jsonb,uuid,text),shared_expenses._can_read_context(uuid),shared_expenses._can_read_revision(uuid,uuid),shared_expenses._can_read_invitation(uuid) TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE shared_expenses_owner IN SCHEMA shared_expenses REVOKE ALL ON TABLES FROM PUBLIC, app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE shared_expenses_owner IN SCHEMA shared_expenses REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, app_user;
