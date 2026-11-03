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
