'use strict';
// Deliberate local-only integration entry point. Never loads dotenv or DATABASE_URL.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { transactionalSql, statements } = require('../scripts/product_migrate');
const requireApi = createRequire(path.resolve(__dirname, '../../api/package.json'));
const raw = process.env.PANDAPAY_SHARED_EXPENSES_TEST_URL;
function fixtureUrl(value) {
  if (!value) throw new Error('explicit shared_expenses_test fixture URL required');
  const url = new URL(value);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) ||
      !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.pathname !== '/shared_expenses_test' || url.search || url.hash)
    throw new Error('loopback shared_expenses_test database required');
  return url.toString();
}

test('fixture admission refuses ambient and non-disposable databases', () => {
  assert.throws(() => fixtureUrl(), /explicit/);
  for (const url of ['postgres://localhost/pandapay', 'postgres://host/shared_expenses_test',
    'postgres://localhost/shared_expenses_test?sslmode=require']) assert.throws(() => fixtureUrl(url));
});

test('real PostgreSQL: forced RLS, source eligibility, replay and fail-closed writes', { skip: !raw && 'PANDAPAY_SHARED_EXPENSES_TEST_URL not supplied; real PG acceptance pending' }, async (t) => {
  const { Client } = requireApi('pg');
  const db = new Client({ connectionString: fixtureUrl(raw), connectionTimeoutMillis: 5000 });
  await db.connect();
  t.after(async () => { await db.query('ROLLBACK').catch(() => {}); await db.end(); });
  assert.ok(['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(db.connection.stream.remoteAddress));
  const existing = await db.query("SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast' AND c.relkind IN ('r','p')");
  assert.equal(existing.rows[0].n, 0, 'fixture must contain no existing product/user tables');
  await db.query('BEGIN');
  await db.query(`
    DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_user') THEN CREATE ROLE app_user NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$;
    CREATE SCHEMA pandapay;
    CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$;
    CREATE TABLE public.profiles(id uuid PRIMARY KEY);
    ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
    ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
    CREATE POLICY profiles_owner ON public.profiles FOR ALL USING(id=pandapay.uid()) WITH CHECK(id=pandapay.uid());
    CREATE TABLE public.transactions(id uuid PRIMARY KEY,profile_id uuid,amount_inr numeric(12,2),occurred_at timestamptz,status text,entry_kind text,source text,instrument text,updated_at timestamptz,pipeline_version smallint,event_id text,source_key text);
    CREATE TABLE public.sms_v2_events(event_id text PRIMARY KEY,profile_id uuid,type text,status text,amount_minor bigint,updated_at timestamptz);
    CREATE TABLE public.sms_v2_instruments(instrument_id uuid PRIMARY KEY,profile_id uuid,status text,updated_at timestamptz);
    CREATE TABLE public.sms_v2_ledger_entries(entry_id text PRIMARY KEY,profile_id uuid,event_id text,from_instrument_id uuid,from_external text,from_own_unresolved text,to_instrument_id uuid,to_external text,to_own_unresolved text,amount_minor bigint,unit text,is_spend boolean,counts_as_transaction boolean,updated_at timestamptz);
    CREATE TABLE public.foreign_payments(id uuid PRIMARY KEY,profile_id uuid,transaction_id uuid,valuation_status text,billed_inr numeric(12,2),original_currency text,original_amount numeric(26,4),direction text,confirmation_source text,revision int,updated_at timestamptz);
    DO $$ DECLARE n text; BEGIN FOREACH n IN ARRAY ARRAY['transactions','sms_v2_events','sms_v2_instruments','sms_v2_ledger_entries','foreign_payments'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n); EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',n); EXECUTE format('CREATE POLICY owner_scope ON public.%I FOR ALL USING(profile_id=pandapay.uid()) WITH CHECK(profile_id=pandapay.uid())',n); END LOOP; END $$;
  `);
  const sql = fs.readFileSync(path.resolve(__dirname, '../supabase/migrations/20261112210000_shared_expenses_foundation.sql'), 'utf8');
  for (const [index, statement] of statements(transactionalSql(sql)).entries()) {
    try { await db.query(statement); } catch (error) { error.message += ` [migration statement ${index}]`; throw error; }
  }
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261112213000_shared_expense_totals.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261112220000_shared_expense_bill_metadata.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261112230000_shared_expense_review_indexes.sql'),'utf8'));
  // Replay the pre-existing role setup's broad grants. A new isolated schema
  // must retain its ACL even when public and pandapay grants are restored.
  await db.query('GRANT USAGE ON SCHEMA public,pandapay TO app_user; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO app_user; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pandapay TO app_user');
  const a='10000000-0000-0000-0000-000000000001', b='10000000-0000-0000-0000-000000000002';
  const tx='20000000-0000-0000-0000-000000000001', ctx='30000000-0000-0000-0000-000000000001', op='40000000-0000-0000-0000-000000000001';
  await db.query('INSERT INTO public.profiles VALUES($1),($2)',[a,b]);
  await db.query("INSERT INTO public.transactions VALUES($1,$2,1200,now(),'active','spend','manual','cash',now(),1,null,null)",[tx,a]);
  async function actor(id, callback) { await db.query('SAVEPOINT request'); try { await db.query('SET LOCAL ROLE app_user'); await db.query("SELECT set_config('app.user_id',$1,true)",[id]); const result=await callback(); await db.query('RESET ROLE'); await db.query('RELEASE SAVEPOINT request'); return result; } catch(error) { await db.query('ROLLBACK TO SAVEPOINT request'); await db.query('RELEASE SAVEPOINT request'); throw error; } }
  await actor(a,async()=> {
    const cap=(await db.query('SELECT shared_expenses.capabilities() AS v')).rows[0].v;
    assert.equal(cap.acceptedWrites,false); assert.equal(cap.proposals,false);
  });
  await assert.rejects(actor(a,()=>db.query('INSERT INTO shared_expenses.contexts(context_id,kind,name,created_by) VALUES($1,\'group\',\'x\',$2)',[ctx,a])), /permission denied/);
  await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'group\',\'Flatmates\',$2,$3)',[ctx,op,'a'.repeat(64)])), /feature_disabled/);
  await db.query('UPDATE shared_expenses.settings SET reads_enabled=true,proposals_enabled=true');
  const result=await actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'group\',\'Flatmates\',$2,$3) AS v',[ctx,op,'a'.repeat(64)]));
  const replay=await actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'group\',\'Flatmates\',$2,$3) AS v',[ctx,op,'a'.repeat(64)]));
  assert.deepEqual(replay.rows[0].v,result.rows[0].v);
  await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'group\',\'Changed\',$2,$3)',[ctx,op,'a'.repeat(64)])), /operation_conflict/);
  assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.contexts'))).rowCount,0);
  const ref={kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:tx,sourceVersion:'pending'};
  await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.admit_source($1::jsonb)',[JSON.stringify(ref)])), /source_not_authorized/);
  await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.admit_source($1::jsonb)',[JSON.stringify(ref)])), /source_version_mismatch/);
  // Version discovery is separate from expected-version admission, so no client
  // token can manufacture funding evidence.
  const fresh={kind:'sms_v2_event',ownerAccountId:a,eventId:'f'.repeat(64)};
  await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1::jsonb)',[JSON.stringify(fresh)])), /source_not_eligible/);
  const catalog=await db.query("SELECT c.relname,c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='shared_expenses' AND c.relkind='r'");
  assert.ok(catalog.rows.length>=20); assert.ok(catalog.rows.every(row=>row.relforcerowsecurity));
  const noCrud=await db.query("SELECT bool_and(NOT has_table_privilege('app_user',c.oid,'INSERT,UPDATE,DELETE')) AS safe FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='shared_expenses' AND c.relkind='r'");
  assert.equal(noCrud.rows[0].safe,true);
  const roles=await db.query("SELECT rolname,rolsuper,rolbypassrls,rolcanlogin FROM pg_roles WHERE rolname IN ('app_user','shared_expenses_owner')");
  assert.ok(roles.rows.every(row=>!row.rolsuper&&!row.rolbypassrls));
  assert.equal(roles.rows.find(row=>row.rolname==='shared_expenses_owner').rolcanlogin,false);
  assert.equal((await db.query("SELECT pg_has_role('app_user','shared_expenses_owner','MEMBER') AS inherited")).rows[0].inherited,false);

  // All following financial fixtures stay inside this disposable transaction.
  // Membership seeding is an admin fixture, not an implemented invitation flow.
  const c='10000000-0000-0000-0000-000000000003';
  const ma=result.rows[0].v.memberId, mb='50000000-0000-0000-0000-000000000002', mc='50000000-0000-0000-0000-000000000003';
  await db.query('INSERT INTO public.profiles VALUES($1)',[c]);
  await t.test('owner invitations create pending membership without consenting to financial debt',async()=>{
    const invitedCtx=crypto.randomUUID(), invited=crypto.randomUUID();
    await actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'direct\',\'Synthetic friend\',$2,$3)',[invitedCtx,crypto.randomUUID(),'c'.repeat(64)]));
    const payload={contextId:invitedCtx,memberId:invited,profileId:b,displayName:'Synthetic friend'};
    const invite=await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3) AS v',[payload,crypto.randomUUID(),'d'.repeat(64)]));
    assert.equal(invite.rows[0].v.status,'invited');
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2',[invitedCtx,invited])).rows[0].state,'invited');
    assert.equal((await actor(b,()=>db.query('SELECT context_id FROM shared_expenses.contexts WHERE context_id=$1',[invitedCtx]))).rowCount,1);
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.profile_events WHERE context_id=$1',[invitedCtx]))).rowCount,1);
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.context_events WHERE context_id=$1',[invitedCtx]))).rowCount,1);
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.pair_balances WHERE context_id=$1',[invitedCtx]))).rowCount,0);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:invitedCtx,memberId:crypto.randomUUID(),displayName:'Third identity'},crypto.randomUUID(),'e'.repeat(64)])),/context_member_limit/);
    await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:invitedCtx,memberId:crypto.randomUUID(),displayName:'Not owner'},crypto.randomUUID(),'e'.repeat(64)])),/context_not_authorized/);
    const joined=await actor(b,()=>db.query('SELECT shared_expenses.respond_membership($1,$2,true,$3,$4) AS v',[invitedCtx,invited,crypto.randomUUID(),'f'.repeat(64)]));
    assert.equal(joined.rows[0].v.status,'joined');
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.revision_approvals WHERE context_id=$1',[invitedCtx])).rows[0].n,0);
  });
  await db.query("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state) VALUES($1,$2,$3,'member','active'),($1,$4,$5,'member','active')",[ctx,mb,b,mc,c]);
  async function command(who,fn,payload,operation=crypto.randomUUID()) {
    return (await actor(who,()=>db.query(`SELECT shared_expenses.${fn}($1::jsonb,$2::uuid,$3::text) AS v`,[JSON.stringify(payload),operation,crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex')]))).rows[0].v;
  }
  const exp=crypto.randomUUID(), rev=crypto.randomUUID();
  function proposal(revision,total,share,previous=null) { return {contextId:ctx,expenseId:exp,revisionId:revision,expectedHeadRevisionId:previous,snapshot:{currency:'INR',totalMinor:String(total),contributions:[{memberId:ma,amountMinor:String(total)}],shares:[ma,mb,mc].map(memberId=>({memberId,amountMinor:String(share)})),memberOrder:[ma,mb,mc]},title:'Synthetic dinner',occurredOn:'2026-11-04',sources:[],void:false}; }
  async function balances() { const rows=(await db.query('SELECT member_id,balance_minor::text FROM shared_expenses.member_balances WHERE context_id=$1',[ctx])).rows; return Object.fromEntries(rows.map(row=>[row.member_id,row.balance_minor])); }
  await t.test('all affected parties approve the whole revision before accepted balances change',async()=>{
    const first=await command(a,'submit_proposal',proposal(rev,120000,40000));
    assert.equal(first.status,'awaiting_approval'); assert.deepEqual(await balances(),{});
    const queries=requireApi('./src/shared_expenses/queries');
    const pending=await actor(b,()=>queries.listContextExpenses(db,b,ctx,{}));
    const pendingRow=pending.items.find(item=>item.expenseId===exp);
    assert.equal(pendingRow.totalMinor,null,'pending money must not impersonate accepted money');
    assert.equal(pendingRow.pendingRevision.revisionId,rev);
    assert.equal(pendingRow.pendingRevision.totalMinor,'120000');
    const contextList=await actor(b,()=>queries.listContexts(db,b,{}));
    assert.equal(contextList.items.find(item=>item.contextId===ctx).hasUnacceptedExpenses,true);
    const review=await actor(b,()=>queries.listExpenseRevisions(db,b,ctx,exp,{}));
    assert.equal(review.items[0].reviewState,'awaiting_approval');
    assert.equal(review.items[0].canRespond,true);
    const authorReview=await actor(a,()=>queries.listExpenseRevisions(db,a,ctx,exp,{}));
    assert.equal(authorReview.items[0].yourDecision,'approve');
    assert.equal(authorReview.items[0].canRespond,false);
    assert.equal((await command(b,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:rev,decision:'approve'})).status,'awaiting_approval');
    assert.equal((await command(c,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:rev,decision:'approve'})).status,'awaiting_activation');
    assert.deepEqual(await balances(),{});
    await db.query('UPDATE shared_expenses.settings SET accepted_writes_enabled=true,settlements_enabled=true');
    assert.equal((await command(c,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:rev,decision:'approve'})).status,'accepted');
    assert.deepEqual(await balances(),{[ma]:'80000',[mb]:'-40000',[mc]:'-40000'});
    const acceptedPage=await actor(b,()=>queries.listContextExpenses(db,b,ctx,{}));
    assert.equal(acceptedPage.items.find(item=>item.expenseId===exp).pendingRevision,null);
    const acceptedReview=await actor(b,()=>queries.listExpenseRevisions(db,b,ctx,exp,{}));
    assert.equal(acceptedReview.items[0].reviewState,'accepted');
    assert.equal(acceptedReview.items[0].canRespond,false);
    await assert.rejects(actor(b,()=>db.query('SELECT source_links FROM shared_expenses.expense_revisions')),/permission denied/);
    assert.equal((await actor(b,()=>db.query('SELECT revision_id,snapshot,projection_version FROM shared_expenses.expense_revisions'))).rows[0].projection_version,'pair_v1');
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses._post_pair($1,$2,0::smallint,$3,$4,1,\'revision\',$2)',[ctx,crypto.randomUUID(),mb,mc])),/permission denied/);
  });
  await t.test('partial payments post only after receiver confirmation, once, without changing private costs',async()=>{
    const sid=crypto.randomUUID(), report={contextId:ctx,settlementId:sid,payerMemberId:mb,receiverMemberId:ma,amountMinor:'30000',currency:'INR',method:'upi',paidOn:'2026-11-04'};
    assert.equal((await command(b,'report_settlement',report)).status,'awaiting_receiver_confirmation');
    assert.equal((await balances())[mb],'-40000');
    await assert.rejects(command(b,'respond_settlement',{contextId:ctx,settlementId:sid,decision:'confirm'}),/receiver_confirmation_required/);
    const response={contextId:ctx,settlementId:sid,decision:'confirm'}, operation=crypto.randomUUID();
    const confirmed=await command(a,'respond_settlement',response,operation);
    assert.deepEqual(await command(a,'respond_settlement',response,operation),confirmed);
    assert.equal((await balances())[mb],'-10000');
    const allocation=(await db.query('SELECT kind,amount_minor::text FROM shared_expenses.settlement_allocations WHERE event_id=$1',[confirmed.eventId])).rows;
    assert.deepEqual(allocation,[{kind:'pair_balance',amount_minor:'30000'}]);
    assert.equal((await db.query('SELECT share_minor::text FROM shared_expenses.private_cost_facts WHERE profile_id=$1 AND expense_id=$2',[b,exp])).rows[0].share_minor,'40000');
    assert.equal((await command(a,'respond_settlement',response)).status,'confirmed');
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE settlement_id=$1',[sid])).rows[0].n,1);
    const csid=crypto.randomUUID();
    await command(c,'report_settlement',{...report,settlementId:csid,payerMemberId:mc,amountMinor:'40000'});
    await command(a,'respond_settlement',{contextId:ctx,settlementId:csid,decision:'confirm'});
    assert.deepEqual(await balances(),{[ma]:'10000',[mb]:'-10000',[mc]:'0'});
  });
  const rev2=crypto.randomUUID();
  await t.test('a settled expense correction preserves old payments and returns explicit friend credit',async()=>{
    assert.equal((await command(a,'submit_proposal',proposal(rev2,90000,30000,rev))).status,'awaiting_approval');
    assert.deepEqual(await balances(),{[ma]:'10000',[mb]:'-10000',[mc]:'0'});
    await command(b,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:rev2,decision:'approve'});
    await command(c,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:rev2,decision:'approve'});
    assert.deepEqual(await balances(),{[ma]:'-10000',[mb]:'0',[mc]:'10000'});
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE context_id=$1',[ctx])).rows[0].n,2);
    await assert.rejects(command(a,'submit_proposal',proposal(crypto.randomUUID(),90000,30000,rev)),/revision_head_conflict/);
    await assert.rejects(actor(a,()=>db.query('UPDATE shared_expenses.expense_revisions SET total_minor=1 WHERE revision_id=$1',[rev2])),/permission denied/);
  });
  await t.test('approved void reverses expense debt and retains confirmed payment refund obligations',async()=>{
    const voidRev=crypto.randomUUID(), payload={...proposal(voidRev,90000,30000,rev2),snapshot:null,void:true};
    await command(a,'submit_proposal',payload);
    await command(b,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:voidRev,decision:'approve'});
    await command(c,'respond_expense',{contextId:ctx,expenseId:exp,revisionId:voidRev,decision:'approve'});
    assert.deepEqual(await balances(),{[ma]:'-70000',[mb]:'30000',[mc]:'40000'});
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE context_id=$1',[ctx])).rows[0].n,2);
  });
  await t.test('an overpayment retains explicit pair credit and never crosses into another friend balance',async()=>{
    const sid=crypto.randomUUID();
    await command(a,'report_settlement',{contextId:ctx,settlementId:sid,payerMemberId:ma,receiverMemberId:mb,amountMinor:'50000',currency:'INR',method:'bank',paidOn:'2026-11-04',reference:'synthetic-reference'});
    await assert.rejects(actor(b,()=>db.query('SELECT reference FROM shared_expenses.settlement_private_references WHERE settlement_id=$1',[sid])),/permission denied/);
    const confirmed=await command(b,'respond_settlement',{contextId:ctx,settlementId:sid,decision:'confirm'});
    assert.deepEqual((await db.query('SELECT kind,amount_minor::text FROM shared_expenses.settlement_allocations WHERE event_id=$1 ORDER BY ordinal',[confirmed.eventId])).rows,[{kind:'pair_balance',amount_minor:'30000'},{kind:'pair_credit',amount_minor:'20000'}]);
    assert.deepEqual(await balances(),{[ma]:'-20000',[mb]:'-20000',[mc]:'40000'});
    assert.equal((await db.query('SELECT reference FROM shared_expenses.settlement_private_references WHERE settlement_id=$1',[sid])).rows[0].reference,'synthetic-reference');
    // Administrative fixture proves schema separation only; the actual trusted
    // lifecycle command/retention authorization remains a separate integration.
    await db.query('DELETE FROM shared_expenses.settlement_private_references WHERE settlement_id=$1',[sid]);
    assert.equal((await db.query('SELECT amount_minor::text FROM shared_expenses.settlement_reports WHERE settlement_id=$1',[sid])).rows[0].amount_minor,'50000');
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE settlement_id=$1',[sid])).rows[0].n,1);
  });
  await t.test('linked proposals stay provisional without a verified source reservation guard',async()=>{
    const linkedExp=crypto.randomUUID(), linkedRev=crypto.randomUUID();
    const payload={...proposal(linkedRev,120000,40000),expenseId:linkedExp,sources:[{payerMemberId:ma,amountMinor:'120000',reference:{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:tx,sourceVersion:'f'.repeat(64)}}]};
    const before=await balances();
    await command(a,'submit_proposal',payload);
    await command(b,'respond_expense',{contextId:ctx,expenseId:linkedExp,revisionId:linkedRev,decision:'approve'});
    assert.equal((await command(c,'respond_expense',{contextId:ctx,expenseId:linkedExp,revisionId:linkedRev,decision:'approve'})).status,'awaiting_source_authorization');
    assert.deepEqual(await balances(),before);
    assert.equal((await db.query('SELECT accepted_revision_id FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2',[ctx,linkedExp])).rows[0].accepted_revision_id,null);
    await assert.rejects(command(a,'submit_proposal',{...payload,expenseId:crypto.randomUUID(),revisionId:crypto.randomUUID(),sources:[{...payload.sources[0],amountMinor:'120001'}]}),/source_overallocated/);
    await assert.rejects(command(a,'submit_proposal',{...payload,expenseId:crypto.randomUUID(),revisionId:crypto.randomUUID(),sources:[{...payload.sources[0],reference:{...payload.sources[0].reference,ownerAccountId:b}}]}),/source_overallocated/);
  });
  await t.test('source discovery resolves actual v2 ownership, posted leg, instrument and current fingerprint',async()=>{
    const vtx=crypto.randomUUID(), instrument=crypto.randomUUID(), event='e'.repeat(64), entry='d'.repeat(64);
    await db.query("INSERT INTO public.transactions VALUES($1,$2,100,now(),'active','spend','sms','credit_card',now(),2,$3,null)",[vtx,a,event]);
    await db.query("INSERT INTO public.sms_v2_events VALUES($1,$2,'purchase','complete',10000,now())",[event,a]);
    await db.query("INSERT INTO public.sms_v2_instruments VALUES($1,$2,'confirmed',now())",[instrument,a]);
    await db.query("INSERT INTO public.sms_v2_ledger_entries VALUES($1,$2,$3,$4,null,null,null,'Synthetic merchant',null,10000,'INR',true,true,now())",[entry,a,event,instrument]);
    const identity={kind:'sms_v2_event',ownerAccountId:a,eventId:event};
    const current=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[identity]))).rows[0].v;
    assert.equal(current.canonicalTransactionId,vtx); assert.equal(current.eligibleMinor,'10000'); assert.equal(current.eligible,true);
    const admitted=(await actor(a,()=>db.query('SELECT shared_expenses.admit_source($1) AS v',[{...identity,canonicalTransactionId:vtx,sourceVersion:current.sourceVersion}]))).rows[0].v;
    assert.equal(admitted.sourceVersion,current.sourceVersion);
    const alias=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:vtx}]))).rows[0].v;
    assert.equal(alias.sourceVersion,current.sourceVersion);
    await db.query("SET LOCAL timezone='Asia/Kolkata'");
    const timezoneSnapshot=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[identity]))).rows[0].v;
    assert.equal(timezoneSnapshot.sourceVersion,current.sourceVersion);
    await db.query("SET LOCAL timezone='UTC'");
    await db.query("UPDATE public.sms_v2_events SET type='p2p_out',status='user_confirmed' WHERE event_id=$1",[event]);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1)',[identity])),/source_not_eligible/);
    await db.query("UPDATE public.sms_v2_events SET type='purchase',status='complete' WHERE event_id=$1",[event]);
    await db.query('UPDATE public.sms_v2_ledger_entries SET amount_minor=9999 WHERE entry_id=$1',[entry]);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1)',[identity])),/source_not_eligible/);
    await db.query('UPDATE public.sms_v2_ledger_entries SET amount_minor=10000 WHERE entry_id=$1',[entry]);
    await db.query("UPDATE public.sms_v2_instruments SET status='rejected' WHERE instrument_id=$1",[instrument]);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.admit_source($1)',[{...identity,canonicalTransactionId:vtx,sourceVersion:current.sourceVersion}])),/source_not_eligible/);
    const legacy=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:tx}]))).rows[0].v;
    assert.equal(legacy.requiresReview,true); assert.equal(legacy.eligible,false);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.admit_source($1)',[{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:tx,sourceVersion:legacy.sourceVersion}])),/source_explicit_review_required/);
  });
  await t.test('foreign valuation and canonical aliases cannot bypass review or billed amount truth',async()=>{
    const fxid=crypto.randomUUID(), fxtx=crypto.randomUUID();
    await db.query("INSERT INTO public.transactions VALUES($1,$2,100,now(),'active','spend','manual','debit_card',now(),1,null,null)",[fxtx,a]);
    await db.query("INSERT INTO public.foreign_payments VALUES($1,$2,$3,'confirmed',100,'USD',2,'spend','user',1,now())",[fxid,a,fxtx]);
    const identity={kind:'confirmed_foreign_payment',ownerAccountId:a,canonicalTransactionId:fxtx,foreignPaymentId:fxid};
    const fx=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[identity]))).rows[0].v;
    assert.equal(fx.foreignPaymentId,fxid); assert.equal(fx.requiresReview,true);
    const canonical=(await actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1) AS v',[{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:fxtx}]))).rows[0].v;
    assert.equal(canonical.sourceVersion,fx.sourceVersion);
    await db.query("UPDATE public.foreign_payments SET valuation_status='estimated',revision=2 WHERE id=$1",[fxid]);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1)',[identity])),/source_not_eligible/);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1)',[{kind:'legacy_transaction',ownerAccountId:a,canonicalTransactionId:fxtx}])),/source_not_eligible/);
    await db.query("UPDATE public.foreign_payments SET valuation_status='confirmed',billed_inr=101,revision=3 WHERE id=$1",[fxid]);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.inspect_source($1)',[identity])),/source_not_eligible/);
  });
  await t.test('stored projection v1 matches pure fixtures and rejects malformed money before posting',async()=>{
    const {projectExpense}=requireApi('./src/shared_expenses/domain');
    const vectors=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../contracts/shared_expenses/v1/domain_vectors.json'),'utf8')).projection;
    const ids={priya:mc,rahul:mb,you:ma};
    for(const vector of vectors) {
      const snapshot={...vector.input,contributions:vector.input.contributions.map(row=>({...row,memberId:ids[row.memberId]})),shares:vector.input.shares.map(row=>({...row,memberId:ids[row.memberId]})),memberOrder:vector.input.memberOrder.map(id=>ids[id])};
      const expected=projectExpense(snapshot);
      const actual=(await db.query('SELECT shared_expenses._project_snapshot($1) AS v',[snapshot])).rows[0].v;
      assert.deepEqual(actual,expected,vector.id);
    }
    for(const bad of ['01','1.5','1e5','-1',true,null,10000]) {
      const snapshot={...proposal(crypto.randomUUID(),90000,30000).snapshot,totalMinor:bad};
      await db.query('SAVEPOINT malformed');
      await assert.rejects(db.query('SELECT shared_expenses._project_snapshot($1)',[snapshot]));
      await db.query('ROLLBACK TO SAVEPOINT malformed'); await db.query('RELEASE SAVEPOINT malformed');
    }
  });
  await t.test('circular debt remains three scoped edges even when every member has zero net',async()=>{
    // Create a second context so the completed refund fixture remains intact.
    const circularCtx=crypto.randomUUID();
    await actor(a,()=>db.query('SELECT shared_expenses.create_context($1,\'group\',\'Synthetic circle\',$2,$3)',[circularCtx,crypto.randomUUID(),'b'.repeat(64)]));
    const ca=(await db.query('SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND profile_id=$2',[circularCtx,a])).rows[0].member_id;
    await db.query("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state) VALUES($1,$2,$3,'member','active'),($1,$4,$5,'member','active')",[circularCtx,mb,b,mc,c]);
    for(const [payer,debtor,owner,reviewer] of [[ca,mb,a,b],[mb,mc,b,c],[mc,ca,c,a]]) {
      const e=crypto.randomUUID(),revision=crypto.randomUUID();
      await command(owner,'submit_proposal',{contextId:circularCtx,expenseId:e,revisionId:revision,expectedHeadRevisionId:null,snapshot:{currency:'INR',totalMinor:'100',contributions:[{memberId:payer,amountMinor:'100'}],shares:[{memberId:debtor,amountMinor:'100'}],memberOrder:[payer,debtor]},title:'Circle',occurredOn:'2026-11-04',sources:[],void:false});
      await command(reviewer,'respond_expense',{contextId:circularCtx,expenseId:e,revisionId:revision,decision:'approve'});
    }
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.pair_balances WHERE context_id=$1',[circularCtx])).rows[0].n,3);
    assert.ok((await db.query('SELECT balance_minor::text b FROM shared_expenses.member_balances WHERE context_id=$1',[circularCtx])).rows.every(row=>row.b==='0'));
    // Synthetic high-gross circular positions exercise the actual command's
    // aggregate guard without millions of repeated writes or a fake parser.
    const members=[ca,mb,mc].sort();
    await db.query('DELETE FROM shared_expenses.pair_balances WHERE context_id=$1',[circularCtx]);
    const magnitude='3002399751580330'; // 3*magnitude = MAX_SAFE_INTEGER-1.
    for(const [low,high,sign] of [[members[0],members[1],1],[members[1],members[2],1],[members[0],members[2],-1]]) await db.query('INSERT INTO shared_expenses.pair_balances VALUES($1,\'INR\',$2,$3,$4)',[circularCtx,low,high,sign===1?magnitude:'-'+magnitude]);
    const receiver=members[0],payer=members[2];
    const whoById={[ca]:a,[mb]:b,[mc]:c};
    const sid=crypto.randomUUID();
    await command(whoById[payer],'report_settlement',{contextId:circularCtx,settlementId:sid,payerMemberId:payer,receiverMemberId:receiver,amountMinor:'100',currency:'INR',method:'cash',paidOn:'2026-11-04'});
    await assert.rejects(command(whoById[receiver],'respond_settlement',{contextId:circularCtx,settlementId:sid,decision:'confirm'}),/aggregate_limit_exceeded/);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE settlement_id=$1',[sid])).rows[0].n,0);
    assert.equal((await db.query('SELECT sum(abs(balance_minor::numeric))::text gross FROM shared_expenses.pair_balances WHERE context_id=$1',[circularCtx])).rows[0].gross,'9007199254740990');
  });
  await t.test('P03 read repository executes on actual app_user RLS and approved column ACL',async()=>{
    const queries=requireApi('./src/shared_expenses/queries');
    const contexts=await actor(a,()=>queries.listContexts(db,a,{limit:'1'}));
    assert.equal(contexts.items.length,1); assert.equal(contexts.hasMore,true);
    assert.equal((await actor(a,()=>queries.listContexts(db,a,{limit:'1',after:contexts.nextCursor}))).items.length,1);
    assert.equal((await actor(a,()=>queries.listContextMembers(db,a,ctx))).items.length,3);
    assert.ok((await actor(a,()=>queries.listContextExpenses(db,a,ctx))).items.some(item=>item.expenseId===exp));
    assert.ok((await actor(a,()=>queries.readBalances(db,a,ctx))).items.length>0);
    const activity=await actor(a,()=>queries.listContextActivity(db,a,ctx));
    assert.ok(activity.items.some(item=>item.kind==='settlement.confirmed'));
    assert.ok((await actor(a,()=>queries.listChanges(db,a))).items.length>0);
    assert.equal((await actor(a,()=>queries.readOperation(db,a,op))).state,'committed');
    assert.ok(!JSON.stringify(activity).includes('private_reference'));
  });
  await t.test('current context totals exactly match accepted revisions after payments, edits and void',async()=>{
    const {readOverview,readContextTotals}=requireApi('./src/shared_expenses/queries');
    const expected=await db.query(`SELECT coalesce(sum(r.total_minor),0)::text total_minor,count(*) FILTER(WHERE NOT r.is_void)::text expense_count FROM shared_expenses.expenses e JOIN shared_expenses.expense_revisions r ON r.context_id=e.context_id AND r.expense_id=e.expense_id AND r.revision_id=e.accepted_revision_id WHERE e.context_id=$1`,[ctx]);
    const actual=await actor(a,()=>readContextTotals(db,a,ctx));
    assert.equal(actual.sharedTotalMinor,expected.rows[0].total_minor);
    assert.equal(actual.expenseCount,expected.rows[0].expense_count);
    const overview=await actor(a,()=>readOverview(db,a));
    assert.equal(BigInt(overview.owedMinor)-BigInt(overview.owingMinor),BigInt(overview.netMinor));
    await assert.rejects(actor(a,()=>db.query('UPDATE shared_expenses.member_totals SET share_minor=0')),/permission denied/);
  });
  await t.test('P03 bounded projection feed materializes every branch through real actor RLS',async()=>{
    const queries=requireApi('./src/shared_expenses/queries');
    const records=[],granted=new Set();let after;let finished=false;
    for(let page=0;page<300;page++){
      const result=await actor(a,()=>queries.pullProjectionChanges(db,a,{limit:'7',...(after?{after}:{} )}));
      records.push(...result.records);for(const context of result.grantedContextIds)granted.add(context);
      if(!result.hasMore){finished=true;break;}
      assert.ok(result.nextCursor&&result.nextCursor!==after,'feed must make cursor progress');
      after=result.nextCursor;
    }
    assert.equal(finished,true);
    for(const entity of ['contexts','members','expenses','balances','activity','personal_cost'])assert.ok(records.some(record=>record.entity===entity),entity);
    assert.ok(granted.has(ctx));
    assert.ok(!JSON.stringify(records).includes('synthetic-reference'));
    assert.ok(!JSON.stringify(records).includes('source_links'));
    assert.ok(!JSON.stringify(records).includes('private_snapshot'));
  });
  await t.test('full bill and split mode are immutable consent data with exact independent sums',async()=>{
    const {executeCommand}=requireApi('./src/shared_expenses/commands');
    const mine=(await db.query('SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND profile_id=$2',[ctx,a])).rows[0].member_id;
    const payload={contextId:ctx,expenseId:crypto.randomUUID(),revisionId:crypto.randomUUID(),expectedHeadRevisionId:null,
      title:'Partial shared bill',occurredOn:'2026-11-04',void:false,sources:[],
      snapshot:{currency:'INR',totalMinor:'120000',contributions:[{memberId:mine,amountMinor:'120000'}],shares:[{memberId:mine,amountMinor:'120000'}],memberOrder:[mine]},
      bill:{currency:'INR',totalMinor:'140000',contributions:[{memberId:mine,amountMinor:'140000'}],allocation:{mode:'equal',participants:[{memberId:mine}],tieOrder:[mine]}}};
    await actor(a,()=>executeCommand(db,{schemaVersion:1,operationId:crypto.randomUUID(),kind:'expense.propose',payload}));
    const saved=await actor(a,()=>db.query('SELECT total_minor::text,bill,revision_hash FROM shared_expenses.expense_revisions WHERE revision_id=$1',[payload.revisionId]));
    assert.equal(saved.rows[0].total_minor,'120000');assert.deepEqual(saved.rows[0].bill,payload.bill);
    const hash=(await db.query("SELECT encode(sha256(convert_to($1::jsonb::text,'UTF8')),'hex') hash",[JSON.stringify(payload)])).rows[0].hash;
    assert.equal(saved.rows[0].revision_hash,hash);
    await assert.rejects(actor(a,()=>db.query('UPDATE shared_expenses.expense_revisions SET bill=NULL WHERE revision_id=$1',[payload.revisionId])),/permission denied/);
    await db.query('SAVEPOINT immutable_bill');
    await assert.rejects(db.query('UPDATE shared_expenses.expense_revisions SET bill=NULL WHERE revision_id=$1',[payload.revisionId]),/immutable/);
    await db.query('ROLLBACK TO immutable_bill');
    for(const change of [
      {totalMinor:'110000'},
      {contributions:[{memberId:mine,amountMinor:'139999'}]},
      {allocation:{mode:'exact',participants:[{memberId:mine,amountMinor:'119999'}],tieOrder:[mine]}},
      {allocation:{mode:'percentage',participants:[{memberId:mine,weight:'9999'}],tieOrder:[mine]}},
      {allocation:{mode:'shares',participants:[{memberId:mine,weight:'0'}],tieOrder:[mine]}},
    ]) {
      const invalid={...payload,expenseId:crypto.randomUUID(),revisionId:crypto.randomUUID(),bill:{...payload.bill,...change}};
      await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.submit_proposal($1::jsonb,$2::uuid,$3)',[JSON.stringify(invalid),crypto.randomUUID(),'e'.repeat(64)])),/invalid_bill/);
    }
    const {allocateExpense}=requireApi('./src/shared_expenses/domain');
    const ids=[mine,crypto.randomUUID(),crypto.randomUUID()];
    for(const [mode,total,weights] of [['equal','1',[]],['equal','100',[]],['percentage','1000000000',['3334','3333','3333']],['shares','999999999',['0','1000000','1']],['exact','100',['0','33','67']]]) {
      const participants=ids.map((memberId,index)=>({memberId,...(mode==='equal'?{}:{[mode==='exact'?'amountMinor':'weight']:weights[index]})}));
      const allocation={mode,participants,tieOrder:ids};
      const financial={currency:'INR',totalMinor:total,contributions:[{memberId:mine,amountMinor:total}],shares:allocateExpense({currency:'INR',totalMinor:total,...allocation}).allocations,memberOrder:ids};
      const full={currency:'INR',totalMinor:total,contributions:financial.contributions,allocation};
      await db.query('SELECT shared_expenses._validate_bill($1::jsonb,$2::jsonb)',[JSON.stringify(full),JSON.stringify(financial)]);
    }
    const legacy=(await db.query('SELECT bill FROM shared_expenses.expense_revisions WHERE revision_id<>$1 LIMIT 1',[payload.revisionId])).rows[0];
    assert.equal(legacy.bill,null);
    const outsider='10000000-0000-0000-0000-000000000099';
    assert.equal((await actor(outsider,()=>db.query('SELECT bill FROM shared_expenses.expense_revisions WHERE revision_id=$1',[payload.revisionId]))).rowCount,0);
  });

});
