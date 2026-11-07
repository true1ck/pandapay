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
    CREATE TABLE public.profiles(id uuid PRIMARY KEY,display_name text);
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
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261113000000_shared_expense_invitations.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261114000000_shared_expense_phone_directory.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261114010000_shared_expense_context_label.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261114020000_shared_expense_group_links.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261114030000_shared_expense_membership_exit.sql'),'utf8'));
  await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261114040000_shared_expense_owner_and_former.sql'),'utf8'));
  for (const file of ['20261116080000_shared_expense_invitation_audience.sql', '20261116090100_shared_expense_member_labels.sql', '20261116100100_shared_expense_join_identity.sql']) await db.query(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/'+file),'utf8'));
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
  await t.test('verified phone claims retain old member identity and require a separate financial approval',async()=>{
    const group=crypto.randomUUID(), member=crypto.randomUUID(), invitation=crypto.randomUUID(), expense=crypto.randomUUID(), revision=crypto.randomUUID();
    const own=(await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'direct','Claim fixture',$2,$3) AS v",[group,crypto.randomUUID(),'1'.repeat(64)]))).rows[0].v.memberId;
    await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:group,memberId:member,displayName:'Unregistered friend'},crypto.randomUUID(),'2'.repeat(64)]));
    const proposal={contextId:group,expenseId:expense,revisionId:revision,expectedHeadRevisionId:null,title:'Historical dinner',occurredOn:'2026-11-05',snapshot:{currency:'INR',totalMinor:'10000',memberOrder:[own,member],contributions:[{memberId:own,amountMinor:'10000'}],shares:[{memberId:own,amountMinor:'5000'},{memberId:member,amountMinor:'5000'}]},sources:[],void:false};
    await actor(a,()=>db.query('SELECT shared_expenses.submit_proposal($1,$2,$3)',[proposal,crypto.randomUUID(),'3'.repeat(64)]));
    const before=(await db.query('SELECT approver_profile_id,paid_minor,share_minor FROM shared_expenses.revision_members WHERE context_id=$1 AND member_id=$2',[group,member])).rows;
    const payload={invitationId:invitation,contextId:group,memberId:member,targetPhoneHash:'4'.repeat(64),tokenHash:'5'.repeat(64)};
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[payload,'6'.repeat(64)]));
    await assert.rejects(actor(c,()=>db.query('SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5)',['5'.repeat(64),'0'.repeat(64),'0000',crypto.randomUUID(),'7'.repeat(64)])),/invitation_phone_mismatch/);
    const operation=crypto.randomUUID(),claim=()=>actor(b,()=>db.query('SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5) AS v',['5'.repeat(64),'4'.repeat(64),'3210',operation,'8'.repeat(64)]));
    assert.equal((await claim()).rows[0].v.status,'joined');
    assert.equal((await claim()).rows[0].v.status,'joined');
    assert.deepEqual((await db.query('SELECT approver_profile_id,paid_minor,share_minor FROM shared_expenses.revision_members WHERE context_id=$1 AND member_id=$2',[group,member])).rows,before);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1',[group])).rows[0].n,0);
    const {listExpenseRevisions}=requireApi('./src/shared_expenses/queries');
    const read=await actor(b,()=>listExpenseRevisions(db,b,group,expense));
    assert.equal(read.items[0].yourShareMinor,'5000');assert.equal(read.items[0].canRespond,true);
    await db.query('UPDATE shared_expenses.settings SET accepted_writes_enabled=true');
    const approved=await actor(b,()=>db.query('SELECT shared_expenses.respond_expense($1,$2,$3) AS v',[{contextId:group,expenseId:expense,revisionId:revision,decision:'approve'},crypto.randomUUID(),'9'.repeat(64)]));
    assert.equal(approved.rows[0].v.status,'accepted');
    await db.query('UPDATE shared_expenses.settings SET accepted_writes_enabled=false');
    assert.equal((await actor(b,()=>db.query('SELECT share_minor::text share FROM shared_expenses.private_cost_facts WHERE context_id=$1',[group]))).rows[0].share,'5000');
    await assert.rejects(actor(c,()=>db.query('SELECT * FROM shared_expenses.invitations')),/permission denied/);
  });
  await t.test('forwarded links need owner approval and are revocable without posting money',async()=>{
    const group=crypto.randomUUID(), member=crypto.randomUUID(), id=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'direct','Unbound fixture',$2,$3)",[group,crypto.randomUUID(),'a'.repeat(64)]));
    await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:group,memberId:member,displayName:'Friend'},crypto.randomUUID(),'b'.repeat(64)]));
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:id,contextId:group,memberId:member,targetPhoneHash:null,tokenHash:'c'.repeat(64)},'d'.repeat(64)]));
    const claim=await actor(b,()=>db.query('SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5) AS v',['c'.repeat(64),null,null,crypto.randomUUID(),'e'.repeat(64)]));
    assert.equal(claim.rows[0].v.status,'awaiting_owner');
    const reqs=(r)=>r.rows[0].v.items;
    assert.equal(reqs(await actor(a,()=>db.query('SELECT shared_expenses.list_join_requests() AS v'))).some(i=>i.invitationId===id),true,'owner sees the request');
    assert.equal(reqs(await actor(b,()=>db.query('SELECT shared_expenses.list_join_requests() AS v'))).length,0,'the requester is not an owner');
    assert.equal(reqs(await actor(c,()=>db.query('SELECT shared_expenses.list_join_requests() AS v'))).length,0);
    assert.equal((await db.query('SELECT profile_id FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2',[group,member])).rows[0].profile_id,null);
    await assert.rejects(actor(c,()=>db.query('SELECT shared_expenses.respond_invitation($1,true,$2,$3)',[id,crypto.randomUUID(),'f'.repeat(64)])),/context_not_authorized/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.respond_invitation($1,true,$2,$3) AS v',[id,crypto.randomUUID(),'f'.repeat(64)]))).rows[0].v.status,'joined');
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1',[group])).rows[0].n,0);
  });
  await t.test('phone directory: hashed lookup, opt-out, self, rate limit and no direct table access',async()=>{
    const H=(ch)=>ch.repeat(64);
    await db.query("UPDATE public.profiles SET display_name='Rahul Kumar Sharma' WHERE id=$1",[b]);
    for(const [who,h] of [[a,H('a')],[b,H('b')],[c,H('c')]]) assert.equal((await actor(who,()=>db.query('SELECT shared_expenses.register_phone($1,NULL) AS v',[h]))).rows[0].v.registered,true);
    const look=(who,h)=>actor(who,()=>db.query('SELECT shared_expenses.lookup_phone($1) AS v',[h])).then(r=>r.rows[0].v);
    const found=await look(a,H('b'));
    assert.equal(found.found,true);assert.equal(found.displayName,'Rahul Kumar Sharma');
    assert.equal((await look(a,H('9'))).found,false);
    assert.deepEqual(await look(a,H('a')),{found:false,self:true});
    // Opting out is indistinguishable from not being registered.
    await actor(b,()=>db.query('SELECT shared_expenses.register_phone($1,false)',[H('b')]));
    assert.deepEqual(await look(a,H('b')),{found:false,self:false});
    assert.deepEqual(await look(a,H('9')),{found:false,self:false});
    assert.equal((await actor(b,()=>db.query('SELECT shared_expenses.directory_status() AS v'))).rows[0].v.discoverable,false);
    // Re-registering without a choice keeps the opt-out.
    await actor(b,()=>db.query('SELECT shared_expenses.register_phone($1,NULL)',[H('b')]));
    assert.equal((await look(a,H('b'))).found,false);
    await actor(b,()=>db.query('SELECT shared_expenses.register_phone($1,true)',[H('b')]));
    assert.equal((await look(a,H('b'))).found,true);
    // The newest verifier of a number owns the entry.
    await actor(c,()=>db.query('SELECT shared_expenses.register_phone($1,NULL)',[H('b')]));
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.phone_directory WHERE phone_hash=$1',[H('b')])).rows[0].n,1);
    await actor(b,()=>db.query('SELECT shared_expenses.register_phone($1,NULL)',[H('b')]));
    await actor(c,()=>db.query('SELECT shared_expenses.register_phone($1,NULL)',[H('c')]));
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.lookup_phone($1)',['not-a-hash'])),/invalid_phone/);
    await assert.rejects(actor(c,()=>db.query('SELECT * FROM shared_expenses.phone_directory')),/permission denied/);
    await assert.rejects(actor(c,()=>db.query('SELECT * FROM shared_expenses.phone_lookups')),/permission denied/);
    for(let n=0;n<25;n++) await look(c,crypto.randomBytes(32).toString('hex'));
    await assert.rejects(look(c,crypto.randomBytes(32).toString('hex')),/lookup_rate_limited/);
    await db.query("DELETE FROM shared_expenses.phone_lookups WHERE profile_id=$1",[c]);
  });
  await t.test('phone-bound invitations reach the verified phone by inbox, with accept, decline and guards',async()=>{
    const H=(ch)=>ch.repeat(64), ctxId=crypto.randomUUID(), member=crypto.randomUUID(), inv=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'direct','Rahul',$2,$3)",[ctxId,crypto.randomUUID(),H('1')]));
    await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:ctxId,memberId:member,displayName:'Rahul'},crypto.randomUUID(),H('2')]));
    const create=(who,payload,hash=H('3'))=>actor(who,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[payload,hash]));
    const mk=(extra)=>({invitationId:crypto.randomUUID(),contextId:ctxId,memberId:member,targetPhoneHash:H('b'),tokenHash:crypto.randomBytes(32).toString('hex'),...extra});
    await assert.rejects(create(a,mk({targetPhoneHash:H('a')})),/invitation_self/);
    await create(a,mk({invitationId:inv}),H('4'));
    const inbox=(who,h)=>actor(who,()=>db.query('SELECT shared_expenses.list_my_invitations($1) AS v',[h])).then(r=>r.rows[0].v.items);
    // A fresh link for someone already invited by phone keeps the phone binding.
    const relink=crypto.randomUUID();
    await create(a,{invitationId:relink,contextId:ctxId,memberId:member,targetPhoneHash:null,tokenHash:crypto.randomBytes(32).toString('hex')},H('e'));
    assert.equal((await db.query('SELECT target_phone_hash FROM shared_expenses.invitations WHERE invitation_id=$1',[relink])).rows[0].target_phone_hash,H('b'));
    await db.query("UPDATE shared_expenses.invitations SET state='rejected' WHERE invitation_id=$1",[relink]);
    await db.query("UPDATE shared_expenses.invitations SET state='open' WHERE invitation_id=$1",[inv]);
    const mine=await inbox(b,H('b'));
    assert.equal(mine.length,1);assert.equal(mine[0].invitationId,inv);assert.equal(mine[0].contextKind,'direct');
    assert.equal((await inbox(c,H('c'))).length,0,'another number sees nothing');
    assert.equal((await inbox(b,null)).length,0);
    const accept=(who,h,op)=>actor(who,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5) AS v',[inv,h,'3210',op,H('5')]));
    await assert.rejects(accept(c,H('c'),crypto.randomUUID()),/invitation_unavailable/);
    await assert.rejects(accept(a,H('b'),crypto.randomUUID()),/invitation_unavailable/,'the inviter cannot claim their own invitation');
    const op=crypto.randomUUID();
    assert.equal((await accept(b,H('b'),op)).rows[0].v.status,'joined');
    assert.equal((await accept(b,H('b'),op)).rows[0].v.status,'joined','replay');
    assert.equal((await db.query('SELECT profile_id FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2',[ctxId,member])).rows[0].profile_id,b);
    assert.equal((await inbox(b,H('b'))).length,0);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1',[ctxId])).rows[0].n,0,'joining posts no money');
    const {listContexts,readContext}=requireApi('./src/shared_expenses/queries');
    await db.query("UPDATE public.profiles SET display_name='Asha Verma Rao' WHERE id=$1",[a]);
    await actor(a,()=>db.query('SELECT shared_expenses.register_phone($1,NULL)',[H('a')]));
    const own=await actor(a,()=>listContexts(db,a,{kind:'direct'}));
    assert.ok(own.items.some(i=>i.contextId===ctxId&&i.name==='Rahul'),'creator keeps the name they typed');
    const seen=await actor(b,()=>listContexts(db,b,{kind:'direct'}));
    assert.equal(seen.items.find(i=>i.contextId===ctxId).name,'Asha Verma Rao','the friend sees the creator, not their own name');
    assert.equal((await actor(b,()=>readContext(db,b,ctxId))).name,'Asha Verma Rao');
    assert.ok((await actor(b,()=>listContexts(db,b,{kind:'direct',q:'asha'}))).items.some(i=>i.contextId===ctxId),'search uses the shown name');
    assert.equal((await actor(b,()=>listContexts(db,b,{kind:'direct',q:'rahul'}))).items.filter(i=>i.contextId===ctxId).length,0,'the creator-typed name is not searchable by the friend');
    const existing=await actor(c,()=>db.query('SELECT shared_expenses.lookup_phone($1) AS v',[H('b')]));
    assert.equal(existing.rows[0].v.found,true);
    const g=crypto.randomUUID(), gm1=crypto.randomUUID(), gm2=crypto.randomUUID(), gi=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Flat',$2,$3)",[g,crypto.randomUUID(),H('1')]));
    for(const [m,nm] of [[gm1,'Rahul'],[gm2,'Rahul Two']]) await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:g,memberId:m,displayName:nm},crypto.randomUUID(),H('9')]));
    await create(a,{invitationId:gi,contextId:g,memberId:gm1,targetPhoneHash:H('b'),tokenHash:crypto.randomBytes(32).toString('hex')},H('5'));
    await actor(b,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5)',[gi,H('b'),'3210',crypto.randomUUID(),H('6')]));
    await assert.rejects(create(a,{invitationId:crypto.randomUUID(),contextId:g,memberId:gm2,targetPhoneHash:H('b'),tokenHash:crypto.randomBytes(32).toString('hex')},H('7')),/invitation_already_member/,'a person already in the context cannot be invited again by number');
    // Decline: no money, owner sees a decline, re-inviting is paused for a week.
    const ctx2=crypto.randomUUID(), m2=crypto.randomUUID(), i2=crypto.randomUUID(), m3=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Trip',$2,$3)",[ctx2,crypto.randomUUID(),H('6')]));
    for(const [m,n] of [[m2,'Dev'],[m3,'Dev again']]) await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:ctx2,memberId:m,displayName:n},crypto.randomUUID(),H('7')]));
    const tok=()=>crypto.randomBytes(32).toString('hex');
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:i2,contextId:ctx2,memberId:m2,targetPhoneHash:H('d'),tokenHash:tok()},H('8')]));
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:crypto.randomUUID(),contextId:ctx2,memberId:m3,targetPhoneHash:H('d'),tokenHash:tok()},H('9')])),/invitation_duplicate/);
    const dec=(who,h)=>actor(who,()=>db.query('SELECT shared_expenses.decline_invitation($1,$2,$3,$4) AS v',[i2,h,crypto.randomUUID(),H('a')]));
    await assert.rejects(dec(c,H('c')),/invitation_unavailable/);
    assert.equal((await dec(c,H('d'))).rows[0].v.status,'declined');
    await assert.rejects(dec(c,H('d')),/invitation_unavailable/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.list_invitations($1,NULL) AS v',[ctx2]))).rows[0].v.items.find(i=>i.invitationId===i2).status,'declined');
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:crypto.randomUUID(),contextId:ctx2,memberId:m2,targetPhoneHash:H('d'),tokenHash:tok()},H('b')])),/invitation_declined_recently/);
    await assert.rejects(actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:crypto.randomUUID(),contextId:ctx2,memberId:m2,targetPhoneHash:null,tokenHash:tok()},H('c')])),/invitation_declined_recently/,'a phone-less link cannot bypass the decline pause');
    // Expired invitations vanish from the inbox and cannot be accepted.
    const i3=crypto.randomUUID();
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:i3,contextId:ctx2,memberId:m3,targetPhoneHash:H('e'),tokenHash:tok()},H('c')]));
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=$1",[i3]);
    assert.equal((await inbox(c,H('e'))).length,0);
    await assert.rejects(actor(c,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5)',[i3,H('e'),'3210',crypto.randomUUID(),H('d')])),/invitation_unavailable/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.list_invitations($1,NULL) AS v',[ctx2]))).rows[0].v.items.find(i=>i.invitationId===i3).status,'expired');
  });
  await t.test('group link: owner-controlled requests, approval, decline, revoke and limits',async()=>{
    const H=(ch)=>ch.repeat(64), g=crypto.randomUUID(), direct=crypto.randomUUID(), tok=()=>crypto.randomBytes(32).toString('hex');
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Link trip',$2,$3)",[g,crypto.randomUUID(),H('1')]));
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'direct','Just us',$2,$3)",[direct,crypto.randomUUID(),H('2')]));
    const link=(who,ctxId,token,op=crypto.randomUUID())=>actor(who,()=>db.query('SELECT shared_expenses.create_group_link($1,$2,$3,$4) AS v',[ctxId,token,op,H('3')]));
    const t1=tok();
    await assert.rejects(link(b,g,t1),/context_not_authorized/);
    await assert.rejects(link(a,direct,tok()),/context_not_active/,'direct splits have no group link');
    const op=crypto.randomUUID();
    assert.equal((await link(a,g,t1,op)).rows[0].v.active,true);
    assert.equal((await link(a,g,t1,op)).rows[0].v.active,true,'replay');
    const preview=(who,token)=>actor(who,()=>db.query('SELECT shared_expenses.preview_invitation($1) AS v',[token])).then(r=>r.rows[0].v);
    const p=await preview(b,t1);
    assert.equal(p.kind,'group_link');assert.equal(p.contextName,'Link trip');
    await assert.rejects(preview(b,tok()),/invitation_unavailable/);
    const claim=(who,token,o=crypto.randomUUID())=>actor(who,()=>db.query('SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5) AS v',[token,null,null,o,H('4')])).then(r=>r.rows[0].v);
    // Opening the link creates a request only.
    const cop=crypto.randomUUID();
    const first=await claim(b,t1,cop);
    assert.equal(first.status,'awaiting_owner');
    assert.equal((await claim(b,t1,cop)).status,'awaiting_owner','replay');
    assert.equal((await claim(b,t1)).status,'awaiting_owner','a second tap does not create a second request');
    assert.equal((await db.query("SELECT count(*)::int n FROM shared_expenses.members WHERE context_id=$1",[g])).rows[0].n,2,'owner plus one pending person');
    assert.equal((await db.query('SELECT profile_id FROM shared_expenses.members WHERE member_id=$1',[first.memberId])).rows[0].profile_id,null,'no access before approval');
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.contexts WHERE context_id=$1',[g]))).rowCount,0,'pending requester cannot read the group');
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1',[g])).rows[0].n,0);
    const requests=await actor(a,()=>db.query('SELECT shared_expenses.list_join_requests() AS v'));
    const mine=requests.rows[0].v.items.find(i=>i.contextId===g);
    assert.ok(mine,'owner sees the request');
    assert.equal(mine.claimantName,'Rahul Kumar Sharma','owner sees who actually opened the link, not only the typed name');
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses._member_label(NULL,$1) AS v',[a]))).rows[0].v,'Asha Verma Rao','an unnamed owner is labelled by their PandaPay name');
    assert.equal(requests.rows[0].v.items.filter(i=>i.contextId===g).length,1);
    await assert.rejects(actor(c,()=>db.query('SELECT shared_expenses.respond_invitation($1,true,$2,$3)',[mine.invitationId,crypto.randomUUID(),H('5')])),/context_not_authorized/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.respond_invitation($1,true,$2,$3) AS v',[mine.invitationId,crypto.randomUUID(),H('6')]))).rows[0].v.status,'joined');
    assert.equal((await db.query('SELECT state,profile_id FROM shared_expenses.members WHERE member_id=$1',[first.memberId])).rows[0].profile_id,b);
    // Already a member: opening the link again just says so.
    assert.equal((await claim(b,t1)).status,'joined');
    // The owner opening their own link is also a no-op.
    assert.equal((await claim(a,t1)).status,'joined');
    // Decline hides the person and pauses new requests for a week.
    const d=await claim(c,t1);
    const dreq=(await actor(a,()=>db.query('SELECT shared_expenses.list_join_requests() AS v'))).rows[0].v.items.find(i=>i.contextId===g);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.respond_invitation($1,false,$2,$3) AS v',[dreq.invitationId,crypto.randomUUID(),H('7')]))).rows[0].v.status,'rejected');
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE member_id=$1',[d.memberId])).rows[0].state,'declined');
    await assert.rejects(claim(c,t1),/join_declined_recently/);
    // Replacing or revoking the link kills the old token without touching requests.
    const t2=tok();
    await link(a,g,t2);
    await assert.rejects(preview(c,t1),/invitation_unavailable/,'old link is dead after a reset');
    assert.equal((await preview(c,t2)).kind,'group_link');
    await actor(a,()=>db.query('SELECT shared_expenses.revoke_group_link($1,$2,$3)',[g,crypto.randomUUID(),H('8')]));
    await assert.rejects(claim(c,t2),/invitation_unavailable/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.group_link_status($1) AS v',[g]))).rows[0].v.active,false);
    await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.group_link_status($1)',[g])),/context_not_authorized/,'only the owner sees link status');
    // Expiry.
    const t3=tok();
    await link(a,g,t3);
    await db.query("UPDATE shared_expenses.group_links SET expires_at=clock_timestamp()-interval '1 minute' WHERE context_id=$1",[g]);
    await assert.rejects(preview(c,t3),/invitation_unavailable/);
    assert.equal((await actor(a,()=>db.query('SELECT shared_expenses.group_link_status($1) AS v',[g]))).rows[0].v.expired,true);
    // Pending-request cap.
    await link(a,g,t3);
    await db.query("UPDATE shared_expenses.group_links SET expires_at=clock_timestamp()+interval '1 day' WHERE context_id=$1",[g]);
    await db.query("DELETE FROM shared_expenses.invitations WHERE claimed_profile_id=$1 AND via_group_link",[c]);
    await db.query("INSERT INTO shared_expenses.members(context_id,member_id,role,state,display_name) SELECT $1,gen_random_uuid(),'member','invited','x' FROM generate_series(1,20)",[g]);
    await db.query("INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,state,via_group_link) SELECT gen_random_uuid(),$1,m.member_id,$2,encode(sha256(convert_to(m.member_id::text,'UTF8')),'hex'),$2,'awaiting_owner',true FROM shared_expenses.members m WHERE m.context_id=$1 AND m.display_name='x'",[g,a]);
    await assert.rejects(claim(c,t3),/join_requests_full/);
  });
  await t.test('owner transfer, take-over when the owner account is gone, and "Former member" label',async()=>{
    const H=(ch)=>ch.repeat(64), g=crypto.randomUUID(), q=crypto.randomUUID(), i=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Own trip',$2,$3)",[g,crypto.randomUUID(),H('1')]));
    await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:g,memberId:q,displayName:'Bee'},crypto.randomUUID(),H('2')]));
    const xfer=(who,member)=>actor(who,()=>db.query('SELECT shared_expenses.transfer_owner($1,$2,$3,$4) AS v',[g,member,crypto.randomUUID(),H('9')]));
    await assert.rejects(xfer(a,q),/membership_conflict/,'target must be an active member');
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:i,contextId:g,memberId:q,targetPhoneHash:H('b'),tokenHash:crypto.randomBytes(32).toString('hex')},H('5')]));
    await actor(b,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5)',[i,H('b'),'3210',crypto.randomUUID(),H('6')]));
    await assert.rejects(xfer(b,q),/context_not_authorized/,'only the owner transfers');
    await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.take_over_ownership($1,$2,$3)',[g,crypto.randomUUID(),H('8')])),/owner_still_present/);
    assert.equal((await xfer(a,q)).rows[0].v.status,'owner');
    const roles=(await db.query("SELECT profile_id,role FROM shared_expenses.members WHERE context_id=$1 AND state='active'",[g])).rows;
    assert.equal(roles.find(x=>x.role==='owner').profile_id,b);
    // The old owner is now a plain member and may leave; the new owner may not.
    await actor(a,()=>db.query('SELECT shared_expenses.leave_context($1,$2,$3)',[g,crypto.randomUUID(),H('7')]));
    await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.leave_context($1,$2,$3)',[g,crypto.randomUUID(),H('7')])),/owner_cannot_leave/);
    assert.equal((await db.query('SELECT shared_expenses._member_label(NULL,NULL) AS l')).rows[0].l,'Former member');
    assert.equal((await db.query("SELECT shared_expenses._member_label('Asha',NULL) AS l")).rows[0].l,'Asha');
  });
  await t.test('leaving and removing: only unjoined people without expenses, and only when settled up',async()=>{
    const H=(ch)=>ch.repeat(64), g=crypto.randomUUID(), m1=crypto.randomUUID(), m2=crypto.randomUUID(), tok=()=>crypto.randomBytes(32).toString('hex');
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Exit trip',$2,$3)",[g,crypto.randomUUID(),H('1')]));
    for(const [m,n] of [[m1,'Dev'],[m2,'Ria']]) await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:g,memberId:m,displayName:n},crypto.randomUUID(),H('2')]));
    const remove=(who,member,op=crypto.randomUUID())=>actor(who,()=>db.query('SELECT shared_expenses.remove_member($1,$2,$3,$4) AS v',[g,member,op,H('3')]));
    await assert.rejects(remove(b,m1),/context_not_authorized/,'only owners remove');
    const op=crypto.randomUUID();
    assert.equal((await remove(a,m1,op)).rows[0].v.status,'removed');
    assert.equal((await remove(a,m1,op)).rows[0].v.status,'removed','replay');
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE member_id=$1',[m1])).rows[0].state,'declined');
    await assert.rejects(remove(a,m1),/membership_conflict/,'already removed');
    // A person with an expense cannot be removed.
    const exp=crypto.randomUUID(), rev=crypto.randomUUID(), ownerMember=(await db.query("SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND role='owner'",[g])).rows[0].member_id;
    const snapshot={currency:'INR',totalMinor:'10000',memberOrder:[ownerMember,m2],contributions:[{memberId:ownerMember,amountMinor:'10000'}],shares:[{memberId:ownerMember,amountMinor:'5000'},{memberId:m2,amountMinor:'5000'}]};
    await actor(a,()=>db.query('SELECT shared_expenses.submit_proposal($1,$2,$3)',[{contextId:g,expenseId:exp,revisionId:rev,expectedHeadRevisionId:null,title:'Dinner',occurredOn:'2026-11-05',snapshot,sources:[],void:false},crypto.randomUUID(),H('4')]));
    await assert.rejects(remove(a,m2),/member_has_expenses/);
    // Joined members: owner cannot leave; a member with a pending expense must settle first.
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:crypto.randomUUID(),contextId:g,memberId:m2,targetPhoneHash:H('b'),tokenHash:tok()},H('5')]));
    const inv=(await db.query("SELECT invitation_id FROM shared_expenses.invitations WHERE member_id=$1 AND state='open'",[m2])).rows[0].invitation_id;
    await actor(b,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5)',[inv,H('b'),'3210',crypto.randomUUID(),H('6')]));
    const leave=(who,op2=crypto.randomUUID())=>actor(who,()=>db.query('SELECT shared_expenses.leave_context($1,$2,$3) AS v',[g,op2,H('7')]));
    await assert.rejects(leave(a),/owner_cannot_leave/);
    await assert.rejects(leave(c),/membership_not_authorized/,'a stranger cannot leave');
    await assert.rejects(leave(b),/settle_first/,'pending expense blocks leaving');
    // A settled member with nothing pending can leave, and loses access.
    const g2=crypto.randomUUID(), q1=crypto.randomUUID(), i2=crypto.randomUUID();
    await actor(a,()=>db.query("SELECT shared_expenses.create_context($1,'group','Quiet',$2,$3)",[g2,crypto.randomUUID(),H('1')]));
    await actor(a,()=>db.query('SELECT shared_expenses.invite_member($1,$2,$3)',[{contextId:g2,memberId:q1,displayName:'Bee'},crypto.randomUUID(),H('2')]));
    await actor(a,()=>db.query('SELECT shared_expenses.create_invitation($1,$2)',[{invitationId:i2,contextId:g2,memberId:q1,targetPhoneHash:H('b'),tokenHash:tok()},H('5')]));
    await actor(b,()=>db.query('SELECT shared_expenses.claim_invitation_by_id($1,$2,$3,$4,$5)',[i2,H('b'),'3210',crypto.randomUUID(),H('6')]));
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.contexts WHERE context_id=$1',[g2]))).rowCount,1);
    const lop=crypto.randomUUID();
    const left=()=>actor(b,()=>db.query('SELECT shared_expenses.leave_context($1,$2,$3) AS v',[g2,lop,H('7')]));
    assert.equal((await left()).rows[0].v.status,'left');
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE member_id=$1',[q1])).rows[0].state,'left');
    assert.equal((await actor(b,()=>db.query('SELECT * FROM shared_expenses.contexts WHERE context_id=$1',[g2]))).rowCount,0,'no access after leaving');
    await assert.rejects(actor(b,()=>db.query('SELECT shared_expenses.leave_context($1,$2,$3)',[g2,crypto.randomUUID(),H('8')])),/membership_not_authorized/);
  });
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
    const queries=requireApi('./src/shared_expenses/queries');
    const pending=await actor(a,()=>queries.listSettlementReports(db,a,ctx,{}));
    assert.equal(pending.items.find(row=>row.settlementId===sid).status,'pending');
    assert.equal((await actor(c,()=>queries.listSettlementReports(db,c,ctx,{}))).items.some(row=>row.settlementId===sid),false,'unrelated group member must not read payment reports');
    assert.equal((await balances())[mb],'-40000');
    await assert.rejects(command(b,'respond_settlement',{contextId:ctx,settlementId:sid,decision:'confirm'}),/receiver_confirmation_required/);
    const response={contextId:ctx,settlementId:sid,decision:'confirm'}, operation=crypto.randomUUID();
    const confirmed=await command(a,'respond_settlement',response,operation);
    assert.deepEqual(await command(a,'respond_settlement',response,operation),confirmed);
    assert.equal((await balances())[mb],'-10000');
    const paid=await actor(a,()=>queries.listSettlementReports(db,a,ctx,{}));
    assert.equal(paid.items.filter(row=>row.settlementId===sid).length,1);
    assert.equal(paid.items.find(row=>row.settlementId===sid).status,'confirmed');
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
  await t.test('member labels: typed name wins, live profile name next, Former member last; member.rename',async()=>{
    const H=(ch)=>ch.repeat(64), uuid=()=>crypto.randomUUID();
    const own='60000000-0000-0000-0000-000000000001', pal='60000000-0000-0000-0000-000000000002', stranger='60000000-0000-0000-0000-000000000003', gone='60000000-0000-0000-0000-000000000004', joiner='60000000-0000-0000-0000-000000000005';
    await db.query("INSERT INTO public.profiles VALUES($1,'Olive Owner'),($2,'Pal Profile'),($3,'Stranger Sam'),($4,'Gone Gary'),($5,'Joiner Jo')",[own,pal,stranger,gone,joiner]);
    const call=(who,fn,args)=>actor(who,()=>db.query(`SELECT shared_expenses.${fn} AS v`,args)).then(r=>r.rows[0].v);
    const label=(name,profile)=>db.query('SELECT shared_expenses._member_label($1,$2) AS v',[name,profile]).then(r=>r.rows[0].v);
    const memberName=(ctxId,mid)=>db.query('SELECT display_name FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2',[ctxId,mid]).then(r=>r.rows[0].display_name);
    const g=uuid(); const ownerMember=(await call(own,"create_context($1,'group','Label trip',$2,$3)",[g,uuid(),H('1')])).memberId;
    // A typed name beats the profile name; the pal joins through a phone-bound invite.
    const palMember=uuid();
    await call(own,'invite_member($1,$2,$3)',[{contextId:g,memberId:palMember,displayName:'Mom'},uuid(),H('2')]);
    const inv=uuid();
    await call(own,'create_invitation($1,$2)',[{invitationId:inv,contextId:g,memberId:palMember,targetPhoneHash:H('c'),tokenHash:crypto.randomBytes(32).toString('hex')},H('3')]);
    await call(pal,'claim_invitation_by_id($1,$2,$3,$4,$5)',[inv,H('c'),'3210',uuid(),H('4')]);
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE member_id=$1',[palMember])).rows[0].state,'active');
    assert.equal(await label(await memberName(g,palMember),pal),'Mom','typed beats profile');
    // No typed name: the live profile name, and a rename of the profile shows straight away.
    await db.query('UPDATE shared_expenses.members SET display_name=NULL WHERE member_id=$1',[palMember]);
    assert.equal(await label(null,pal),'Pal Profile');
    assert.equal(await label('   ',pal),'Pal Profile','blank typed name counts as none');
    await db.query("UPDATE public.profiles SET display_name='Pal Renamed' WHERE id=$1",[pal]);
    assert.equal(await label(null,pal),'Pal Renamed','live, not cached');
    // A stale phone_directory copy is ignored; so is its absence.
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.phone_directory WHERE profile_id=$1',[pal])).rows[0].n,0,'no directory row for this person');
    await db.query("INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash,display_name,discoverable) VALUES($1,$2,'Stale Copy',false)",[pal,H('d')]);
    assert.equal(await label(null,pal),'Pal Renamed','the stale directory copy is never used');
    await db.query("UPDATE public.profiles SET display_name=NULL WHERE id=$1",[pal]);
    assert.equal(await label(null,pal),null,'no typed name and no profile name: the caller falls back (Someone)');
    await db.query("UPDATE public.profiles SET display_name='Pal Renamed' WHERE id=$1",[pal]);
    assert.equal(await label(null,null),'Former member','deleted account');
    assert.equal(await label('Mom',null),'Mom','a typed name survives account deletion');
    // The roster label is what the app shows; read it through the app role.
    const roster=(await actor(own,()=>db.query('SELECT shared_expenses._member_label(m.display_name,m.profile_id) AS v FROM shared_expenses.members m WHERE m.member_id=$1',[palMember]))).rows[0].v;
    assert.equal(roster,'Pal Renamed','the app role can read another member\'s live name');

    // member.rename
    const rename=(who,mid,displayName,op=uuid(),hash=H('5'),ctxId=g)=>call(who,'rename_member($1,$2,$3)',[{contextId:ctxId,memberId:mid,displayName},op,hash]);
    const events=()=>db.query("SELECT count(*)::int n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='member.renamed'",[g]).then(r=>r.rows[0].n);
    const op1=uuid();
    const first=await rename(own,palMember,'  Pal   the   Friend ',op1,H('6'));
    assert.equal(first.status,'renamed');assert.equal(first.displayName,'Pal the Friend');
    assert.equal(await memberName(g,palMember),'Pal the Friend','owner renamed another member');
    assert.equal(await events(),1);
    assert.deepEqual(await rename(own,palMember,'  Pal   the   Friend ',op1,H('6')),first,'replay returns the same result');
    assert.equal(await events(),1,'replay emits nothing new');
    await assert.rejects(rename(own,palMember,'Different',op1,H('7')),/operation_conflict/);
    assert.equal((await rename(pal,palMember,'Pal Self')).displayName,'Pal Self','a member renames their own row');
    await assert.rejects(rename(pal,ownerMember,'Hijack'),/member_rename_not_authorized/,'not someone else\'s row');
    await assert.rejects(rename(stranger,palMember,'Nope'),/context_not_authorized/,'a stranger cannot rename');
    await assert.rejects(rename(own,uuid(),'Ghost'),/member_not_found/);
    for(const bad of ['','   ','\u0007\u0001','\n\t'])await assert.rejects(rename(own,palMember,bad),/invalid_member_name/,JSON.stringify(bad));
    await assert.rejects(actor(own,()=>db.query('SELECT shared_expenses.rename_member($1,$2,$3)',[{contextId:g,memberId:palMember,displayName:7},uuid(),H('8')])),/invalid_member_name/);
    await assert.rejects(actor(own,()=>db.query('SELECT shared_expenses.rename_member($1,$2,$3)',[{contextId:g,memberId:palMember,displayName:'x',extra:1},uuid(),H('8')])),/invalid_member_name/);
    assert.equal((await rename(own,palMember,'A \n\u0007  B')).displayName,'A B','control characters stripped, whitespace collapsed');
    assert.equal((await rename(own,palMember,'y'.repeat(200))).displayName,'y'.repeat(40),'capped at 40');
    assert.equal(await memberName(g,palMember),'y'.repeat(40));
    // Names are unique within a split (see the join-identity tests for the full matrix).
    await rename(own,palMember,'Twin');
    await assert.rejects(rename(own,ownerMember,'twin'),/member_name_taken/);
    assert.equal(await memberName(g,palMember),'Twin');
    // Hostile text is only ever data.
    assert.equal((await rename(own,palMember,"Robert'); DROP TABLE shared_expenses.members;--")).displayName,"Robert'); DROP TABLE shared_expenses.members;--".slice(0,40));
    assert.ok((await db.query('SELECT count(*)::int n FROM shared_expenses.members')).rows[0].n>0);
    // Invited (not yet joined) people: the owner may name them, other members may not; closed rows are refused.
    const shadow=uuid();
    await call(own,'invite_member($1,$2,$3)',[{contextId:g,memberId:shadow,displayName:'Shadow'},uuid(),H('9')]);
    assert.equal((await rename(own,shadow,'Shadow Two')).displayName,'Shadow Two');
    await assert.rejects(rename(pal,shadow,'Nope'),/member_rename_not_authorized/);
    await db.query("UPDATE shared_expenses.members SET state='declined' WHERE member_id=$1",[shadow]);
    await assert.rejects(rename(own,shadow,'Again'),/member_not_renamable/);
    await db.query("UPDATE shared_expenses.members SET state='active',profile_id=NULL WHERE member_id=$1",[shadow]);
    await assert.rejects(rename(own,shadow,'Again'),/member_not_renamable/,'former member keeps their history label');
    await db.query("UPDATE shared_expenses.members SET state='left' WHERE member_id=$1",[shadow]);
    await assert.rejects(rename(own,shadow,'Again'),/member_not_renamable/);

    // member.invite uses the same cleaner as rename (trigger on every stored name).
    const invite=(displayName)=>{const m=uuid();return call(own,'invite_member($1,$2,$3)',[{contextId:g,memberId:m,displayName},uuid(),H('f')]).then(()=>memberName(g,m));};
    assert.equal(await invite('z'.repeat(110)),'z'.repeat(40),'long invite name capped');
    assert.equal(await invite(' Ra\n\thul\u0085  K '),'Ra hul K','control chars incl. U+0085 become one space');
    assert.equal(await invite('\u{1D4D0}'.repeat(60)),'\u{1D4D0}'.repeat(40),'cut on a code point, no half pair');
    for(const bad of ['\u0085','\u0085\u0009\u009f','\u0007'])await assert.rejects(call(own,'invite_member($1,$2,$3)',[{contextId:g,memberId:uuid(),displayName:bad},uuid(),H('f')]),/invalid_member_name/,JSON.stringify(bad));
    // Join request: the owner sees the claimant's LIVE name next to the typed label, plus the new keys.
    const g2=uuid(), friend=uuid(), inv2=uuid(), tokenHash=crypto.randomBytes(32).toString('hex');
    await call(own,"create_context($1,'direct','Join labels',$2,$3)",[g2,uuid(),H('a')]);
    await call(own,'invite_member($1,$2,$3)',[{contextId:g2,memberId:friend,displayName:'Bestie'},uuid(),H('b')]);
    await call(own,'create_invitation($1,$2)',[{invitationId:inv2,contextId:g2,memberId:friend,targetPhoneHash:null,tokenHash},H('c')]);
    assert.equal((await call(joiner,'claim_invitation($1,$2,$3,$4,$5)',[tokenHash,null,null,uuid(),H('d')])).status,'awaiting_owner');
    const joinReq=async()=>(await call(own,'list_join_requests()',[])).items.find(i=>i.invitationId===inv2);
    let req=await joinReq();
    assert.equal(req.claimantName,'Joiner Jo');assert.equal(req.claimantProfileName,'Joiner Jo');
    assert.equal(req.memberName,'Bestie');assert.ok('claimantPhoneSuffix' in req);assert.ok('verifiedPhoneSuffix' in req);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.phone_directory WHERE profile_id=$1',[joiner])).rows[0].n,0,'no directory row needed');
    await db.query("UPDATE public.profiles SET display_name='Joiner Renamed' WHERE id=$1",[joiner]);
    assert.equal((await joinReq()).claimantName,'Joiner Renamed','live name on the join card');
    const listed=(await call(own,'list_invitations($1,NULL)',[g2])).items.find(i=>i.invitationId===inv2);
    assert.equal(listed.claimantName,'Joiner Renamed');assert.equal(listed.memberName,'Bestie');
    // invitation_audience: typed name wins for the push label; profile name and phone suffix ride along separately.
    let audience=await call(joiner,'invitation_audience($1)',[tokenHash]);
    assert.equal(audience.claimantName,'Bestie');assert.equal(audience.claimantProfileName,'Joiner Renamed');assert.ok('claimantPhoneSuffix' in audience);
    assert.deepEqual(audience.owners,[own]);
    await db.query('UPDATE shared_expenses.members SET display_name=NULL WHERE member_id=$1',[friend]);
    audience=await call(joiner,'invitation_audience($1)',[tokenHash]);
    assert.equal(audience.claimantName,'Joiner Renamed','no typed name: live profile name');
    await db.query("UPDATE public.profiles SET display_name=NULL WHERE id=$1",[joiner]);
    audience=await call(joiner,'invitation_audience($1)',[tokenHash]);
    assert.equal(audience.claimantName,null);
    await assert.rejects(call(stranger,'invitation_audience($1)',[tokenHash]),/invitation_unavailable/,'only the claimant');
  });
  await t.test('direct split title is the counterpart\'s live label for each viewer',async()=>{
    const H=(ch)=>ch.repeat(64), uuid=()=>crypto.randomUUID();
    const cr='70000000-0000-0000-0000-000000000001', fr='70000000-0000-0000-0000-000000000002';
    await db.query("INSERT INTO public.profiles VALUES($1,'Creator Cee'),($2,'Friend Eff')",[cr,fr]);
    const call=(who,fn,args)=>actor(who,()=>db.query(`SELECT shared_expenses.${fn} AS v`,args)).then(r=>r.rows[0].v);
    const title=(who,id)=>actor(who,()=>db.query("SELECT shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid,c.context_id) AS v FROM shared_expenses.contexts c WHERE c.context_id=$2",[who,id])).then(r=>r.rows[0].v);
    const g=uuid(), friendMember=uuid(), inv=uuid();
    const creatorMember=(await call(cr,"create_context($1,'direct','Rahul',$2,$3)",[g,uuid(),H('1')])).memberId;
    await call(cr,'invite_member($1,$2,$3)',[{contextId:g,memberId:friendMember,displayName:'Rahul'},uuid(),H('2')]);
    assert.equal(await title(cr,g),'Rahul','invited friend, typed name');
    await call(cr,'create_invitation($1,$2)',[{invitationId:inv,contextId:g,memberId:friendMember,targetPhoneHash:H('e'),tokenHash:crypto.randomBytes(32).toString('hex')},H('3')]);
    await call(fr,'claim_invitation_by_id($1,$2,$3,$4,$5)',[inv,H('e'),'3210',uuid(),H('4')]);
    await call(cr,'rename_member($1,$2,$3)',[{contextId:g,memberId:friendMember,displayName:'Rahul Sharma'},uuid(),H('5')]);
    assert.equal(await title(cr,g),'Rahul Sharma','creator sees the renamed counterpart');
    assert.equal(await title(fr,g),'Creator Cee','the other person sees the creator\'s live profile name');
    await db.query("UPDATE public.profiles SET display_name='Creator Renamed' WHERE id=$1",[cr]);
    assert.equal(await title(fr,g),'Creator Renamed','profile rename is live');
    await call(cr,'rename_member($1,$2,$3)',[{contextId:g,memberId:creatorMember,displayName:'Cee Typed'},uuid(),H('6')]);
    assert.equal(await title(fr,g),'Cee Typed','a typed label for the creator wins');
    // Fallbacks.
    await db.query('UPDATE shared_expenses.members SET display_name=NULL WHERE member_id=$1',[friendMember]);
    await db.query("UPDATE public.profiles SET display_name=NULL WHERE id=$1",[fr]);
    assert.equal(await title(cr,g),'Rahul','no counterpart name: the split\'s own name');
    await db.query('UPDATE shared_expenses.members SET display_name=NULL WHERE member_id=$1',[creatorMember]);
    await db.query("UPDATE public.profiles SET display_name=NULL WHERE id=$1",[cr]);
    assert.equal(await title(fr,g),'PandaPay friend');
    // NULL context id keeps the old behaviour; groups are untouched.
    assert.equal((await db.query("SELECT shared_expenses._context_label('direct','Typed',$1,$2,NULL) AS v",[cr,fr])).rows[0].v,'PandaPay friend');
    const grp=uuid();
    await call(cr,"create_context($1,'group','Goa',$2,$3)",[grp,uuid(),H('7')]);
    assert.equal(await title(cr,grp),'Goa');
  });

  const {parseKeyRing,encryptPhone,decryptPhone}=requireApi('./src/shared_expenses/phone_crypto');
  const {describePhone}=requireApi('./src/shared_expenses/phone_display');
  const labelLib=requireApi('./src/shared_expenses/label');
  const ring=parseKeyRing(JSON.stringify({current:'k1',keys:{k1:crypto.randomBytes(32).toString('base64')}}));
  const pid=(n)=>`80000000-0000-0000-0000-${n.toString(16).padStart(12,'0')}`;
  const phoneHash=(e)=>crypto.createHash('sha256').update('test-phone:'+e).digest('hex');
  await t.test('join identity: consent, capture, lookalikes, reveal, check, purge',async()=>{
    const H=(ch)=>ch.repeat(64), uuid=()=>crypto.randomUUID(), tok=()=>crypto.randomBytes(32).toString('hex');
    const own=pid(1), mem=pid(2), stranger=pid(3), c1=pid(4), c2=pid(5), c3=pid(6), c4=pid(7), c5=pid(8), c6=pid(9), c7=pid(10), c8=pid(11);
    const E={[c1]:'+917234512345',[c2]:'+917299912345',[c3]:'+14155552671',[c4]:'+917234512345',[c6]:'+442079460958',[c7]:'+918800011122',[c8]:'+919811100099'};
    await db.query("INSERT INTO public.profiles VALUES($1,'Olive Owner'),($2,'Mia Member'),($3,'Stranger Sam'),($4,'Rahul Sharma'),($5,'Rahul Sharma'),($6,'Cee Three'),($7,'Dee Four'),($8,'Eve Email'),($9,'Fay Six'),($10,'Gus Seven'),($11,'Hal Eight')",[own,mem,stranger,c1,c2,c3,c4,c5,c6,c7,c8]);
    const call=(who,fn,args)=>actor(who,()=>db.query(`SELECT shared_expenses.${fn} AS v`,args)).then(r=>r.rows[0].v);
    const g=uuid(), link=tok();
    await call(own,"create_context($1,'group','Identity trip',$2,$3)",[g,uuid(),H('1')]);
    await call(own,'register_phone($1,NULL)',[phoneHash('+919000000001')]);
    await call(c1,'register_phone($1,NULL)',[phoneHash(E[c1])]);
    await call(own,'create_group_link($1,$2,$3,$4)',[g,link,uuid(),H('2')]);
    const claim=(who,share,suffix='2345',op=uuid(),token=link)=>call(who,'claim_invitation($1,$2,$3,$4,$5,$6)',[token,E[who]?phoneHash(E[who]):null,suffix,op,H('3'),share]).then(r=>({...r,op}));
    const attach=(who,claimed,e164=E[who])=>{const sealed=encryptPhone(ring,claimed.invitationId,e164),shown=describePhone(e164);return call(who,'attach_claimant_phone($1,$2,$3,$4,$5,$6,$7,$8)',[claimed.invitationId,claimed.op,phoneHash(e164),shown.countryCode,shown.mask,sealed.enc,sealed.keyId,e164.slice(-4)]);};
    const requests=async()=>(await call(own,'list_join_requests()',[])).items;
    const item=async(inv)=>(await requests()).find(i=>i.invitationId===inv);
    const row=(inv)=>db.query('SELECT * FROM shared_expenses.invitations WHERE invitation_id=$1',[inv]).then(r=>r.rows[0]);
    const reveal=(who,inv)=>call(who,'reveal_claimant_phone($1)',[inv]);
    const check=(who,inv,h)=>call(who,'check_claimant_phone($1,$2)',[inv,h]);

    // --- old caller: five arguments, no consent => not_asked, nothing stored, claim still works
    const old=await actor(c3,()=>db.query('SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5) AS v',[link,phoneHash(E[c3]),'2671',uuid(),H('3')])).then(r=>r.rows[0].v);
    assert.equal(old.status,'awaiting_owner');assert.ok(old.invitationId);
    let it=await item(old.invitationId);
    assert.deepEqual(it.claimantPhone,{v:1,source:'verified',consent:'not_asked',countryCode:null,last4:'2671',mask:null,available:false,unavailableReason:'claimed_before_update',lookalike:false,duplicateOf:[],numberStatus:'unknown',matchesTyped:null,capturedAt:null});
    assert.equal(it.verifiedPhoneSuffix,'2671');assert.equal(it.claimantPhoneSuffix,'2671');assert.equal(it.claimantName,'Cee Three');
    // --- shared: claim then attach in the same transaction shape the API uses
    const r1=await claim(c1,null,'2345');
    assert.equal((await attach(c1,r1)).attached,true);
    it=await item(r1.invitationId);
    assert.match(it.claimantPhone.capturedAt,/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.deepEqual({...it.claimantPhone,capturedAt:'T'},{v:1,source:'verified',consent:'shared',countryCode:'+91',last4:'2345',mask:'+91 72••• •2345',available:true,unavailableReason:null,lookalike:false,duplicateOf:[],numberStatus:'confirmed',matchesTyped:null,capturedAt:'T'});
    assert.equal(it.memberName,'Rahul Sharma','placeholder label from the live name');
    // --- declined: no number, no hash, no mask
    const r2=await claim(c2,'declined','2345');
    it=await item(r2.invitationId);
    assert.equal(it.memberName,'Rahul Sharma (2)','a second person with the same name gets a numeric suffix');
    assert.deepEqual(it.claimantPhone,{v:1,source:'verified',consent:'declined',countryCode:null,last4:null,mask:null,available:false,unavailableReason:'claimant_declined',lookalike:false,duplicateOf:[],numberStatus:'unknown',matchesTyped:null,capturedAt:null});
    assert.equal((await row(r2.invitationId)).claimant_phone_hash,null,'declined stores no hash');
    assert.equal(it.verifiedPhoneSuffix,null,'asking without sharing shows the name only');assert.equal(it.claimantPhoneSuffix,null);
    assert.equal((await row(r2.invitationId)).verified_phone_suffix,null);
    // --- none: email-only account
    const r5=await claim(c5,'none',null);
    it=await item(r5.invitationId);
    assert.deepEqual(it.claimantPhone,{v:1,source:'none',consent:'none',countryCode:null,last4:null,mask:null,available:false,unavailableReason:'no_verified_phone',lookalike:false,duplicateOf:[],numberStatus:'unknown',matchesTyped:null,capturedAt:null});
    assert.equal(it.verifiedPhoneSuffix,null);
    assert.equal((await reveal(own,r5.invitationId)).error,'phone_not_available','nothing to reveal for none');
    assert.equal((await reveal(own,old.invitationId)).error,'phone_not_available','nothing to reveal for not_asked');
    assert.equal((await reveal(own,r2.invitationId)).error,'phone_not_available','nothing to reveal for declined');

    // --- re-claim refresh: consent flips, suffix refreshes, expiry is not extended, no second member
    const before=await row(r2.invitationId), membersBefore=(await db.query('SELECT count(*)::int n FROM shared_expenses.members WHERE context_id=$1',[g])).rows[0].n;
    const again=await claim(c2,null,'9999');
    assert.equal(again.invitationId,r2.invitationId);assert.equal(again.memberId,r2.memberId);
    assert.equal((await row(r2.invitationId)).verified_phone_suffix,'9999');
    assert.equal((await row(r2.invitationId)).phone_share,'not_asked','a repeat claim without consent re-applies not_asked');
    assert.deepEqual((await row(r2.invitationId)).expires_at,before.expires_at);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.members WHERE context_id=$1',[g])).rows[0].n,membersBefore);
    const r2b=await claim(c2,null,'2345');
    assert.equal((await attach(c2,r2b)).attached,true);
    assert.equal((await row(r2.invitationId)).verified_phone_suffix,'2345','sharing keeps the last four');
    assert.equal((await row(r2.invitationId)).phone_share,'shared');
    // flip to declined removes the stored number at once
    await claim(c2,'declined','2345');
    let r2row=await row(r2.invitationId);
    assert.equal(r2row.claimant_phone_enc,null);assert.equal(r2row.claimant_phone_hash,null);assert.ok(r2row.phone_purged_at);assert.equal(r2row.phone_share,'declined');assert.equal(r2row.verified_phone_suffix,null);
    const r2c=await claim(c2,null,'2345');await attach(c2,r2c);

    // --- lookalikes (same mask, different number) and duplicates (same number, different account)
    const r4=await claim(c4,null,'2345');
    await attach(c4,r4);
    const all=await requests();
    const byId=(id)=>all.find(i=>i.invitationId===id).claimantPhone;
    assert.equal(byId(r1.invitationId).lookalike,true,'c1 and c2 share a mask but not a number');
    assert.equal(byId(r2.invitationId).lookalike,true);
    assert.equal(byId(r1.invitationId).mask,byId(r2.invitationId).mask);
    assert.deepEqual(byId(r1.invitationId).duplicateOf,[r4.invitationId],'same number, different account');
    assert.deepEqual(byId(r4.invitationId).duplicateOf,[r1.invitationId]);
    assert.equal(byId(r4.invitationId).numberStatus,'moved','the number is now registered to another account');
    assert.equal(byId(r1.invitationId).numberStatus,'confirmed');
    assert.equal(byId(r2.invitationId).numberStatus,'unknown');
    assert.equal(byId(old.invitationId).lookalike,false);
    const enc=await call(own,'list_join_requests_enc($1)',[[r1.invitationId,r2.invitationId,old.invitationId,r5.invitationId]]);
    assert.deepEqual(enc.map(e=>e.invitationId).sort(),[r1.invitationId,r2.invitationId].sort(),'ciphertext only for look-alike requests');
    for(const e of enc)assert.equal(decryptPhone(ring,e.invitationId,Buffer.from(e.enc,'hex'),e.keyId),E[e.invitationId===r1.invitationId?c1:c2]);
    assert.deepEqual(await call(stranger,'list_join_requests_enc($1)',[[r1.invitationId]]),[],'only an owner');
    assert.deepEqual(await call(c1,'list_join_requests_enc($1)',[[r1.invitationId]]),[]);

    // --- no plaintext number anywhere the owner or the ledger can read
    const digits=['7234512345','7299912345','4155552671','2079460958'];
    const dump=JSON.stringify([all,await call(own,'list_invitations($1,NULL)',[g]),(await db.query('SELECT result,input_hash,request_hash FROM shared_expenses.operation_receipts')).rows,(await db.query('SELECT * FROM shared_expenses.phone_reveals')).rows,(await db.query('SELECT * FROM shared_expenses.context_events')).rows]);
    for(const d of digits)assert.ok(!dump.includes(d),'plaintext digits '+d+' leaked');
    assert.ok(!JSON.stringify(await call(c1,'invitation_audience($1)',[(await row(r1.invitationId)).token_hash])).includes('72345'),'audience carries no number');
    assert.ok(!Object.keys(await call(c1,'invitation_audience($1)',[(await row(r1.invitationId)).token_hash])).some(k=>/phone/i.test(k)&&k!=='claimantPhoneSuffix'));

    // --- AAD: a ciphertext copied to another invitation does not decrypt
    const sealed=await row(r1.invitationId);
    assert.equal(decryptPhone(ring,r1.invitationId,sealed.claimant_phone_enc,sealed.claimant_phone_key_id),E[c1]);
    assert.equal(decryptPhone(ring,r2.invitationId,sealed.claimant_phone_enc,sealed.claimant_phone_key_id),null);
    // attach refuses another person's request, a wrong shape, and a non-pending request
    assert.equal((await attach(c3,r1,E[c3])).attached,false);
    assert.equal((await call(c1,'attach_claimant_phone($1,$2,$3,$4,$5,$6,$7,$8)',[r1.invitationId,r1.op,'zz','+91','+91 72',Buffer.from('short'),'k1','2345'])).attached,false);

    // --- reveal permission matrix
    const mm=uuid();
    await call(own,'invite_member($1,$2,$3)',[{contextId:g,memberId:mm,profileId:mem,displayName:'Mia Member'},uuid(),H('4')]);
    await call(mem,'respond_membership($1,$2,$3,$4,$5)',[g,mm,true,uuid(),H('5')]);
    for(const who of [mem,stranger,c1,c2])await assert.rejects(reveal(who,r1.invitationId),/context_not_authorized/,'reveal denied for '+who);
    await assert.rejects(reveal(own,uuid()),/context_not_authorized/,'unknown invitation looks like no access');
    const got=await reveal(own,r1.invitationId);
    assert.equal(decryptPhone(ring,got.invitationId,Buffer.from(got.enc,'hex'),got.keyId),E[c1]);
    assert.equal((await db.query("SELECT count(*)::int n FROM shared_expenses.phone_reveals WHERE owner_profile_id=$1 AND via='tap'",[own])).rows[0].n,1,'audited');
    assert.deepEqual(Object.keys((await db.query('SELECT * FROM shared_expenses.phone_reveals LIMIT 1')).rows[0]).sort(),['at','invitation_id','owner_profile_id','reveal_id','via']);
    // the owner needs a verified number of their own
    await db.query('DELETE FROM shared_expenses.phone_directory WHERE profile_id=$1',[own]);
    assert.equal((await reveal(own,r1.invitationId)).error,'owner_phone_required');
    await call(own,'register_phone($1,NULL)',[phoneHash('+919000000001')]);
    // caps: 5 per hour, 30 per day (look-alike disclosures share the same budget, so start clean)
    await db.query("DELETE FROM shared_expenses.phone_reveals WHERE via='lookalike'");
    for(let n=0;n<4;n++)assert.ok((await reveal(own,r1.invitationId)).enc);
    assert.equal((await reveal(own,r1.invitationId)).error,'reveal_rate_limited','sixth in an hour');
    await db.query("UPDATE shared_expenses.phone_reveals SET at=clock_timestamp()-interval '2 hours'");
    for(let n=0;n<5;n++)assert.ok((await reveal(own,r1.invitationId)).enc,'a new hour opens again');
    await db.query("UPDATE shared_expenses.phone_reveals SET at=clock_timestamp()-interval '2 hours'");
    await db.query("INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,at) SELECT $1,$2,clock_timestamp()-interval '3 hours' FROM generate_series(1,20)",[r1.invitationId,own]);
    assert.equal((await reveal(own,r1.invitationId)).error,'reveal_rate_limited','thirty in a day');
    await db.query('DELETE FROM shared_expenses.phone_reveals');

    // --- check-phone: hashed comparison, three attempts, owner only
    const rightHash=phoneHash(E[c1]), wrongHash=phoneHash('+917000000000');
    await assert.rejects(check(mem,r1.invitationId,rightHash),/context_not_authorized/);
    await assert.rejects(check(own,r1.invitationId,'nothex'),/invalid_invitation/);
    assert.deepEqual(await check(own,r1.invitationId,wrongHash),{matches:false,attemptsLeft:2});
    assert.deepEqual(await check(own,r1.invitationId,rightHash),{matches:true,attemptsLeft:1});
    assert.deepEqual(await check(own,r1.invitationId,rightHash),{matches:true,attemptsLeft:0});
    assert.equal((await check(own,r1.invitationId,rightHash)).error,'check_attempts_exhausted');
    assert.deepEqual(await check(own,r2.invitationId,rightHash),{matches:false,attemptsLeft:2});
    assert.deepEqual(await check(own,r5.invitationId,rightHash),{matches:null,attemptsLeft:3},'no answer and no count when nothing was shared');
    assert.deepEqual(await check(own,old.invitationId,rightHash),{matches:null,attemptsLeft:3});

    // --- purge on every resolution path
    // approve: number gone, 4 digits and hash stay
    await call(own,'respond_invitation($1,true,$2,$3)',[r1.invitationId,uuid(),H('6')]);
    let a1=await row(r1.invitationId);
    assert.equal(a1.claimant_phone_enc,null);assert.equal(a1.claimant_phone_mask,null);assert.ok(a1.phone_purged_at);assert.equal(a1.verified_phone_suffix,'2345');assert.equal(a1.claimant_phone_hash,phoneHash(E[c1]));assert.equal(a1.state,'joined');
    assert.equal((await reveal(own,r1.invitationId)).error,'phone_not_available');
    assert.equal((await check(own,r1.invitationId,rightHash)).error,'phone_not_available');
    // decline
    await call(own,'respond_invitation($1,false,$2,$3)',[r2.invitationId,uuid(),H('7')]);
    assert.equal((await row(r2.invitationId)).claimant_phone_enc,null);
    // remove the pending person (remove_member rejects the request)
    await assert.ok((await row(r4.invitationId)).claimant_phone_enc);
    await call(own,'remove_member($1,$2,$3,$4)',[g,r4.memberId,uuid(),H('8')]);
    a1=await row(r4.invitationId);assert.equal(a1.claimant_phone_enc,null);assert.equal(a1.state,'rejected');
    // link revoke drops numbers of requests that came through the link
    const r6=await claim(c6,null,'0958');await attach(c6,r6);
    assert.ok((await row(r6.invitationId)).claimant_phone_enc);
    await call(own,'revoke_group_link($1,$2,$3)',[g,uuid(),H('9')]);
    assert.equal((await row(r6.invitationId)).claimant_phone_enc,null);
    await call(own,'create_group_link($1,$2,$3,$4)',[g,link,uuid(),H('a')]);
    // lazy purge at expiry (a list is enough), and the hourly function
    const r7=await claim(c7,null,'1122');await attach(c7,r7);
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id IN ($1,$2)",[r7.invitationId,r6.invitationId]);
    assert.ok((await row(r7.invitationId)).claimant_phone_enc,'still stored until something looks');
    assert.equal((await requests()).some(i=>i.invitationId===r7.invitationId),false,'expired requests are not listed');
    assert.equal((await row(r7.invitationId)).claimant_phone_enc,null,'lazy purge on list');
    assert.equal((await reveal(own,r7.invitationId)).error,'phone_not_available');
    // zombie: an expired pending request comes back to life on a new claim, with the same member
    const back=await claim(c7,null,'1122');
    r7.op=back.op;
    assert.equal(back.invitationId,r7.invitationId);assert.equal(back.memberId,r7.memberId);
    assert.ok((await row(r7.invitationId)).expires_at>new Date(Date.now()+6*86400000),'expiry reset to a week');
    assert.equal((await requests()).some(i=>i.invitationId===r7.invitationId),true);
    await attach(c7,r7);
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=$1",[r7.invitationId]);
    assert.equal((await db.query('SELECT shared_expenses.purge_expired_claimant_phones() AS n')).rows[0].n>=1,true,'hourly purge');
    assert.equal((await row(r7.invitationId)).claimant_phone_enc,null);
    // expired rows do not count towards the 20-request cap
    await db.query("INSERT INTO shared_expenses.members(context_id,member_id,role,state,display_name) SELECT $1,gen_random_uuid(),'member','invited','filler '||n FROM generate_series(1,20) n",[g]);
    await db.query("INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,state,via_group_link,expires_at) SELECT gen_random_uuid(),$1,m.member_id,$2,encode(sha256(convert_to(m.member_id::text,'UTF8')),'hex'),$2,'awaiting_owner',true,clock_timestamp()-interval '1 day' FROM shared_expenses.members m WHERE m.context_id=$1 AND m.display_name LIKE 'filler %'",[g,own]);
    const r8=await claim(c8,null,'0099');
    assert.equal(r8.status,'awaiting_owner','20 expired zombies do not block a new request');
    // account deletion scrubs everything about the claimant
    await attach(c8,r8);
    await db.query('DELETE FROM public.profiles WHERE id=$1',[c8]);
    const gone=await row(r8.invitationId);
    assert.equal(gone.claimed_profile_id,null);assert.equal(gone.verified_phone_suffix,null);assert.equal(gone.claimant_phone_enc,null);assert.equal(gone.claimant_phone_hash,null);assert.equal(gone.claimant_phone_cc,null);assert.equal(gone.claimant_phone_mask,null);assert.equal(gone.state,'rejected');
    assert.equal((await db.query('SELECT state FROM shared_expenses.members WHERE member_id=$1',[r8.memberId])).rows[0].state,'declined');

    // --- names shown on join cards are cleaned (bidi, zero width, controls, length)
    await db.query("UPDATE public.profiles SET display_name=$2 WHERE id=$1",[c3,'Cee\u202e T\u200bhree\n\t'+'x'.repeat(80)]);
    const cleaned=(await item(old.invitationId)).claimantName;
    assert.equal(cleaned,('Cee Three '+'x'.repeat(80)).slice(0,40));
    assert.ok(!/[\u202e\u200b\n\t]/.test(cleaned));
    assert.equal((await call(c3,'invitation_audience($1)',[(await row(old.invitationId)).token_hash])).claimantProfileName,cleaned);
  });
  await t.test('join identity: unique names, reserved names and friend uniqueness',async()=>{
    const H=(ch)=>ch.repeat(64), uuid=()=>crypto.randomUUID(), tok=()=>crypto.randomBytes(32).toString('hex');
    const o1=pid(0x20), o2=pid(0x21), p1=pid(0x22), p2=pid(0x23), p3=pid(0x24), p4=pid(0x25);
    await db.query("INSERT INTO public.profiles VALUES($1,'Naomi Owner'),($2,'Otto Owner'),($3,'Pat'),($4,'Pat'),($5,'Admin'),($6,$7)",[o1,o2,p1,p2,p3,p4,'\u200bPat\u202e '+'z'.repeat(60)]);
    const call=(who,fn,args)=>actor(who,()=>db.query(`SELECT shared_expenses.${fn} AS v`,args)).then(r=>r.rows[0].v);
    const g=uuid();
    const ownerMember=(await call(o1,"create_context($1,'group','Names',$2,$3)",[g,uuid(),H('1')])).memberId;
    const invite=(name,ctxId=g,who=o1,mid=uuid())=>call(who,'invite_member($1,$2,$3)',[{contextId:ctxId,memberId:mid,displayName:name},uuid(),H('2')]).then(()=>mid);
    const rename=(mid,name,ctxId=g,who=o1)=>call(who,'rename_member($1,$2,$3)',[{contextId:ctxId,memberId:mid,displayName:name},uuid(),H('3')]);
    const nameOf=(mid)=>db.query('SELECT display_name FROM shared_expenses.members WHERE member_id=$1',[mid]).then(r=>r.rows[0].display_name);
    const rahul=await invite('Rahul');
    for(const dup of ['rahul','RAHUL',' R a h u l ','Rahul.','R-a_h(u)l','R\u0430hul','\uff32ahul','Rah\u00fal','Ra\u200bhul','Ra\u202ehul'])
      await assert.rejects(invite(dup),/member_name_taken/,JSON.stringify(dup));
    await assert.rejects(invite('Naomi Owner'),/member_name_taken/,'the owner\'s own live name counts');
    await assert.rejects(invite('naomi  owner'),/member_name_taken/);
    for(const word of ['You','me','Myself','Owner','ADMIN','Support','Someone','PandaPay','Panda Pay','Pand\u0430 Pay','pandapay friend','Former member','FORMER-MEMBER','Unknown','Deleted'])
      await assert.rejects(invite(word),/member_name_reserved/,word);
    for(const nothing of ['...','!!','\u0085',' \u200b '])await assert.rejects(invite(nothing),/invalid_member_name/,JSON.stringify(nothing));
    const meera=await invite('Meera');
    // rename
    await assert.rejects(rename(meera,'RAHUL'),/member_name_taken/);
    await assert.rejects(rename(meera,'Admin'),/member_name_reserved/);
    await assert.rejects(rename(meera,'...'),/invalid_member_name/);
    assert.equal((await rename(meera,'MEERA')).displayName,'MEERA','case only');
    assert.equal((await rename(meera,'M e e r a')).displayName,'M e e r a','spacing only');
    assert.equal((await rename(meera,'Meera Two')).displayName,'Meera Two');
    assert.equal(await nameOf(rahul),'Rahul');
    // legacy duplicates are grandfathered: only a changed label is checked
    const d1=uuid(), d2=uuid(), d3=await invite('Dana');
    await db.query("INSERT INTO shared_expenses.members(context_id,member_id,role,state,display_name) VALUES($1,$2,'member','invited','Twin'),($1,$3,'member','invited','twin')",[g,d1,d2]);
    assert.equal((await rename(d1,'TWIN')).status,'renamed','same key as its own current label');
    assert.equal((await rename(d2,'Twin')).status,'renamed','its legacy twin does not block it');
    await assert.rejects(rename(d3,'Twin'),/member_name_taken/,'but nobody else may take it');
    // group-link placeholders get a numeric suffix, cleaned and reserved names fall back
    const link=tok();
    await call(o1,'create_group_link($1,$2,$3,$4)',[g,link,uuid(),H('4')]);
    const claim=(who)=>call(who,'claim_invitation($1,$2,$3,$4,$5,$6)',[link,phoneHash('+9199'+who.slice(-6).replace(/\D/g,'1')),'0000',uuid(),H('5'),'none']);
    const c1=await claim(p1), c2=await claim(p2), c3=await claim(p3), c4=await claim(p4);
    assert.deepEqual([await nameOf(c1.memberId),await nameOf(c2.memberId)],['Pat','Pat (2)']);
    assert.equal(await nameOf(c3.memberId),'PandaPay user','a reserved profile name falls back');
    const long=await nameOf(c4.memberId);
    assert.ok(Array.from(long).length<=40);assert.match(long,/^Pat z+/);assert.ok(!/[\u200b\u202e]/.test(long));
    // friends: one direct split per friend name for a creator
    const d=uuid(), friend=uuid();
    await call(o2,"create_context($1,'direct','Anil',$2,$3)",[d,uuid(),H('6')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:d,memberId:friend,displayName:'Anil'},uuid(),H('7')]);
    for(const dup of ['anil','ANIL ','An\u00efl']) {
      const e=await call(o2,"create_context($1,'direct',$2,$3,$4)",[uuid(),dup,uuid(),H('8')]).then(()=>null,(x)=>x);
      assert.equal(e?.message,'friend_name_taken',dup);assert.equal(e.detail,d,'the error points at the existing split');
    }
    await assert.rejects(call(o2,"create_context($1,'direct','You',$2,$3)",[uuid(),uuid(),H('9')]),/member_name_reserved/);
    assert.equal((await call(o1,"create_context($1,'direct','Anil',$2,$3)",[uuid(),uuid(),H('a')])).status,'created','another creator may have an Anil');
    const d2c=uuid(), friend2=uuid();
    await call(o2,"create_context($1,'direct','Bela',$2,$3)",[d2c,uuid(),H('b')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:d2c,memberId:friend2,displayName:'Bela'},uuid(),H('c')]);
    const taken=await rename(friend2,'anil',d2c,o2).then(()=>null,(x)=>x);
    assert.equal(taken?.message,'friend_name_taken');assert.equal(taken.detail,d);
    const d3c=uuid();
    await call(o2,"create_context($1,'direct','Cora',$2,$3)",[d3c,uuid(),H('d')]);
    const third=await invite('ANIL',d3c,o2,uuid()).then(()=>null,(x)=>x);
    assert.equal(third?.message,'friend_name_taken','inviting into another direct split checks friends too');
    assert.equal((await rename(friend2,'Bela B',d2c,o2)).status,'renamed');
    assert.equal((await rename(friend,'ANIL',d,o2)).status,'renamed','renaming a friend to its own name is fine');
    // vectors shared with Node
    const vectors=require('../../contracts/shared_expenses/v1/label_key_vectors.json');
    for(const v of vectors.labelKey)assert.equal((await db.query('SELECT shared_expenses._label_key($1) AS v',[v.input])).rows[0].v,v.key,'label key '+JSON.stringify(v.input));
    for(const v of vectors.cleanLabel)assert.equal((await db.query('SELECT shared_expenses._clean_label($1) AS v',[v.input])).rows[0].v,v.clean,'clean '+JSON.stringify(v.input));
    for(const v of vectors.labelKey)assert.equal(labelLib.labelKey(v.input),v.key);
    for(const v of vectors.reserved)assert.equal((await db.query('SELECT shared_expenses._label_reserved(shared_expenses._label_key($1)) AS v',[v.input])).rows[0].v,v.reserved,'reserved '+JSON.stringify(v.input));
    for(const v of vectors.reserved)assert.equal(labelLib.isReservedLabel(v.input),v.reserved);
  });
  await t.test('join identity review fixes: replay, caps, scoping, friends, cleaning, group-link audience',async()=>{
    const H=(ch)=>ch.repeat(64), uuid=()=>crypto.randomUUID(), tok=()=>crypto.randomBytes(32).toString('hex');
    const o=pid(0x30), o2=pid(0x31), c1=pid(0x32), c2=pid(0x33), c3=pid(0x34), c4=pid(0x35), fr=pid(0x36), stray=pid(0x38);
    await db.query("INSERT INTO public.profiles VALUES($1,'Pia Owner'),($2,'Quin Owner'),($3,'Rita Claim'),($4,'Sita Claim'),($5,'Tara Claim'),($6,'Uma Claim'),($7,'Vik Friend'),($8,'Xan Stray')",[o,o2,c1,c2,c3,c4,fr,stray]);
    const E={[c1]:'+917234500001',[c2]:'+917299900001',[c3]:'+917234500003',[c4]:'+917288800003'};
    const call=(who,fn,args)=>actor(who,()=>db.query(`SELECT shared_expenses.${fn} AS v`,args)).then(r=>r.rows[0].v);
    const row=(inv)=>db.query('SELECT * FROM shared_expenses.invitations WHERE invitation_id=$1',[inv]).then(r=>r.rows[0]);
    const g=uuid(), link=tok(), g2=uuid(), link2=tok();
    await call(o,"create_context($1,'group','Review trip',$2,$3)",[g,uuid(),H('1')]);
    await call(o2,"create_context($1,'group','Other trip',$2,$3)",[g2,uuid(),H('2')]);
    await call(o,'register_phone($1,NULL)',[phoneHash('+919100000001')]);
    await call(o2,'register_phone($1,NULL)',[phoneHash('+919100000002')]);
    await call(o,'create_group_link($1,$2,$3,$4)',[g,link,uuid(),H('3')]);
    await call(o2,'create_group_link($1,$2,$3,$4)',[g2,link2,uuid(),H('4')]);
    const claim=(who,share,suffix='0001',op=uuid(),token=link,h=H('5'))=>call(who,'claim_invitation($1,$2,$3,$4,$5,$6)',[token,E[who]?phoneHash(E[who]):null,suffix,op,h,share]).then(r=>({...r,op}));
    const attach=(who,c,e164=E[who],op=c.op)=>{const sealed=encryptPhone(ring,c.invitationId,e164),shown=describePhone(e164);return call(who,'attach_claimant_phone($1,$2,$3,$4,$5,$6,$7,$8)',[c.invitationId,op,phoneHash(e164),shown.countryCode,shown.mask,sealed.enc,sealed.keyId,e164.slice(-4)]);};

    // (2) a replay is recognisable and can never re-share; a changed choice is a conflict
    const first=await claim(c1,null,'0001');
    assert.equal(first.fresh,true);
    const replay=await call(c1,'claim_invitation($1,$2,$3,$4,$5,$6)',[link,phoneHash(E[c1]),'0001',first.op,H('5'),null]);
    assert.equal(replay.fresh,undefined,'the stored reply has no fresh marker');assert.equal(replay.invitationId,first.invitationId);
    await assert.rejects(call(c1,'claim_invitation($1,$2,$3,$4,$5,$6)',[link,phoneHash(E[c1]),'0001',first.op,H('6'),null]),/operation_conflict/,'same operation, different request hash');
    assert.equal((await attach(c1,first)).attached,true);
    assert.equal((await attach(c1,first)).attached,false,'a replayed claim cannot attach twice');
    const declined=await claim(c1,'declined','0001');
    assert.equal((await attach(c1,first)).attached,false,'a stale claim cannot re-share after "ask without sharing"');
    assert.equal((await row(first.invitationId)).phone_share,'declined');
    const third=await claim(c1,null,'0001');
    assert.equal((await attach(c1,first)).attached,false,'nor after a newer claim with a different operation');
    assert.equal((await attach(c1,declined)).attached,false);
    assert.equal((await attach(c1,third)).attached,true);

    // group-link claims reach the owner's notifier: the audience resolves the LINK token to the caller's own request
    const aud=await call(c1,'invitation_audience($1)',[link]);
    assert.deepEqual(aud.owners,[o]);assert.equal(aud.contextId,g);assert.equal(aud.claimantName,'Rita Claim');
    assert.ok(!JSON.stringify(aud).includes('72345'));assert.ok(Object.keys(aud).every((k)=>!/phone/i.test(k)||k==='claimantPhoneSuffix'));
    await assert.rejects(call(c2,'invitation_audience($1)',[link]),/invitation_unavailable/,'a person who never claimed gets nothing');
    await assert.rejects(call(c1,'invitation_audience($1)',[link2]),/invitation_unavailable/);

    // (10) the caps are checked before an expired request is revived
    const z=await claim(c2,null,'0001');
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 hour' WHERE invitation_id=$1",[z.invitationId]);
    await db.query("INSERT INTO shared_expenses.members(context_id,member_id,role,state,display_name) SELECT $1,gen_random_uuid(),'member','invited','live '||n FROM generate_series(1,20) n",[g]);
    await db.query("INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,state,via_group_link,expires_at) SELECT gen_random_uuid(),$1,m.member_id,$2,encode(sha256(convert_to(m.member_id::text,'UTF8')),'hex'),gen_random_uuid(),'awaiting_owner',true,clock_timestamp()+interval '2 days' FROM shared_expenses.members m WHERE m.context_id=$1 AND m.display_name LIKE 'live %'",[g,o]);
    await assert.rejects(claim(c2,null,'0001'),/join_requests_full/,'a full list blocks the revival');
    assert.ok((await row(z.invitationId)).expires_at<new Date(),'and the request stays expired');
    await db.query("DELETE FROM shared_expenses.invitations WHERE invitation_id IN (SELECT i.invitation_id FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE m.display_name LIKE 'live %')");
    await db.query("DELETE FROM shared_expenses.members WHERE display_name LIKE 'live %'");
    const revived=await claim(c2,null,'0001');
    assert.equal(revived.invitationId,z.invitationId);assert.ok((await row(z.invitationId)).expires_at>new Date());

    // (9) look-alike full numbers spend the reveal budget; when it is spent the item is left out
    const l3=await claim(c3,null,'0003');await attach(c3,l3);
    const l4=await claim(c4,null,'0003');await attach(c4,l4);
    await attach(c2,revived);
    const lookalike=(await call(o,'list_join_requests()',[])).items.filter((i)=>i.claimantPhone.lookalike);
    assert.ok(lookalike.length>=4,'same mask, different numbers');
    await db.query("DELETE FROM shared_expenses.phone_reveals");
    await db.query("INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) SELECT gen_random_uuid(),$1,'tap' FROM generate_series(1,5)",[o]);
    const ids=lookalike.map((i)=>i.invitationId);
    assert.deepEqual(await call(o,'list_join_requests_enc($1)',[ids]),[],'budget spent => nothing in full, no failure');
    assert.ok((await call(o,'list_join_requests()',[])).items.filter((i)=>i.claimantPhone.lookalike).length>=4,'still marked look-alike');
    await db.query("DELETE FROM shared_expenses.phone_reveals");
    assert.equal((await call(o,'list_join_requests_enc($1)',[ids])).length,ids.length);
    assert.equal((await call(o,'list_join_requests_enc($1)',[ids])).length,ids.length,'same hour, same requests: no second charge');
    assert.equal((await db.query("SELECT count(*)::int n FROM shared_expenses.phone_reveals WHERE via='lookalike'")).rows[0].n,ids.length);
    await db.query("DELETE FROM shared_expenses.phone_directory WHERE profile_id=$1",[o]);
    await db.query("DELETE FROM shared_expenses.phone_reveals");
    assert.deepEqual(await call(o,'list_join_requests_enc($1)',[ids]),[],'the owner needs a verified number for this too');
    assert.equal((await call(o,'reveal_claimant_phone($1)',[l3.invitationId])).error,'owner_phone_required');
    assert.equal((await call(o,'check_claimant_phone($1,$2)',[l3.invitationId,H('a')])).error,'owner_phone_required');
    await call(o,'register_phone($1,NULL)',[phoneHash('+919100000001')]);

    // (16) check-phone is audited and capped per owner per day
    assert.equal((await call(o,'check_claimant_phone($1,$2)',[l3.invitationId,H('a')])).matches,false);
    assert.equal((await db.query("SELECT count(*)::int n FROM shared_expenses.phone_reveals WHERE via='check' AND owner_profile_id=$1",[o])).rows[0].n,1);
    await db.query("INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) SELECT $1,$2,'check' FROM generate_series(1,20)",[l3.invitationId,o]);
    assert.equal((await call(o,'check_claimant_phone($1,$2)',[l3.invitationId,H('b')])).error,'check_rate_limited');
    await db.query("DELETE FROM shared_expenses.phone_reveals");

    // (15) once a request is resolved nothing is guessed about its number any more
    await call(o,'respond_invitation($1,true,$2,$3)',[l3.invitationId,uuid(),H('7')]);
    const resolved=(await call(o,'list_invitations($1,NULL)',[g])).items.find((i)=>i.invitationId===l3.invitationId).claimantPhone;
    assert.equal(resolved.numberStatus,'unknown');assert.equal(resolved.lookalike,false);assert.deepEqual(resolved.duplicateOf,[]);assert.equal(resolved.mask,null);assert.equal(resolved.available,false);

    // (14) the lazy purge touches only the reader's own splits, and never breaks a read-only read
    const other=await claim(c3,null,'0003',uuid(),link2);await attach(c3,other);
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=$1",[other.invitationId]);
    await call(o,'list_join_requests()',[]);
    assert.ok((await row(other.invitationId)).claimant_phone_enc,'another owner\'s expired row is left alone by this owner\'s read');
    await call(o2,'list_join_requests()',[]);
    assert.equal((await row(other.invitationId)).claimant_phone_enc,null,'its own owner\'s read purges it');
    const other2=await claim(c4,null,'0003',uuid(),link2);await attach(c4,other2);
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=$1",[other2.invitationId]);
    assert.ok((await db.query('SELECT shared_expenses.purge_expired_claimant_phones() AS n')).rows[0].n>=1);
    assert.equal((await row(other2.invitationId)).claimant_phone_enc,null);
    const sentinel=new Error('rollback-read-only');
    await assert.rejects(actor(o,async()=>{
      await db.query('SET LOCAL transaction_read_only=on');
      const listed=(await db.query('SELECT shared_expenses.list_join_requests() AS v')).rows[0].v;
      assert.ok(Array.isArray(listed.items),'a read-only transaction still lists');
      throw sentinel;
    }),/rollback-read-only/);

    // (5) deletion: indexed, never blocked by a scrub problem, erases the owner id of audit rows
    assert.equal((await db.query("SELECT count(*)::int n FROM pg_indexes WHERE schemaname='shared_expenses' AND indexname='shared_invitations_claimed_profile'")).rows[0].n,1);
    await db.query("INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via) VALUES($1,$2,'tap')",[l4.invitationId,stray]);
    await db.query('DELETE FROM public.profiles WHERE id=$1',[stray]);
    assert.equal((await db.query('SELECT count(*)::int n FROM shared_expenses.phone_reveals WHERE owner_profile_id IS NULL')).rows[0].n,1);
    const broken=await claim(c4,null,'0003',uuid(),link);
    await db.query("ALTER TABLE shared_expenses.invitations ADD CONSTRAINT scrub_boom CHECK(phone_share<>'none') NOT VALID");
    await db.query('DELETE FROM public.profiles WHERE id=$1',[c4]);
    assert.equal((await db.query('SELECT count(*)::int n FROM public.profiles WHERE id=$1',[c4])).rows[0].n,0,'the account is gone even though the scrub could not finish');
    await db.query('ALTER TABLE shared_expenses.invitations DROP CONSTRAINT scrub_boom');
    assert.equal(broken.status,'awaiting_owner');

    // (3) + (8) friends: only the creator is checked against their own list, a gone friend never blocks
    const d1=uuid(), d1m=uuid(), d2=uuid(), d2m=uuid();
    await call(o2,"create_context($1,'direct','Kiran',$2,$3)",[d1,uuid(),H('8')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:d1,memberId:d1m,profileId:fr,displayName:'Kiran'},uuid(),H('9')]);
    await call(fr,'respond_membership($1,$2,$3,$4,$5)',[d1,d1m,true,uuid(),H('a')]);
    await call(o2,"create_context($1,'direct','Lena',$2,$3)",[d2,uuid(),H('b')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:d2,memberId:d2m,displayName:'Lena'},uuid(),H('c')]);
    const e=await call(o2,'rename_member($1,$2,$3)',[{contextId:d2,memberId:d2m,displayName:'kiran'},uuid(),H('d')]).then(()=>null,(x)=>x);
    assert.equal(e?.message,'friend_name_taken');assert.equal(e.detail,d1,'the creator is pointed at their own split');
    // the counterpart renaming THEIR OWN row is never checked against the creator's friends list
    const selfRename=await call(fr,'rename_member($1,$2,$3)',[{contextId:d1,memberId:d1m,displayName:'Lena'},uuid(),H('e')]);
    assert.equal(selfRename.displayName,'Lena');
    // the creator's friend who left or was removed does not dead-end the name
    const gone=uuid(), goneM=uuid();
    await call(o2,"create_context($1,'direct','Mira',$2,$3)",[gone,uuid(),H('2')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:gone,memberId:goneM,displayName:'Mira'},uuid(),H('3')]);
    const again=await call(o2,"create_context($1,'direct','mira',$2,$3)",[uuid(),uuid(),H('4')]).then(()=>null,(x)=>x);
    assert.equal(again?.message,'friend_name_taken','while Mira is invited');
    await call(o2,'remove_member($1,$2,$3,$4)',[gone,goneM,uuid(),H('5')]);
    assert.equal((await call(o2,"create_context($1,'direct','mira',$2,$3)",[uuid(),uuid(),H('6')])).status,'created','after removal the name is free again');
    // an invitation that expired unanswered also frees the name
    const exp=uuid(), expM=uuid();
    await call(o2,"create_context($1,'direct','Noor',$2,$3)",[exp,uuid(),H('7')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:exp,memberId:expM,displayName:'Noor'},uuid(),H('8')]);
    await call(o2,'create_invitation($1,$2)',[{invitationId:uuid(),contextId:exp,memberId:expM,targetPhoneHash:null,tokenHash:tok()},H('9')]);
    await db.query("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 day' WHERE context_id=$1",[exp]);
    assert.equal((await call(o2,"create_context($1,'direct','noor',$2,$3)",[uuid(),uuid(),H('a')])).status,'created');
    // a declined friend does not use up the direct split's two seats
    const seat=uuid(), seatM=uuid(), seatM2=uuid();
    await call(o2,"create_context($1,'direct','Omar',$2,$3)",[seat,uuid(),H('b')]);
    await call(o2,'invite_member($1,$2,$3)',[{contextId:seat,memberId:seatM,displayName:'Omar'},uuid(),H('c')]);
    await call(o2,'remove_member($1,$2,$3,$4)',[seat,seatM,uuid(),H('d')]);
    assert.equal((await call(o2,'invite_member($1,$2,$3)',[{contextId:seat,memberId:seatM2,displayName:'Omar B'},uuid(),H('e')])).status,'invited');

    // (13) names that reach other people are cleaned wherever they come from
    const dirty='Bad‮ ​Trip';
    const named=uuid();
    await call(o2,"create_context($1,'group',$2,$3,$4)",[named,dirty+'\n'+'y'.repeat(100),uuid(),H('f')]).catch((x)=>assert.fail(x.message));
    const storedName=(await db.query('SELECT name FROM shared_expenses.contexts WHERE context_id=$1',[named])).rows[0].name;
    assert.ok(!/[‮​\n]/.test(storedName));assert.ok(Array.from(storedName).length<=120);assert.match(storedName,/^Bad Trip y+/);
    await db.query("UPDATE shared_expenses.contexts SET name=$2 WHERE context_id=$1",[named,'Legacy‮​ name']);
    assert.equal((await db.query("SELECT shared_expenses._context_label('group','Legacy‮​ name',$1,$1,$2) AS v",[o2,named])).rows[0].v,'Legacy name','stored legacy names are cleaned on the way out');
    assert.equal((await db.query("SELECT shared_expenses._member_label($1,NULL) AS v",['Eve‮l​'])).rows[0].v,'Evel');
    await db.query("UPDATE public.profiles SET display_name=$2 WHERE id=$1",[o2,'Quin‮​ Owner']);
    const pv=await call(c3,'preview_invitation($1)',[link2]);
    assert.equal(pv.ownerName,'Quin Owner');
  });
});
