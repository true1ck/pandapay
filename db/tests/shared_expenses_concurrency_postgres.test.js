'use strict';
// Committed synthetic fixtures and independent PostgreSQL sessions. This suite
// creates only its fixed, absent, explicitly named local database; no dotenv.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {createRequire}=require('node:module');
const {transactionalSql}=require('../scripts/product_migrate');
const requireApi=createRequire(path.resolve(__dirname,'../../api/package.json'));
const raw=process.env.PANDAPAY_SHARED_EXPENSES_CONCURRENCY_TEST_URL;
const DB='shared_expenses_concurrency_test';
const A='10000000-0000-0000-0000-000000000001',B='10000000-0000-0000-0000-000000000002',C='10000000-0000-0000-0000-000000000003';
const id=()=>crypto.randomUUID();
const hash=payload=>crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
function fixtureUrl(value){
 if(!value)throw new Error('explicit concurrency fixture URL required');
 const url=new URL(value);
 if(!['postgres:','postgresql:'].includes(url.protocol)||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.pathname!==`/${DB}`||url.search||url.hash)throw new Error('loopback shared_expenses_concurrency_test required');
 return url;
}
const localAddress=value=>['127.0.0.1','::1','::ffff:127.0.0.1'].includes(value);

test('concurrency fixture refuses ambient or existing-product database targets',()=>{
 assert.throws(()=>fixtureUrl());
 for(const value of ['postgres://localhost/pandapay','postgres://remote/shared_expenses_concurrency_test','postgres://localhost/shared_expenses_concurrency_test?sslmode=require'])assert.throws(()=>fixtureUrl(value));
});

test('real independent sessions serialize commands and publish only committed stream positions',{skip:!raw&&'explicit concurrency database URL not supplied',timeout:60000},async t=>{
 const {Client}=requireApi('pg');
 const target=fixtureUrl(raw),adminUrl=new URL(target);adminUrl.pathname='/postgres';
 const marker=`pp-split-race:${id()}`;
 const admin=new Client({connectionString:adminUrl.toString(),connectionTimeoutMillis:5000,application_name:marker});
 const sessions=new Set();let ownsDatabase=false;
 await admin.connect();
 t.after(async()=>{
   for(const session of sessions)await session.close();
   if(ownsDatabase){
     const check=await admin.query('SELECT shobj_description(oid,\'pg_database\') AS marker FROM pg_database WHERE datname=$1',[DB]);
     assert.equal(check.rows[0]?.marker,marker,'refuse cleanup without exact creation ownership marker');
     await admin.query('DROP DATABASE shared_expenses_concurrency_test');
   }
   await admin.end();
 });
 assert.ok(localAddress(admin.connection.stream.remoteAddress));
 assert.equal((await admin.query('SELECT count(*)::int n FROM pg_database WHERE datname=$1',[DB])).rows[0].n,0,'refuse existing database, even a former fixture');
 await admin.query('CREATE DATABASE shared_expenses_concurrency_test');ownsDatabase=true;
 // Fixed database name; the comment is a generated opaque ownership marker.
 await admin.query(`COMMENT ON DATABASE shared_expenses_concurrency_test IS '${marker}'`);
 const setup=new Client({connectionString:target.toString(),connectionTimeoutMillis:5000,application_name:marker});
 await setup.connect();
 try{
 await setup.query(`
 DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='app_user') THEN CREATE ROLE app_user NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$;
 CREATE SCHEMA pandapay;
 CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$;
 CREATE TABLE public.profiles(id uuid PRIMARY KEY);
 CREATE TABLE public.transactions(id uuid PRIMARY KEY,profile_id uuid,amount_inr numeric(12,2),occurred_at timestamptz,status text,entry_kind text,source text,instrument text,updated_at timestamptz,pipeline_version smallint,event_id text,source_key text);
 CREATE TABLE public.sms_v2_events(event_id text PRIMARY KEY,profile_id uuid,type text,status text,amount_minor bigint,updated_at timestamptz);
 CREATE TABLE public.sms_v2_instruments(instrument_id uuid PRIMARY KEY,profile_id uuid,status text,updated_at timestamptz);
 CREATE TABLE public.sms_v2_ledger_entries(entry_id text PRIMARY KEY,profile_id uuid,event_id text,from_instrument_id uuid,from_external text,from_own_unresolved text,to_instrument_id uuid,to_external text,to_own_unresolved text,amount_minor bigint,unit text,is_spend boolean,counts_as_transaction boolean,updated_at timestamptz);
 CREATE TABLE public.foreign_payments(id uuid PRIMARY KEY,profile_id uuid,transaction_id uuid,valuation_status text,billed_inr numeric(12,2),original_currency text,original_amount numeric(26,4),direction text,confirmation_source text,revision int,updated_at timestamptz);
 ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
 CREATE POLICY owner_scope ON public.profiles FOR ALL USING(id=pandapay.uid()) WITH CHECK(id=pandapay.uid());
 DO $$ DECLARE n text; BEGIN FOREACH n IN ARRAY ARRAY['transactions','sms_v2_events','sms_v2_instruments','sms_v2_ledger_entries','foreign_payments'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n); EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',n); EXECUTE format('CREATE POLICY owner_scope ON public.%I FOR ALL USING(profile_id=pandapay.uid()) WITH CHECK(profile_id=pandapay.uid())',n); END LOOP; END $$;
 `);
 await setup.query('BEGIN');
 await setup.query(transactionalSql(fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261112210000_shared_expenses_foundation.sql'),'utf8')));
 await setup.query('COMMIT');
 await setup.query('GRANT USAGE ON SCHEMA public,pandapay TO app_user;GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO app_user;GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pandapay TO app_user');
 await setup.query('INSERT INTO public.profiles VALUES($1),($2),($3)',[A,B,C]);
 await setup.query('UPDATE shared_expenses.settings SET reads_enabled=true,proposals_enabled=true,accepted_writes_enabled=true,settlements_enabled=true');
 }finally{await setup.end();}
 async function begin(actor){
   const client=new Client({connectionString:target.toString(),connectionTimeoutMillis:5000,application_name:marker});
   client.on('error',()=>{});await client.connect();
   const pid=(await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
   await client.query('BEGIN');await client.query("SET LOCAL statement_timeout='8000ms';SET LOCAL lock_timeout='6000ms';SET LOCAL ROLE app_user");
   await client.query("SELECT set_config('app.user_id',$1,true)",[actor]);
   let closed=false;
   const session={client,pid,query:(sql,args)=>client.query(sql,args),commit:()=>client.query('COMMIT'),close:async()=>{if(closed)return;closed=true;await client.query('ROLLBACK').catch(()=>{});await client.end().catch(()=>{});sessions.delete(session);}};
   sessions.add(session);return session;
 }
 async function invoke(session,fn,payload,operation=id()){
   if(fn==='create_context')return(await session.query('SELECT shared_expenses.create_context($1,$2,$3,$4,$5) AS v',[payload.contextId,payload.contextKind,payload.name,operation,hash(payload)])).rows[0].v;
   if(fn==='respond_membership')return(await session.query('SELECT shared_expenses.respond_membership($1,$2,$3,$4,$5) AS v',[payload.contextId,payload.memberId,payload.accept,operation,hash(payload)])).rows[0].v;
   assert.ok(['invite_member','submit_proposal','respond_expense','report_settlement','respond_settlement'].includes(fn));
   return(await session.query(`SELECT shared_expenses.${fn}($1::jsonb,$2::uuid,$3::text) AS v`,[payload,operation,hash(payload)])).rows[0].v;
 }
 async function command(actor,fn,payload,operation=id()){
   const session=await begin(actor);try{const result=await invoke(session,fn,payload,operation);await session.commit();return result;}finally{await session.close();}
 }
 async function read(actor,sql,args){const session=await begin(actor);try{return await session.query(sql,args);}finally{await session.close();}}
 async function inspect(sql,args){const client=new Client({connectionString:target.toString(),connectionTimeoutMillis:5000,application_name:marker});await client.connect();try{return await client.query(sql,args);}finally{await client.end();}}
 async function blocked(session){
   const deadline=Date.now()+2500;
   while(Date.now()<deadline){
     const state=await admin.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1 AND datname=$2 AND application_name=$3',[session.pid,DB,marker]);
     if(state.rows[0]?.wait_event_type==='Lock')return;
     await new Promise(resolve=>setTimeout(resolve,15));
   }
   assert.fail('expected independent session to wait on a real PostgreSQL lock');
 }
 async function group(kind='group',includeC=false){
   const contextId=id(), created=await command(A,'create_context',{contextId,contextKind:kind,name:'Synthetic race'});
   const a=created.memberId,b=id();
   await command(A,'invite_member',{contextId,memberId:b,profileId:B,displayName:'Synthetic B'});
   await command(B,'respond_membership',{contextId,memberId:b,accept:true});
   let c=null;if(includeC){c=id();await command(A,'invite_member',{contextId,memberId:c,profileId:C,displayName:'Synthetic C'});await command(C,'respond_membership',{contextId,memberId:c,accept:true});}
   return{contextId,a,b,c};
 }
 function expense(g,expenseId,revisionId,total,previous=null){return{contextId:g.contextId,expenseId,revisionId,expectedHeadRevisionId:previous,snapshot:{currency:'INR',totalMinor:String(total),contributions:[{memberId:g.a,amountMinor:String(total)}],shares:[{memberId:g.a,amountMinor:String(total/2)},{memberId:g.b,amountMinor:String(total/2)}],memberOrder:[g.a,g.b]},title:'Synthetic expense',occurredOn:'2026-11-04',sources:[],void:false};}
 async function acceptExpense(g,total=120000){const expenseId=id(),revisionId=id();await command(A,'submit_proposal',expense(g,expenseId,revisionId,total));await command(B,'respond_expense',{contextId:g.contextId,expenseId,revisionId,decision:'approve'});return{expenseId,revisionId};}

 await t.test('same-operation retry waits for its original commit and returns one durable receipt',async()=>{
   const operation=id(),payload={contextId:id(),contextKind:'group',name:'Exact replay'};
   const first=await begin(A),second=await begin(A);
   try{
     const original=await invoke(first,'create_context',payload,operation);
     const pending=invoke(second,'create_context',payload,operation);pending.catch(()=>{});
     await blocked(second);
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.contexts WHERE context_id=$1',[payload.contextId])).rows[0].n,0);
     await first.commit();assert.deepEqual(await pending,original);await second.commit();
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.operation_receipts WHERE operation_id=$1',[operation])).rows[0].n,1);
     assert.equal((await read(A,'SELECT committed_sequence::text FROM shared_expenses.contexts WHERE context_id=$1',[payload.contextId])).rows[0].committed_sequence,'1');
   }finally{await first.close();await second.close();}
 });
 await t.test('same operation with changed payload conflicts after the winning transaction commits',async()=>{
   const operation=id(),payload={contextId:id(),contextKind:'group',name:'Original'};
   const first=await begin(A),second=await begin(A);
   try{
     await invoke(first,'create_context',payload,operation);
     const pending=invoke(second,'create_context',{...payload,name:'Changed'},operation);pending.catch(()=>{});
     await blocked(second);await first.commit();await assert.rejects(pending,/operation_conflict/);
     assert.equal((await read(A,'SELECT name FROM shared_expenses.contexts WHERE context_id=$1',[payload.contextId])).rows[0].name,'Original');
   }finally{await first.close();await second.close();}
 });
 await t.test('two first accepted heads cannot overwrite the same expense precondition',async()=>{
   const g=await group(),expenseId=id(),r1=id(),r2=id();
   const payload=expense(g,expenseId,r1,100);
   payload.snapshot.shares=[{memberId:g.a,amountMinor:'100'}];payload.snapshot.memberOrder=[g.a];
   const first=await begin(A),second=await begin(A);
   try{
     assert.equal((await invoke(first,'submit_proposal',payload)).status,'accepted');
     const pending=invoke(second,'submit_proposal',{...payload,revisionId:r2});pending.catch(()=>{});
     await blocked(second);await first.commit();await assert.rejects(pending,/revision_head_conflict/);
     assert.equal((await read(A,'SELECT accepted_revision_id,head_version::text FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2',[g.contextId,expenseId])).rows[0].accepted_revision_id,r1);
   }finally{await first.close();await second.close();}
 });
 await t.test('competing complete revisions keep one accepted balanced head and invalidate the stale review',async()=>{
   const g=await group(),base=await acceptExpense(g),r1=id(),r2=id();
   await command(A,'submit_proposal',expense(g,base.expenseId,r1,90000,base.revisionId));
   await command(A,'submit_proposal',expense(g,base.expenseId,r2,60000,base.revisionId));
   const first=await begin(B),second=await begin(B);
   try{
     assert.equal((await invoke(first,'respond_expense',{contextId:g.contextId,expenseId:base.expenseId,revisionId:r1,decision:'approve'})).status,'accepted');
     const pending=invoke(second,'respond_expense',{contextId:g.contextId,expenseId:base.expenseId,revisionId:r2,decision:'approve'});pending.catch(()=>{});
     await blocked(second);await first.commit();await assert.rejects(pending,/revision_head_conflict/);
     const rows=(await read(A,'SELECT member_id,balance_minor::text FROM shared_expenses.member_balances WHERE context_id=$1',[g.contextId])).rows;
     assert.deepEqual(Object.fromEntries(rows.map(row=>[row.member_id,row.balance_minor])),{[g.a]:'45000',[g.b]:'-45000'});
     assert.equal((await read(A,'SELECT head_version::text FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2',[g.contextId,base.expenseId])).rows[0].head_version,'2');
   }finally{await first.close();await second.close();}
 });
 await t.test('independent confirmed payments on one pair accumulate exactly and preserve overpayment credit',async()=>{
   const g=await group();await acceptExpense(g);
   const one=id(),two=id();
   for(const [settlementId,amountMinor]of[[one,'40000'],[two,'30000']])await command(B,'report_settlement',{contextId:g.contextId,settlementId,payerMemberId:g.b,receiverMemberId:g.a,amountMinor,currency:'INR',method:'upi',paidOn:'2026-11-04'});
   const first=await begin(A),second=await begin(A);
   try{
     await invoke(first,'respond_settlement',{contextId:g.contextId,settlementId:one,decision:'confirm'});
     const pending=invoke(second,'respond_settlement',{contextId:g.contextId,settlementId:two,decision:'confirm'});pending.catch(()=>{});
     await blocked(second);await first.commit();await pending;await second.commit();
     const rows=(await read(A,'SELECT member_id,balance_minor::text FROM shared_expenses.member_balances WHERE context_id=$1',[g.contextId])).rows;
     assert.deepEqual(Object.fromEntries(rows.map(row=>[row.member_id,row.balance_minor])),{[g.a]:'-10000',[g.b]:'10000'});
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.settlement_events WHERE context_id=$1',[g.contextId])).rows[0].n,2);
     assert.equal((await read(A,"SELECT sum(amount_minor)::text credit FROM shared_expenses.settlement_allocations WHERE context_id=$1 AND kind='pair_credit'",[g.contextId])).rows[0].credit,'10000');
   }finally{await first.close();await second.close();}
 });
 await t.test('two receiver confirmations of the same report apply one permanent financial effect',async()=>{
   const g=await group();await acceptExpense(g);const sid=id();
   await command(B,'report_settlement',{contextId:g.contextId,settlementId:sid,payerMemberId:g.b,receiverMemberId:g.a,amountMinor:'30000',currency:'INR',method:'cash',paidOn:'2026-11-04'});
   const first=await begin(A),second=await begin(A),payload={contextId:g.contextId,settlementId:sid,decision:'confirm'};
   try{
     const accepted=await invoke(first,'respond_settlement',payload);
     const pending=invoke(second,'respond_settlement',payload);pending.catch(()=>{});
     await blocked(second);await first.commit();const duplicate=await pending;await second.commit();
     assert.equal(duplicate.eventId,accepted.eventId);
     assert.equal((await read(A,"SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1 AND kind='settlement'",[g.contextId])).rows[0].n,1);
     assert.equal((await read(A,'SELECT balance_minor::text FROM shared_expenses.member_balances WHERE context_id=$1 AND member_id=$2',[g.contextId,g.b])).rows[0].balance_minor,'-30000');
   }finally{await first.close();await second.close();}
 });
 await t.test('concurrent invitations serialize the direct-context identity limit',async()=>{
   const contextId=id();await command(A,'create_context',{contextId,contextKind:'direct',name:'Direct cap'});
   const first=await begin(A),second=await begin(A);
   try{
     await invoke(first,'invite_member',{contextId,memberId:id(),profileId:B,displayName:'B'});
     const pending=invoke(second,'invite_member',{contextId,memberId:id(),profileId:C,displayName:'C'});pending.catch(()=>{});
     await blocked(second);await first.commit();await assert.rejects(pending,/context_member_limit/);
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.members WHERE context_id=$1',[contextId])).rows[0].n,2);
   }finally{await first.close();await second.close();}
 });
 await t.test('concurrent invitations cannot exceed 200 identities in a group including shadows',async()=>{
   const contextId=id();await command(A,'create_context',{contextId,contextKind:'group',name:'Group cap'});
   await inspect("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) SELECT $1,gen_random_uuid(),null,'member','invited','Synthetic shadow' FROM generate_series(1,198)",[contextId]);
   const first=await begin(A),second=await begin(A);
   try{
     await invoke(first,'invite_member',{contextId,memberId:id(),profileId:B,displayName:'B'});
     const pending=invoke(second,'invite_member',{contextId,memberId:id(),profileId:C,displayName:'C'});pending.catch(()=>{});
     await blocked(second);await first.commit();await assert.rejects(pending,/context_member_limit/);
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.members WHERE context_id=$1',[contextId])).rows[0].n,200);
   }finally{await first.close();await second.close();}
 });
 await t.test('source admission shares the established owner-ingest lock and stale snapshots fail after a competing writer',async()=>{
   const tx=id(),instrument=id(),event='a'.repeat(64),entry='b'.repeat(64);
   await inspect("INSERT INTO public.transactions VALUES($1,$2,100,clock_timestamp(),'active','spend','sms','credit_card',clock_timestamp(),2,$3,null)",[tx,A,event]);
   await inspect("INSERT INTO public.sms_v2_events VALUES($1,$2,'purchase','complete',10000,clock_timestamp())",[event,A]);
   await inspect("INSERT INTO public.sms_v2_instruments VALUES($1,$2,'confirmed',clock_timestamp())",[instrument,A]);
   await inspect("INSERT INTO public.sms_v2_ledger_entries VALUES($1,$2,$3,$4,null,null,null,'Synthetic shop',null,10000,'INR',true,true,clock_timestamp())",[entry,A,event,instrument]);
   const identity={kind:'sms_v2_event',ownerAccountId:A,eventId:event};
   const current=(await read(A,'SELECT shared_expenses.inspect_source($1) AS v',[identity])).rows[0].v;
   const ref={...identity,canonicalTransactionId:tx,sourceVersion:current.sourceVersion};
   const first=await begin(A),second=await begin(A);
   try{
     assert.equal((await first.query('SELECT shared_expenses.admit_source($1) AS v',[ref])).rows[0].v.sourceVersion,current.sourceVersion);
     const pending=(async()=>{
       await second.query("SELECT pg_advisory_xact_lock(hashtextextended('transaction-ingest:'||$1::text,0))",[A]);
       await second.query('UPDATE public.transactions SET amount_inr=101,updated_at=clock_timestamp() WHERE id=$1',[tx]);
       await second.query('UPDATE public.sms_v2_events SET amount_minor=10100,updated_at=clock_timestamp() WHERE event_id=$1',[event]);
       await second.query('UPDATE public.sms_v2_ledger_entries SET amount_minor=10100,updated_at=clock_timestamp() WHERE entry_id=$1',[entry]);
     })();pending.catch(()=>{});
     await blocked(second);await first.commit();await pending;await second.commit();
     await assert.rejects(read(A,'SELECT shared_expenses.admit_source($1)',[ref]),/source_version_mismatch/);
     assert.equal((await read(A,'SELECT shared_expenses.inspect_source($1) AS v',[identity])).rows[0].v.eligibleMinor,'10100');
   }finally{await first.close();await second.close();}
 });
 await t.test('profile stream sequence cannot publish a later commit ahead of a stalled earlier command',async()=>{
   const first=await begin(A),second=await begin(A),c1=id(),c2=id();
   const before=(await read(A,'SELECT committed_sequence::text FROM shared_expenses.profile_stream_heads WHERE profile_id=$1',[A])).rows[0].committed_sequence;
   try{
     await invoke(first,'create_context',{contextId:c1,contextKind:'group',name:'Earlier commit'});
     const pending=invoke(second,'create_context',{contextId:c2,contextKind:'group',name:'Later commit'});pending.catch(()=>{});
     await blocked(second);
     assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.profile_events WHERE profile_id=$1 AND sequence>$2',[A,before])).rows[0].n,0);
     await first.commit();await pending;
     let committed=(await read(A,'SELECT sequence::text,context_id FROM shared_expenses.profile_events WHERE profile_id=$1 AND sequence>$2 ORDER BY sequence',[A,before])).rows;
     assert.deepEqual(committed,[{sequence:(BigInt(before)+1n).toString(),context_id:c1}]);
     await second.commit();
     committed=(await read(A,'SELECT sequence::text,context_id FROM shared_expenses.profile_events WHERE profile_id=$1 AND sequence>$2 ORDER BY sequence',[A,before])).rows;
     assert.deepEqual(committed,[{sequence:(BigInt(before)+1n).toString(),context_id:c1},{sequence:(BigInt(before)+2n).toString(),context_id:c2}]);
   }finally{await first.close();await second.close();}
 });
 await t.test('terminated uncommitted database session rolls back receipt, journal and head before a safe retry',async()=>{
   const g=await group(),expenseId=id(),revisionId=id(),operation=id(),payload=expense(g,expenseId,revisionId,100);
   payload.snapshot.shares=[{memberId:g.a,amountMinor:'100'}];payload.snapshot.memberOrder=[g.a];
   const session=await begin(A);
   assert.equal((await invoke(session,'submit_proposal',payload,operation)).status,'accepted');
   const own=await admin.query('SELECT datname,application_name FROM pg_stat_activity WHERE pid=$1',[session.pid]);
   assert.equal(own.rows[0].datname,DB);assert.equal(own.rows[0].application_name,marker);
   await admin.query('SELECT pg_terminate_backend($1)',[session.pid]);await session.close();
   assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.operation_receipts WHERE operation_id=$1',[operation])).rows[0].n,0);
   assert.equal((await read(A,'SELECT count(*)::int n FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2',[g.contextId,expenseId])).rows[0].n,0);
   assert.equal((await command(A,'submit_proposal',payload,operation)).status,'accepted');
   assert.equal((await read(A,'SELECT head_version::text FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2',[g.contextId,expenseId])).rows[0].head_version,'1');
 });
 // The database is removed by the exact-marker ownership cleanup hook.
});
