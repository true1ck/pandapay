'use strict';
// Fresh explicitly named loopback fixtures only. No DATABASE_URL or .env reads.
const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const crypto=require('node:crypto');const {Pool}=require('pg');
const {createAccountLifecycleWorker}=require('../src/account_lifecycle_worker');
const {applyAccountDeletion}=require('../../auth/src/services/accountLifecycle');
const ROOT=path.resolve(__dirname,'../..');
const ident=value=>'"'+value.replaceAll('"','""')+'"';
function config(raw,database){
 if(!raw)throw Error('Explicit synthetic lifecycle fixture URL is required');const url=new URL(raw);
 if(!['postgres:','postgresql:'].includes(url.protocol)||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.pathname!=='/'+database||!url.username||!url.password||url.search||url.hash)throw Error('Fresh loopback '+database+' is required');
 return{connectionString:raw,ssl:false,max:4,connectionTimeoutMillis:3000};
}
async function fresh(pool,name){
 const state=(await pool.query(`SELECT current_database() AS name,host(inet_server_addr()) AS address`)).rows[0];
 const attested=process.env.ACCOUNT_LIFECYCLE_TEST_SERVER_ADDRESS;
 if(attested&&!require('node:net').isIP(attested))throw Error('Invalid fixture server attestation');
 assert.equal(state.name,name);assert.ok(['127.0.0.1','::1',...(attested?[attested]:[])].includes(state.address));
 const count=(await pool.query(`SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','extensions') AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%' AND c.relname<>'sql_features'`)).rows[0].count;
 assert.equal(count,0,'fixture refuses nonempty database');
}
const pools=[];
async function login(admin,base,membership){
 const role='lifecycle_'+crypto.randomBytes(6).toString('hex'),password=crypto.randomBytes(24).toString('hex');
 await admin.query(`CREATE ROLE ${ident(role)} LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
 if(membership)await admin.query(`GRANT ${ident(membership)} TO ${ident(role)}`);
 const url=new URL(base);url.username=role;url.password=password;
 const pool=new Pool({...config(url.href,url.pathname.slice(1)),max:3});pools.push(pool);
 const actual=(await pool.query('SELECT current_user,session_user')).rows[0];assert.equal(actual.current_user,role);assert.equal(actual.session_user,role);
 return pool;
}
async function scoped(pool,id,sql,args=[id]){
 const client=await pool.connect();try{await client.query('BEGIN');await client.query("SELECT set_config('app.user_id',$1,true)",[id]);const result=await client.query(sql,args);await client.query('COMMIT');return result;}catch(error){await client.query('ROLLBACK');throw error;}finally{client.release();}
}
async function main(){
 const productUrl=process.env.ACCOUNT_LIFECYCLE_TEST_URL,authUrl=process.env.AUTH_ACCOUNT_LIFECYCLE_TEST_URL;
 const product=new Pool(config(productUrl,'account_lifecycle_test')),auth=new Pool(config(authUrl,'auth_account_lifecycle_test'));pools.push(product,auth);
 try{
  await fresh(product,'account_lifecycle_test');await fresh(auth,'auth_account_lifecycle_test');
  const migrationDir=path.join(ROOT,'db/supabase/migrations');
  const names=['extensions_and_enums','reference_data','card_catalogue','user_domain','sync','ingest','crowdsource','admin_console','platform_ops','functions_and_views','rls_policies'];
  for(const [i,name]of names.entries())await product.query(fs.readFileSync(path.join(migrationDir,String(i+1).padStart(4,'0')+'_'+name+'.sql'),'utf8'));
  await product.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='app_user') THEN CREATE ROLE app_user NOLOGIN NOSUPERUSER NOBYPASSRLS;END IF;END $$");
  const a=crypto.randomUUID(),b=crypto.randomUUID(),c=crypto.randomUUID();
  await product.query('INSERT INTO profiles(id) VALUES ($1),($2),($3)',[a,b,c]);
  const financial=(await product.query("INSERT INTO transactions(profile_id,amount_inr,occurred_at,source) VALUES ($1,123.45,now(),'manual') RETURNING id",[a])).rows[0].id;
  await product.query('BEGIN');try{await product.query(fs.readFileSync(path.join(migrationDir,'20261023191847_durable_account_lifecycle.sql'),'utf8'));await product.query('COMMIT');}catch(error){await product.query('ROLLBACK');throw error;}
  await product.query('BEGIN');try{await product.query(fs.readFileSync(path.join(migrationDir,'20261024072435_lifecycle_journal_checkpoint.sql'),'utf8'));await product.query('COMMIT');}catch(error){await product.query('ROLLBACK');throw error;}
  await auth.query(fs.readFileSync(path.join(ROOT,'auth/db/pandapay-auth/init.sql'),'utf8'));
  await auth.query('BEGIN');try{await auth.query(fs.readFileSync(path.join(ROOT,'auth/db/migrations/0010_durable_account_lifecycle.sql'),'utf8'));await auth.query('COMMIT');}catch(error){await auth.query('ROLLBACK');throw error;}
  await auth.query("INSERT INTO users(id,email) VALUES ($1,'lifecycle-a@example.test'),($2,'lifecycle-b@example.test'),($3,'lifecycle-c@example.test')",[a,b,c]);
  await auth.query("INSERT INTO user_devices(user_id,device_identifier,device_platform) VALUES ($1,'synthetic-device','android')",[a]);
  await auth.query("INSERT INTO refresh_tokens(user_id,token_id,token_hash,device_id,expires_at) VALUES ($1,$2,'synthetic-hash','synthetic-device',now()+interval '1 day')",[a,crypto.randomUUID()]);
  const app=await login(product,productUrl,'app_user'),worker=await login(product,productUrl,'pandapay_account_lifecycle'),authWorker=await login(auth,authUrl,'pandapay_auth_lifecycle'),outsider=await login(product,productUrl,null);
  await require('../src/service_pools').checkAccountLifecycleReadiness(worker);
  const {createAccountLifecycleRuntime}=require('../../auth/src/services/accountLifecycleRuntime');
  const authRuntime=createAccountLifecycleRuntime({env:{ACCOUNT_LIFECYCLE_ENABLED:'true',AUTH_LIFECYCLE_DATABASE_URL:authWorker.options.connectionString,NODE_ENV:'test',DB_SSL:'false'}});
  try{await authRuntime.readiness();}finally{await authRuntime.close();}
  // Exercise the exact opt-in migration bootstraps, including credential
  // preservation on replay, then enter through independent LOGIN sessions.
  const bootstrapPassword='synthetic-lifecycle-bootstrap-32bytes-minimum';
  const {configureServiceCapabilities}=require('../../db/scripts/service_capabilities');
  const {configureAuthLifecycleLogin}=require('../../auth/scripts/authLifecyclePermissions');
  await configureServiceCapabilities(product,{ACCOUNT_LIFECYCLE_DB_PASSWORD:bootstrapPassword});
  await configureAuthLifecycleLogin(auth,{AUTH_LIFECYCLE_DB_PASSWORD:bootstrapPassword});
  await configureServiceCapabilities(product,{ACCOUNT_LIFECYCLE_DB_PASSWORD:'different-synthetic-password-never-installed'});
  await configureAuthLifecycleLogin(auth,{AUTH_LIFECYCLE_DB_PASSWORD:'different-synthetic-password-never-installed'});
  for(const [base,role,check] of [[productUrl,'account_lifecycle_runtime',require('../src/service_pools').checkAccountLifecycleReadiness],[authUrl,'auth_lifecycle_runtime',null]]){
    const url=new URL(base);url.username=role;url.password=bootstrapPassword;
    if(check){const pool=new Pool(config(url.href,'account_lifecycle_test'));try{await check(pool);}finally{await pool.end();}}
    else{const runtime=createAccountLifecycleRuntime({env:{ACCOUNT_LIFECYCLE_ENABLED:'true',AUTH_LIFECYCLE_DATABASE_URL:url.href,NODE_ENV:'test',DB_SSL:'false'}});try{await runtime.readiness();}finally{await runtime.close();}}
  }
  let journalHead={journal_id:'a'.repeat(64),sequence:0,head:'b'.repeat(64)};
  await product.query('UPDATE account_lifecycle.control SET journal_id=$1,journal_head=$2',[journalHead.journal_id,journalHead.head]);
  const journal={inspect:async()=>({...journalHead}),append:async(_,old)=>{journalHead={...old,sequence:old.sequence+1,head:crypto.randomBytes(32).toString('hex')};return {...journalHead};}};
  const denied=error=>error.code==='42501';
  for(const sql of ['SELECT * FROM account_lifecycle.requests','SELECT * FROM account_lifecycle.tombstones',"UPDATE account_lifecycle.control SET worker_enabled=true",'SET ROLE account_lifecycle_owner'])await assert.rejects(worker.query(sql),denied);
  await assert.rejects(app.query('SELECT account_lifecycle.claim_due(1)'),denied);
  await assert.rejects(outsider.query('SELECT account_lifecycle.claim_due(1)'),denied);
  await assert.rejects(authWorker.query('SELECT * FROM auth_private.account_deletion_tombstones'),denied);
  await assert.rejects(authWorker.query('SET ROLE auth_lifecycle_owner'),denied);
  await assert.rejects(scoped(app,a,'SELECT * FROM account_lifecycle.request_deletion($1)',[b]),denied);
  const initial=(await scoped(app,a,'SELECT * FROM account_lifecycle.request_deletion($1)')).rows[0];
  const repeat=(await scoped(app,a,'SELECT * FROM account_lifecycle.request_deletion($1)')).rows[0];assert.deepEqual(repeat,initial);
  assert.equal((initial.deletion_due_at-initial.deletion_requested_at)/86400000,30);
  const original=(await product.query('SELECT request_id,generation FROM account_lifecycle.requests WHERE profile_id=$1',[a])).rows[0];
  assert.equal((await worker.query('SELECT * FROM account_lifecycle.claim_due(25)')).rowCount,0,'DB worker gate defaults off');
  await scoped(app,a,'SELECT * FROM account_lifecycle.cancel_deletion($1)');
  await scoped(app,a,'SELECT * FROM account_lifecycle.request_deletion($1)');
  const active=(await product.query("SELECT request_id,generation FROM account_lifecycle.requests WHERE profile_id=$1 AND status='pending'",[a])).rows[0];assert.notEqual(active.request_id,original.request_id);assert.equal(active.generation,'2');
  await product.query("UPDATE profiles SET deletion_requested_at=now()-interval '31 days',deletion_due_at=now()-interval '1 day' WHERE id=$1",[a]);
  await assert.rejects(scoped(app,a,'SELECT * FROM account_lifecycle.cancel_deletion($1)'),error=>error.code==='55000');
  await product.query('UPDATE account_lifecycle.control SET worker_enabled=true');
  // A pre-existing user/sync transaction owns a shared UUID fence. Claims
  // must skip it without waiting on row locks or permitting a stale write to
  // commit after the deletion boundary.
  const held=await app.connect();
  try {
    await held.query('BEGIN');await held.query("SELECT set_config('app.user_id',$1,true)",[a]);
    await held.query('SELECT account_lifecycle.assert_access($1)',[a]);
    assert.equal((await worker.query('SELECT * FROM account_lifecycle.claim_due(1)')).rowCount,0,'active user transaction fences due claim');
    await held.query('COMMIT');
  } catch(error){await held.query('ROLLBACK').catch(()=>{});throw error;}finally{held.release();}
  const exportClient=await app.connect();let releaseExport;
  try{
    releaseExport=await require('../src/account_lifecycle_snapshot_fence').acquireSnapshotFence(exportClient,a);
    await exportClient.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    await exportClient.query("SELECT set_config('app.user_id',$1,true)",[a]);
    await exportClient.query('SELECT account_lifecycle.assert_access($1)',[a]);
    assert.equal((await worker.query('SELECT * FROM account_lifecycle.claim_due(1)')).rowCount,0,'session snapshot fence blocks due claim');
    await exportClient.query('ROLLBACK');
  }finally{if(releaseExport)await releaseExport();exportClient.release();}
  const [claims1,claims2]=await Promise.all([worker.query('SELECT * FROM account_lifecycle.claim_due(1)'),worker.query('SELECT * FROM account_lifecycle.claim_due(1)')]);
  assert.equal(claims1.rowCount+claims2.rowCount,1,'one lease across workers');const claim=(claims1.rows[0]||claims2.rows[0]);
  await assert.rejects(scoped(app,a,'SELECT account_lifecycle.assert_access($1)'),denied);
  await assert.rejects(scoped(app,a,'SELECT * FROM account_lifecycle.cancel_deletion($1)'),denied);
  assert.equal((await worker.query('SELECT account_lifecycle.finish($1,$2,true) AS ok',[active.request_id,crypto.randomUUID()])).rows[0].ok,false);
  // Crash after remote success but before product acknowledgement. Retry must
  // preserve stable UUID and reapply denial without incrementing token version.
  const payload={request_id:claim.request_id,user_id:claim.profile_id,generation:claim.generation};
  await applyAccountDeletion(authWorker,payload);await applyAccountDeletion(authWorker,payload);
  let user=(await auth.query('SELECT id,email,deleted,is_active,token_version FROM users WHERE id=$1',[a])).rows[0];
  assert.equal(user.id,a);assert.equal(user.email,'lifecycle-a@example.test');assert.equal(user.deleted,true);assert.equal(user.is_active,false);assert.equal(user.token_version,2);
  assert.equal((await auth.query('SELECT is_active FROM user_devices WHERE user_id=$1',[a])).rows[0].is_active,false);
  assert.ok((await auth.query('SELECT revoked_at FROM refresh_tokens WHERE user_id=$1',[a])).rows[0].revoked_at);
  await auth.query('UPDATE users SET deleted=false,is_active=true,token_version=1 WHERE id=$1',[a]);
  user=(await auth.query('SELECT deleted,is_active,token_version FROM users WHERE id=$1',[a])).rows[0];assert.deepEqual(user,{deleted:true,is_active:false,token_version:2},'tombstone fences identity resurrection');
  await product.query("UPDATE account_lifecycle.requests SET leased_until=now()-interval '1 second' WHERE request_id=$1",[active.request_id]);
  const run=createAccountLifecycleWorker({pool:worker,enabled:true,journal,applyAuthDeletion:data=>applyAccountDeletion(authWorker,data),logger:{warn(){}}});
  assert.equal((await run()).completed,1);
  const completed=(await product.query('SELECT status,attempts FROM account_lifecycle.requests WHERE request_id=$1',[active.request_id])).rows[0];assert.deepEqual(completed,{status:'completed',attempts:2});
  assert.equal((await product.query('SELECT id,amount_inr FROM transactions WHERE id=$1',[financial])).rows[0].amount_inr,'123.45');assert.equal((await product.query('SELECT id FROM profiles WHERE id=$1',[a])).rowCount,1,'all financial/profile data retained');
  // A cancelled generation cannot be replayed as deleted or replace another UUID.
  await assert.rejects(worker.query('SELECT account_lifecycle.replay_tombstone($1,$2,1)',[original.request_id,b]),error=>error.code==='23514');
  await assert.rejects(applyAccountDeletion(authWorker,{...payload,user_id:b}),error=>error.code==='23514');
  const replayRequest=crypto.randomUUID();await applyAccountDeletion(authWorker,{request_id:replayRequest,user_id:b,generation:'1'});
  const exported=(await authWorker.query('SELECT * FROM auth_private.list_deletion_tombstones(null,100)')).rows;
  const target=exported.find(x=>x.user_id===b);assert.ok(target);
  assert.equal((await worker.query('SELECT account_lifecycle.replay_tombstone($1,$2,$3) AS ok',[target.request_id,target.user_id,target.generation])).rows[0].ok,true);
  assert.equal((await worker.query('SELECT account_lifecycle.replay_tombstone($1,$2,$3) AS ok',[target.request_id,target.user_id,target.generation])).rows[0].ok,false);
  await assert.rejects(scoped(app,b,'SELECT account_lifecycle.assert_access($1)'),denied);
  await assert.rejects(worker.query('SELECT account_lifecycle.replay_tombstone($1,$2,$3)',[crypto.randomUUID(),b,target.generation]),error=>error.code==='23514');
  await assert.rejects(worker.query('SELECT account_lifecycle.replay_tombstone($1,$2,$3)',[target.request_id,b,'2']),error=>error.code==='23514');
  const productExport=(await worker.query('SELECT * FROM account_lifecycle.list_tombstones(null,100)')).rows;assert.equal(productExport.length,2);
  // Terminal retry exhaustion remains denied and requires reviewed operator action.
  await scoped(app,c,'SELECT * FROM account_lifecycle.request_deletion($1)');
  await product.query("UPDATE profiles SET deletion_requested_at=now()-interval '31 days',deletion_due_at=now()-interval '1 day' WHERE id=$1",[c]);
  await product.query('UPDATE account_lifecycle.requests SET attempts=9 WHERE profile_id=$1',[c]);
  const fail=createAccountLifecycleWorker({pool:worker,enabled:true,journal,applyAuthDeletion:async()=>{throw Error('synthetic unavailable');},logger:{warn(){}}});assert.equal((await fail()).failed,1);
  assert.equal((await product.query('SELECT status,attempts FROM account_lifecycle.requests WHERE profile_id=$1',[c])).rows[0].status,'blocked');
  await assert.rejects(scoped(app,c,'SELECT account_lifecycle.assert_access($1)'),denied);
  await assert.rejects(worker.query('SELECT * FROM account_lifecycle.claim_due(26)'),error=>error.code==='22023');
  await assert.rejects(app.query('SELECT pandapay.execute_account_deletion($1)',[b]),denied);
  // Legacy cron owner call is now a harmless warning, with data intact.
  await product.query('SELECT pandapay.execute_account_deletion($1)',[a]);assert.equal((await product.query('SELECT id FROM transactions WHERE id=$1',[financial])).rowCount,1);
  // Account recovery escrow is additive and bounded; uses the same real app
  // login with UUID-scoped functions and the lifecycle transaction fence.
  await product.query('BEGIN');try{await product.query(fs.readFileSync(path.join(migrationDir,'20261023192644_account_recovery_escrow.sql'),'utf8'));await product.query('COMMIT');}catch(error){await product.query('ROLLBACK');throw error;}
  const legacy=crypto.randomUUID();await product.query('INSERT INTO profiles(id) VALUES($1)',[legacy]);
  await product.query("UPDATE profiles SET deletion_requested_at=now(),deletion_due_at=now()+interval '30 days' WHERE id=$1",[legacy]);
  assert.equal((await product.query("SELECT status FROM account_lifecycle.requests WHERE profile_id=$1",[legacy])).rows[0].status,'pending');
  await product.query('UPDATE profiles SET deletion_requested_at=null,deletion_due_at=null WHERE id=$1',[legacy]);
  assert.equal((await product.query("SELECT status FROM account_lifecycle.requests WHERE profile_id=$1",[legacy])).rows[0].status,'cancelled','disabled legacy cancellation mirrors durable ledger');
  const d=crypto.randomUUID(),e=crypto.randomUUID();await product.query('INSERT INTO profiles(id) VALUES($1),($2)',[d,e]);
  await assert.rejects(scoped(app,d,'SELECT * FROM account_recovery.list_snapshots($1)'),error=>error.code==='55000');
  await product.query('UPDATE account_recovery.control SET enabled=true');
  const {PUT_SQL,READ_SQL,LIST_SQL,DELETE_SQL,wrapKey,unwrapKey,wrappingKey}=require('../src/account_recovery_routes');
  const wrap=wrappingKey(crypto.randomBytes(32).toString('base64'),'synthetic-v1');const secret=crypto.randomBytes(32);
  let latest;for(let i=0;i<3;i++){
    await product.query("UPDATE account_recovery.snapshots SET created_at=created_at-interval '16 minutes' WHERE profile_id=$1",[d]);
    const id=crypto.randomUUID(),cipher=Buffer.concat([Buffer.from('PDAR1'),crypto.randomBytes(80)]),digest=crypto.createHash('sha256').update(cipher).digest('hex');
    const wrapped=wrapKey(secret,d,id,wrap);
    const args=[d,id,wrapped,wrap.keyId,cipher,digest,true,true,'account-recovery-v1'];
    await scoped(app,d,PUT_SQL,args);assert.equal((await scoped(app,d,PUT_SQL,args)).rows[0].created,false,'stable snapshot retry');latest=id;
  }
  const rows=(await scoped(app,d,LIST_SQL)).rows;assert.equal(rows.length,2,'two recovery snapshots per account');
  const saved=(await scoped(app,d,READ_SQL,[d,latest])).rows[0];assert.deepEqual(unwrapKey(saved.wrapped_key,d,latest,saved.wrapping_key_id,wrap),secret);
  assert.equal((await scoped(app,e,READ_SQL,[e,latest])).rowCount,0,'cross-account snapshot UUID reveals nothing');
  await assert.rejects(scoped(app,e,READ_SQL,[d,latest]),denied);
  await assert.rejects(app.query('SELECT * FROM account_recovery.snapshots'),denied);
  await assert.rejects(app.query('SET ROLE account_recovery_owner'),denied);
  await assert.rejects(scoped(app,d,PUT_SQL,[d,crypto.randomUUID(),Buffer.alloc(60),wrap.keyId,Buffer.alloc(5242881),'0'.repeat(64),true,true,'account-recovery-v1']),error=>error.code==='22023');
  assert.equal((await scoped(app,d,DELETE_SQL)).rows[0].removed,2,'only explicitly discarded recovery copies removed');
  assert.equal((await product.query('SELECT id FROM profiles WHERE id=$1',[d])).rowCount,1,'recovery discard preserves product profile');
  const failed=crypto.randomUUID();await product.query('INSERT INTO profiles(id) VALUES($1)',[failed]);
  await scoped(app,failed,'SELECT * FROM account_lifecycle.request_deletion($1)');
  await product.query("UPDATE profiles SET deletion_requested_at=now()-interval '31 days',deletion_due_at=now()-interval '1 day' WHERE id=$1",[failed]);
  const checkpointBefore=(await worker.query('SELECT * FROM account_lifecycle.journal_checkpoint(false)')).rows[0];
  const failedJournal={inspect:async()=>({...checkpointBefore,sequence:Number(checkpointBefore.sequence)}),append:async()=>{throw Error('synthetic unavailable copy');}};
  await assert.rejects(createAccountLifecycleWorker({pool:worker,enabled:true,journal:failedJournal,applyAuthDeletion:async()=>assert.fail('journal failure cannot reach auth')})(),/unavailable copy/);
  assert.equal((await product.query('SELECT 1 FROM account_lifecycle.tombstones WHERE profile_id=$1',[failed])).rowCount,0,'journal failure rolled back product denial');
  assert.equal((await product.query('SELECT attempts FROM account_lifecycle.requests WHERE profile_id=$1',[failed])).rows[0].attempts,0);
  await assert.rejects(product.query('UPDATE profiles SET deletion_requested_at=null,deletion_due_at=null WHERE id=$1',[failed]),error=>error.code==='55000','active journal grace boundary cannot be undone by legacy update');
  await assert.rejects(app.query('SELECT account_lifecycle.journal_checkpoint(false)'),denied);
  await assert.rejects(app.query("SELECT account_lifecycle.advance_journal(repeat('a',64),0,repeat('b',64),repeat('c',64))"),denied);
  if(process.env.LIFECYCLE_JOURNAL_AGE_TEST_BIN){
    const execFile=require('node:util').promisify(require('node:child_process').execFile),fsp=require('node:fs/promises');
    const directory=await fsp.mkdtemp(path.join(require('node:os').tmpdir(),'pp-journal-pg-'));
    try{
      const binary=process.env.LIFECYCLE_JOURNAL_AGE_TEST_BIN,identity=path.join(directory,'identity'),recipients=path.join(directory,'recipients');
      await execFile(path.join(path.dirname(binary),'age-keygen'),['-o',identity]);
      await fsp.writeFile(recipients,(await execFile(path.join(path.dirname(binary),'age-keygen'),['-y',identity])).stdout,{mode:0o600});
      const options={roots:[path.join(directory,'a'),path.join(directory,'b')],checkpointRoot:path.join(directory,'checkpoint'),journalId:crypto.randomBytes(32).toString('hex'),signingKey:crypto.randomBytes(32).toString('base64'),recipientsFile:recipients,ageBinary:binary};
      await require('../src/account_lifecycle_journal').initializeJournal(options);
      await product.query('UPDATE account_lifecycle.control SET worker_enabled=false,journal_id=null,journal_sequence=0,journal_head=null');
      const env={PATH:process.env.PATH,NODE_ENV:'test',DB_SSL:'false',ACCOUNT_LIFECYCLE_JOURNAL_A:options.roots[0],ACCOUNT_LIFECYCLE_JOURNAL_B:options.roots[1],ACCOUNT_LIFECYCLE_CHECKPOINT_ROOT:options.checkpointRoot,ACCOUNT_LIFECYCLE_JOURNAL_ID:options.journalId,ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY:options.signingKey,ACCOUNT_LIFECYCLE_JOURNAL_RECIPIENTS_FILE:recipients,ACCOUNT_LIFECYCLE_JOURNAL_AGE_BINARY:binary,LIFECYCLE_JOURNAL_EXPECTED_CHECKPOINT_FILE:path.join(options.checkpointRoot,'latest-checkpoint.json'),LIFECYCLE_JOURNAL_RECOVERY_IDENTITY_FILE:identity,LIFECYCLE_REPLAY_PRODUCT_DATABASE_URL:worker.options.connectionString,LIFECYCLE_REPLAY_AUTH_DATABASE_URL:authWorker.options.connectionString,LIFECYCLE_REPLAY_CONTROL_DATABASE_URL:productUrl};
      for(let pass=0;pass<2;pass++){
        const result=JSON.parse((await execFile(process.execPath,[path.join(ROOT,'db/scripts/lifecycle_journal.js'),'--reconcile','--quiesced'],{env,timeout:30000})).stdout);
        assert.equal(result.status,'reconciled_keep_services_fenced');assert.ok(result.checkpoint.sequence>=3);if(pass===1)assert.equal(result.journaled_existing_records,0,'repeat operator replay does not append duplicate history');
      }
      assert.equal((await product.query('SELECT id FROM transactions WHERE id=$1',[financial])).rowCount,1);
      console.log('PASS: real age journal operator bootstrap/replay with separate control/limited function logins, all pre-existing DB tombstones journaled before checkpoint install, repeat recovery and financial history preserved');
    }finally{await fsp.rm(directory,{recursive:true,force:true});}
  }
  console.log('PASS: durable two-database deletion ledger, exact UUID preservation, 30-day grace/cancel race, one-worker leases, bounded retries, auth/session revocation, immutable soft tombstones, replay fencing, no financial/profile deletion, non-owner role denials, legacy cron safety and bounded account-recovery escrow/rotation');
 }finally{await Promise.all(pools.map(pool=>pool.end()));}
}
if(require.main===module)main().catch(error=>{console.error('Synthetic account lifecycle fixture failed',error.stack);process.exitCode=1;});
module.exports={config};
