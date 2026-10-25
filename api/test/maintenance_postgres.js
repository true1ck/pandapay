'use strict';
// Fresh loopback database only. Synthetic rows, independent non-owner LOGINs.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {Client}=require('pg');
const {createMaintenanceRunner,checkMaintenanceIdentity}=require('../src/maintenance/runner');
async function main(){
 const raw=process.env.MAINTENANCE_TEST_URL;if(!raw)throw Error('MAINTENANCE_TEST_URL required');
 const u=new URL(raw);if(!['postgres:','postgresql:'].includes(u.protocol)||!['127.0.0.1','localhost','[::1]'].includes(u.hostname)||u.pathname!=='/maintenance_test'||u.search||u.hash)throw Error('Fresh loopback maintenance_test required');
 const options={connectionString:raw,ssl:false,connectionTimeoutMillis:3000},admin=new Client(options);await admin.connect();const clients=[];
 try{
  assert.equal((await admin.query("SELECT count(*)::integer AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('information_schema','pg_catalog','pg_toast') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p','v','m','S','f')")).rows[0].n,0);
  const operator=(await admin.query('SELECT current_user AS name')).rows[0].name,q=x=>'"'+x.replaceAll('"','""')+'"';
  await admin.query(`CREATE TYPE public.record_confidence AS ENUM('unverified','low','medium','high','operator_verified');
   CREATE TABLE public.profiles(id uuid PRIMARY KEY,note text);
   CREATE TABLE public.transactions(id uuid PRIMARY KEY,amount numeric);
   CREATE TABLE public.user_cards(id uuid PRIMARY KEY);
   CREATE TABLE public.merchants(id uuid PRIMARY KEY,operator_locked boolean NOT NULL DEFAULT false,distinct_device_count integer,confirmation_count integer,confidence_score numeric,confidence public.record_confidence,is_published boolean,last_confirmed_on date,updated_at timestamptz);
   CREATE TABLE public.merchant_contributions(merchant_id uuid,device_hash text,is_counted boolean,submitted_on date);
   CREATE TABLE public.inbound_emails(id uuid PRIMARY KEY,purge_after timestamptz,received_at timestamptz,policy_keyword_hit boolean NOT NULL,body_text text);
   CREATE TABLE public.effective_rate_summary(card_product_id uuid,category_id uuid,period_month date,distinct_devices integer,published_rate numeric,divergence_pct numeric,observed_rate_p50 numeric,alert_raised_at timestamptz,is_divergent boolean);
   CREATE TABLE public.policy_change_alerts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),card_product_id uuid,field_path text,field_label text,current_value jsonb,proposed_value jsonb,signal_count integer,distinct_signal_kinds integer,corroboration_score numeric,state text DEFAULT 'open',last_signal_at timestamptz);
   CREATE TABLE public.policy_alert_evidence(alert_id uuid,signal text,rate_summary_key jsonb,excerpt text,weight numeric);
   INSERT INTO public.profiles VALUES('11111111-1111-4111-8111-111111111111','original identity');
   INSERT INTO public.transactions VALUES('22222222-2222-4222-8222-222222222222',123.45);
   INSERT INTO public.merchants(id) VALUES('33333333-3333-4333-8333-333333333333');
   INSERT INTO public.merchant_contributions VALUES('33333333-3333-4333-8333-333333333333','device-a',true,current_date),('33333333-3333-4333-8333-333333333333','device-b',true,current_date);
   INSERT INTO public.inbound_emails VALUES('44444444-4444-4444-8444-444444444444',now()-interval '1 day',now()-interval '31 days',false,'expired body'),('55555555-5555-4555-8555-555555555555',now()-interval '1 day',now()-interval '31 days',true,'policy retained');
   INSERT INTO public.effective_rate_summary VALUES('66666666-6666-4666-8666-666666666666',NULL,current_date,3,5,0.2,4,NULL,false);`);
  for(const table of ['merchants','merchant_contributions','inbound_emails','effective_rate_summary','policy_change_alerts','policy_alert_evidence'])await admin.query(`ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY; ALTER TABLE public.${table} FORCE ROW LEVEL SECURITY; CREATE POLICY fixture_operator ON public.${table} TO ${q(operator)} USING(true) WITH CHECK(true)`);
  const migration=fs.readFileSync(path.join(__dirname,'../../db/supabase/migrations/20261024111632_bounded_operational_maintenance.sql'),'utf8');
  await admin.query('BEGIN');try{await admin.query(migration);await admin.query('COMMIT');}catch(e){await admin.query('ROLLBACK');throw e;}
  const suffix=crypto.randomBytes(5).toString('hex');
  async function login(role){const name='maint_fixture_'+suffix+'_'+clients.length;await admin.query(`CREATE ROLE ${q(name)} LOGIN PASSWORD 'synthetic-fixture' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;GRANT ${q(role)} TO ${q(name)}`);const c=new Client({...options,user:name,password:'synthetic-fixture',connectionString:undefined,host:u.hostname,port:Number(u.port||5432),database:'maintenance_test'});await c.connect();clients.push(c);c.fixtureOptions={...options,connectionString:undefined,host:u.hostname,port:Number(u.port||5432),database:'maintenance_test',user:name,password:'synthetic-fixture'};return c;}
  const worker=await login('pandapay_maintenance'),reader=await login('pandapay_maintenance_reader'),auth=await login('pandapay_auth_retention_coordinator');
  await checkMaintenanceIdentity(worker);
  await require('../../db/scripts/maintenance_alert_delivery').checkReaderIdentity(reader);
  await assert.rejects(require('../../db/scripts/maintenance_alert_delivery').checkReaderIdentity(worker));
  assert.equal((await worker.query("SELECT * FROM maintenance.claim_job('merchant_confidence')")).rows.length,0);
  await assert.rejects(worker.query('SELECT * FROM maintenance.jobs'),{code:'42501'});
  await assert.rejects(worker.query('SELECT * FROM public.transactions'),{code:'42501'});
  await assert.rejects(worker.query("SELECT * FROM maintenance.claim_job('auth_retention')"));
  await assert.rejects(worker.query("SELECT maintenance.acknowledge_notification('merchant_confidence','job_failed',1)"),{code:'42501'});
  await admin.query(`GRANT maintenance_owner TO ${q(operator)} WITH INHERIT FALSE,SET TRUE`);
  async function control(sql){await admin.query('BEGIN');try{await admin.query('SET LOCAL ROLE maintenance_owner');await admin.query(sql);await admin.query('COMMIT');}catch(e){await admin.query('ROLLBACK');throw e;}}
  await assert.rejects(control("UPDATE maintenance.jobs SET enabled=true WHERE job='inbound_body_retention'"),{code:'23514'});
  await control("UPDATE maintenance.jobs SET enabled=true,retention_days=30,batch_size=1");
  const result=await createMaintenanceRunner({enabled:true,clientFactory:()=>new Client(worker.fixtureOptions)})();
  assert.equal(result.failed,0);assert.equal(result.processed,3);assert.equal(result.deferred,3);
  assert.equal((await admin.query('SELECT is_published FROM public.merchants')).rows[0].is_published,true);
  const bodies=(await admin.query('SELECT body_text FROM public.inbound_emails ORDER BY id')).rows;
  assert.equal(bodies[0].body_text,null);assert.equal(bodies[1].body_text,'policy retained');
  assert.equal((await admin.query('SELECT count(*)::integer AS n FROM public.policy_alert_evidence')).rows[0].n,1);
  assert.equal((await admin.query('SELECT sum(amount)::text AS total FROM public.transactions')).rows[0].total,'123.45');
  assert.equal((await admin.query('SELECT note FROM public.profiles')).rows[0].note,'original identity');
  await control("UPDATE maintenance.jobs SET next_run_at=now() WHERE job='merchant_confidence'");
  const old=(await worker.query("SELECT * FROM maintenance.claim_job('merchant_confidence')")).rows[0];
  assert.equal((await worker.query("SELECT * FROM maintenance.claim_job('merchant_confidence')")).rows.length,0);
  await control("UPDATE maintenance.jobs SET lease_until=now()-interval '1 second' WHERE job='merchant_confidence'");
  const current=(await worker.query("SELECT * FROM maintenance.claim_job('merchant_confidence')")).rows[0];
  assert.notEqual(old.lease_token,current.lease_token);
  await assert.rejects(worker.query("SELECT * FROM maintenance.run_batch('merchant_confidence',$1)",[old.lease_token]));
  const notices=(await reader.query('SELECT * FROM maintenance.read_notifications()')).rows;
  assert.equal(notices.length,1);assert.equal(notices[0].code,'lease_expired');
  assert.equal((await reader.query("SELECT maintenance.acknowledge_notification('merchant_confidence','lease_expired',$1) AS ok",[Number(notices[0].generation)+1])).rows[0].ok,false);
  assert.equal((await reader.query("SELECT maintenance.acknowledge_notification('merchant_confidence','lease_expired',$1) AS ok",[notices[0].generation])).rows[0].ok,true);
  const authLease=(await auth.query('SELECT * FROM maintenance.claim_auth_retention()')).rows[0];
  assert.ok(authLease);await assert.rejects(auth.query("SELECT * FROM maintenance.claim_job('merchant_confidence')"),{code:'42501'});
  assert.equal((await auth.query('SELECT maintenance.finish_external($1,2,false) AS ok',[authLease.lease_token])).rows[0].ok,true);
  await admin.query(`REVOKE maintenance_owner FROM ${q(operator)}`);
  console.log('PASS: bounded maintenance disabled defaults, narrow independent LOGINs/RLS, mailbox body-only policy, merchant/rate batches, durable leases/checkpoints, generation acknowledgements and separate auth coordinator; financial/identity rows preserved');
 }finally{for(const c of clients)await c.end();await admin.end();}
}
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1;});
module.exports={main};
