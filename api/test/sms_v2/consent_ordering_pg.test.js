'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const url = process.env.SMS_V2_TEST_DATABASE_URL;
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';
const deferred = () => { let resolve; const promise = new Promise(r => { resolve=r; }); return { promise, resolve }; };
let pool;
const profiles=[];
async function own(profile, operation, { locked, release, pid }={}) {
 const client=await pool.connect();
 try {
  await client.query('BEGIN'); await client.query('SET LOCAL ROLE app_user');
  await client.query("SELECT set_config('app.user_id',$1,true)",[profile]);
  if(pid) pid.resolve((await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid);
  let captured=false;
  const wrapped={query:async(sql,...args)=>{
   const result=await client.query(sql,...args);
   if(!captured && locked && sql.includes('pg_advisory_xact_lock(hashtextextended')) {
    captured=true; locked.resolve(); await release.promise;
   }
   return result;
  }};
  const result=await operation(wrapped);
  await client.query('COMMIT'); return result;
 } catch(error) { await client.query('ROLLBACK'); throw error; }
 finally { client.release(); }
}
async function profile() {
 const id=crypto.randomUUID(); await pool.query('INSERT INTO profiles(id) VALUES($1)',[id]); profiles.push(id);
 await consent(id,true); return id;
}
function consent(profile,granted,options={}) {
 // Exercise the actual route, including its common lock and old/v2 purge work.
 const source=fs.readFileSync(require.resolve('../../src/index.js'),'utf8');
 const start=source.indexOf("app.post('/consents',"); const end=source.indexOf('\n});',start)+5;
 let handler;
 new Function('app','requireAuth','withUserClient','CONSENT_PURPOSES','safeErrorCode',source.slice(start,end))(
  {post:(_path,_auth,fn)=>{handler=fn;}},()=>{},(p,fn)=>own(p,fn,options),['sms_shared_learning'],e=>e?.code||'unknown');
 const res={code:null,body:null,status(n){this.code=n;return this;},json(body){this.body=body;return this;}};
 return handler({userId:profile,body:{purpose:'sms_shared_learning',granted,policyVersion:'sms-shared-learning-v2',sourceScreen:'synthetic-test'}},res).then(()=>res);
}
const template=()=>({templateHash:crypto.randomBytes(32).toString('hex'),senderBrand:'TESTBK',redactedBody:'<AMT> paid to <PARTY>.',observedAt:new Date().toISOString()});
const submit=(profile,item,options)=>own(profile,c=>c.query('SELECT pandapay.sms_v2_submit_templates($1::jsonb,true)',[JSON.stringify([item])]),options);
async function waits(pid) {
 const until=Date.now()+3000;
 while(Date.now()<until) {
  const result=await pool.query("SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='advisory' AND NOT granted",[pid]);
  if(result.rows.length)return;
 }
 assert.fail('operation did not wait on the common consent advisory lock');
}
async function assertErased(profile,item) {
 assert.equal((await pool.query('SELECT count(*)::int AS n FROM sms_v2_template_submitters WHERE profile_id=$1',[profile])).rows[0].n,0);
 assert.equal((await pool.query('SELECT count(*)::int AS n FROM sms_v2_unknown_templates WHERE template_hash=$1',[item.templateHash])).rows[0].n,0);
 assert.equal((await pool.query("SELECT count(*)::int AS n FROM sms_v2_correction_cases WHERE profile_id=$1 AND (redacted_template IS NOT NULL OR corrected<>'{}'::jsonb OR shared_learning_eligible)",[profile])).rows[0].n,0);
}
test.before(async()=>{if(skip)return;pool=new(require('pg').Pool)({connectionString:url});});
test.after(async()=>{if(!pool)return;await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])',[profiles]);await pool.end();});

test('real consent endpoint lock blocks template admission before its withdrawal row is inserted',{skip},async()=>{
 const p=await profile();const item=template();
 const correction={sourceKey:'sms:synthetic:consent-ordering',factIds:[],correctionKind:'missing',corrected:{category:'food',_template:{
  senderBrand:item.senderBrand,hash:crypto.createHash('sha256').update(item.senderBrand+'\n'+item.redactedBody).digest('hex'),observedAt:item.observedAt}},
  redactedTemplate:item.redactedBody,trace:{appVersion:'1',engineVersion:'2',bundleVersion:0,ruleId:null,ruleVersion:null,stage:'gate'}};
 await own(p,c=>require('../../src/sms_v2/corrections_route').submitCorrection(c,p,correction,{sharedLearningEligible:true}));
 const locked=deferred();const release=deferred();const pid=deferred();
 const revoked=consent(p,false,{locked,release});await locked.promise;
 const admission=submit(p,item,{pid}).then(()=>({ok:true}),error=>({error}));
 try {await waits(await pid.promise);} finally {release.resolve();}
 assert.equal((await revoked).code,201);
 assert.equal((await admission).error?.code,'42501');
 await assertErased(p,item);
 assert.equal((await consent(p,true)).code,201);
 await submit(p,item); // New grant allows a fresh contribution; old evidence was erased.
 assert.equal((await consent(p,false)).code,201);
 await assertErased(p,item);
});

test('a template contribution ordered before the real revoke endpoint is purged after it commits',{skip},async()=>{
 const p=await profile();const item=template();const gate=deferred();const uploaded=deferred();const pid=deferred();
 const admission=own(p,async c=>{
  await c.query('SELECT pandapay.sms_v2_submit_templates($1::jsonb,true)',[JSON.stringify([item])]);
  uploaded.resolve();await gate.promise;
 });
 await uploaded.promise;
 const revoked=consent(p,false,{pid});
 try {await waits(await pid.promise);} finally {gate.resolve();}
 await admission;assert.equal((await revoked).code,201);
 await assertErased(p,item);
});

test('template withdrawal follows the latest consent event for insert and update',{skip},async()=>{
 const p=await profile();const item=template();await submit(p,item);
 // A historical opt-out cannot erase a currently consented contribution.
 await pool.query("INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning','synthetic',false,'2000-01-01')",[p]);
 assert.equal((await pool.query('SELECT count(*)::int AS n FROM sms_v2_template_submitters WHERE profile_id=$1',[p])).rows[0].n,1);
 await pool.query("UPDATE user_consents SET granted=false WHERE profile_id=$1 AND granted=true",[p]);
 await assertErased(p,item);
});


test('withdrawal drains admissions holding the old lock during function rollout',{skip},async()=>{
 const p=await profile();const item=template();const legacy=await pool.connect();const pid=deferred();
 let revoked;
 try {
  await legacy.query('BEGIN');
  await legacy.query("SELECT pg_advisory_xact_lock(hashtext($1))",['sms-shared-learning-consent:'+p]);
  // The old function held this lock while creating these rows. Rehearse its
  // already-running transaction without replacing any production function.
  await legacy.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,$2,$3,'held')",[item.templateHash,item.senderBrand,item.redactedBody]);
  await legacy.query('INSERT INTO sms_v2_template_submitters(template_hash,profile_id) VALUES($1,$2)',[item.templateHash,p]);
  revoked=consent(p,false,{pid});
  try {await waits(await pid.promise);} finally {await legacy.query('COMMIT');}
  assert.equal((await revoked).code,201);
  await assertErased(p,item);
 } finally {await legacy.query('ROLLBACK');legacy.release();if(revoked)await revoked;}
});
