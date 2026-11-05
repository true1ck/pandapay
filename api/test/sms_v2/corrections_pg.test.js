'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {submitCorrection,correctionStatusSince}=require('../../src/sms_v2/corrections_route');
const url=process.env.SMS_V2_TEST_DATABASE_URL;
test('real Postgres correction retry is idempotent, private without consent and owner scoped',{skip:!url},async()=>{
 const {Pool}=require('pg');
 const pool=new Pool({connectionString:url});
 const p=crypto.randomUUID(),other=crypto.randomUUID();
 async function withUser(id,operation){
  const client=await pool.connect();
  try{
   await client.query('BEGIN');
   await client.query('SET LOCAL ROLE app_user');
   await client.query("SELECT set_config('app.user_id',$1,true)",[id]);
   const result=await operation(client);
   await client.query('COMMIT');
   return result;
  }catch(error){await client.query('ROLLBACK');throw error;}
  finally{client.release();}
 }
 try{
  await pool.query('INSERT INTO profiles(id) VALUES($1),($2)',[p,other]);
  const body={sourceKey:'sms:synthetic:missing',factIds:[],correctionKind:'missing',corrected:{privateAmount:12345},
   redactedTemplate:'Private original values must be discarded',
   trace:{appVersion:'1',engineVersion:'2',bundleVersion:0,ruleId:null,ruleVersion:null,stage:'gate'}};
  const first=await withUser(p,client=>submitCorrection(client,p,body));
  const second=await withUser(p,client=>submitCorrection(client,p,body));
  assert.equal(first.caseId,second.caseId);
  const row=(await pool.query('SELECT corrected,redacted_template,shared_learning_eligible FROM sms_v2_correction_cases WHERE case_id=$1',[first.caseId])).rows[0];
  assert.deepEqual(row.corrected,{});
  assert.equal(row.redacted_template,null);
  assert.equal(row.shared_learning_eligible,false);
  const mine=await correctionStatusSince(withUser,p,null);
  const theirs=await correctionStatusSince(withUser,other,null);
  assert.equal(mine.items[0].caseId,first.caseId);
  assert.equal(theirs.items.length,0);
 }finally{
  await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])',[[p,other]]);
  await pool.end();
 }
});

test('latest consent, withdrawal, regrant and concurrent admission erase shared evidence',{skip:!url},async()=>{
 const {Pool}=require('pg');
 const pool=new Pool({connectionString:url});
 const profile=crypto.randomUUID();
 const grant=async(value,at)=>pool.query(
  "INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning','sms-shared-learning-v3',$2,$3)",[profile,value,at]);
 const skeleton='Rs.<AMT> spent';
 const body=sourceKey=>({sourceKey,factIds:[],correctionKind:'missing',corrected:{category:'dining',_template:{
  senderBrand:'HDFCBK',hash:crypto.createHash('sha256').update('HDFCBK\n'+skeleton).digest('hex'),
  observedAt:'2026-11-01T12:00:00Z'}},redactedTemplate:skeleton,
  trace:{appVersion:'1',engineVersion:'2',bundleVersion:0,ruleId:null,ruleVersion:null,stage:'gate'}});
 async function transaction(){
  const client=await pool.connect();
  await client.query('BEGIN');
  await client.query('SET LOCAL ROLE app_user');
  await client.query("SELECT set_config('app.user_id',$1,true)",[profile]);
  return client;
 }
 try{
  await pool.query('INSERT INTO profiles(id) VALUES($1)',[profile]);
  await grant(true,'2026-11-01T00:00:00Z');
  let client=await transaction();
  const first=await submitCorrection(client,profile,body('sms:consent:first'),{sharedLearningEligible:true});
  await client.query('COMMIT');client.release();
  let row=(await pool.query('SELECT * FROM sms_v2_correction_cases WHERE case_id=$1',[first.caseId])).rows[0];
  assert.equal(row.shared_learning_eligible,true);
  await grant(false,'2026-11-02T00:00:00Z');
  row=(await pool.query('SELECT * FROM sms_v2_correction_cases WHERE case_id=$1',[first.caseId])).rows[0];
  assert.equal(row.redacted_template,null);
  assert.deepEqual(row.corrected,{});
  assert.equal(row.shared_learning_eligible,false);

  await grant(true,'2026-11-03T00:00:00Z');
  // Regrant does not restore an erased contribution.
  assert.equal((await pool.query('SELECT redacted_template FROM sms_v2_correction_cases WHERE case_id=$1',[first.caseId])).rows[0].redacted_template,null);
  client=await transaction();
  const second=await submitCorrection(client,profile,body('sms:consent:second'),{sharedLearningEligible:true});
  await client.query('COMMIT');client.release();
  // A backdated opt-out must not override the latest purpose-specific event.
  await grant(false,'2025-11-01T00:00:00Z');
  assert.equal((await pool.query('SELECT shared_learning_eligible FROM sms_v2_correction_cases WHERE case_id=$1',[second.caseId])).rows[0].shared_learning_eligible,true);

  client=await transaction();
  const concurrent=await submitCorrection(client,profile,body('sms:consent:concurrent'),{sharedLearningEligible:true});
  const revoke=grant(false,'2026-11-04T00:00:00Z');
  const state=await Promise.race([revoke.then(()=>'revoked'),new Promise(resolve=>setTimeout(()=>resolve('waiting'),30))]);
  assert.equal(state,'waiting');
  await client.query('COMMIT');client.release();
  await revoke;
  row=(await pool.query('SELECT corrected,redacted_template FROM sms_v2_correction_cases WHERE case_id=$1',[concurrent.caseId])).rows[0];
  assert.deepEqual(row.corrected,{});
  assert.equal(row.redacted_template,null);
 }finally{
  await pool.query('DELETE FROM profiles WHERE id=$1',[profile]);
  await pool.end();
 }
});
