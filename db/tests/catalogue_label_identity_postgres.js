#!/usr/bin/env node
'use strict';
// Owns a disposable loopback cluster; never reads .env or DATABASE_URL.
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net');
const {spawnSync}=require('node:child_process');
const {randomUUID}=require('node:crypto');
const {Client}=require('../../api/node_modules/pg');
const {runProductMigrations}=require('../scripts/product_migrate');
const {normalizeCatalogueLabel,labelIdentitySql,RULE_KEYS}=require('../../api/src/catalogue_label_identity');
const {reviewDataCleanup}=require('../scripts/review_data_cleanup');
const ROOT=path.resolve(__dirname,'../..');
const MIGRATION='20261025074636_catalogue_label_identity_v1.sql';
function run(command,args,options={}){const r=spawnSync(command,args,{encoding:'utf8',timeout:60000,...options});if(r.status!==0)throw Error(`${path.basename(command)} synthetic fixture failed: ${String(r.stderr||'').slice(-1800)}`);return r.stdout;}
async function port(){return await new Promise((resolve,reject)=>{const s=net.createServer();s.once('error',reject);s.listen(0,'127.0.0.1',()=>{const n=s.address().port;s.close(()=>resolve(n));});});}
async function main(){
 const work=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-catalogue-fixture-')),data=path.join(work,'data');
 const env={PATH:process.env.PATH||'',HOME:process.env.HOME||'',TMPDIR:work,LC_ALL:'C',LANG:'C'};
 const p=await port(),base=`postgresql://fixture_owner@127.0.0.1:${p}`,dbDir=path.join(work,'db');
 fs.mkdirSync(path.join(dbDir,'supabase/migrations'),{recursive:true});
 const migration=fs.readFileSync(path.join(ROOT,'db/supabase/migrations',MIGRATION),'utf8');
 fs.writeFileSync(path.join(dbDir,'supabase/migrations',MIGRATION),migration);
 let started=false,c,other,restored;
 try{
  run('initdb',['-D',data,'-A','trust','--no-locale','--encoding=UTF8','-U','fixture_owner'],{env});
  run('pg_ctl',['-D',data,'-l',path.join(work,'postgres.log'),'-o',`-p ${p} -h 127.0.0.1 -k ${work}`,'start'],{env});started=true;
  c=new Client({connectionString:base+'/postgres',ssl:false});await c.connect();
  const files=fs.readdirSync(path.join(ROOT,'db/supabase/migrations')).filter(n=>/^00(?:0[1-9]|1[01])_/.test(n)).sort();
  assert.equal(files.length,11);
  for(const file of files)await c.query(fs.readFileSync(path.join(ROOT,'db/supabase/migrations',file),'utf8'));
  await c.query(fs.readFileSync(path.join(ROOT,'db/supabase/migrations/0015_card_products_rls_fix.sql'),'utf8'));
  for(const [table,keys] of Object.entries(RULE_KEYS))await c.query(`CREATE UNIQUE INDEX uq_${table==='cap_rules'?'cap_rules':'card_benefits'}_semantic_identity ON ${table} (${keys.join(',')}) NULLS NOT DISTINCT`);
  const issuer=randomUUID(),card=randomUUID(),card2=randomUUID(),category=randomUUID(),reward=randomUUID();
  await c.query("INSERT INTO issuers(id,slug,name) VALUES($1,'fixture','Fixture')",[issuer]);
  await c.query("INSERT INTO card_products(id,issuer_id,slug,name,network,status,verified_at) VALUES($1,$3,'fixture-a','Fixture A','visa','published',now()),($2,$3,'fixture-b','Fixture B','visa','draft',null)",[card,card2,issuer]);
  await c.query("INSERT INTO spend_categories(id,slug,name) VALUES($1,'fixture','Fixture')",[category]);
  await c.query("INSERT INTO reward_rules(id,card_product_id,unit,rate) VALUES($1,$2,'flat_points',1)",[reward,card]);
  async function insert(table,values,client=c){const cols=Object.keys(values);return (await client.query(`INSERT INTO ${table} (${cols.join(',')}) VALUES (${cols.map((_,i)=>'$'+(i+1)).join(',')}) RETURNING id`,cols.map(k=>values[k]))).rows[0].id;}
  const cap={card_product_id:card,label:' Dining\t CAP ',measure:'reward_value',period:'calendar_month',cap_value:100,post_cap_rate:0};
  const benefit={card_product_id:card,kind:'lounge_domestic',label:' Lounge\t Pass '};
  const capId=await insert('cap_rules',cap),benefitId=await insert('card_benefits',benefit);
  const profile=randomUUID(),userCard=randomUUID();
  await c.query('INSERT INTO profiles(id) VALUES($1)',[profile]);
  await c.query('INSERT INTO user_cards(id,profile_id,card_product_id) VALUES($1,$2,$3)',[userCard,profile,card]);
  await c.query("INSERT INTO cap_states(profile_id,user_card_id,cap_rule_id,period_start,period_end,consumed,cap_value_snapshot) VALUES($1,$2,$3,'2026-10-01','2026-10-31',23.45,100)",[profile,userCard,capId]);
  await c.query("INSERT INTO lounge_usage(profile_id,user_card_id,benefit_id,used_on) VALUES($1,$2,$3,'2026-10-20')",[profile,userCard,benefitId]);
  const tables=['cap_rules','card_benefits','cap_states','lounge_usage','profiles','user_cards','card_products'];
  async function snapshot(client=c){const out={};for(const table of tables)out[table]=(await client.query(`SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) rows FROM ${table} t`)).rows[0].rows;return out;}
  for(const [table,record,label] of [['cap_rules',cap,'dining cap'],['card_benefits',benefit,'lounge pass']]){
   const duplicate=await insert(table,{...record,label}),before=await snapshot();
   const review=await reviewDataCleanup(c,{scope:'product',restoredCopy:true});
   const name=table==='cap_rules'?'cap_rule_normalized_identity_v1':'benefit_normalized_identity_v1';
   const identity=review.checks.find(check=>check.name===name);
   assert.equal(identity.status,'completed');assert.equal(identity.duplicate_groups,'1');assert.equal(identity.extra_rows,'1');
   await assert.rejects(runProductMigrations(c,{dbDir}),e=>e.cause?.code==='23514' && e.cause.message==='Normalized catalogue collisions require reviewed ID mapping; no rows changed');
   assert.deepEqual(await snapshot(),before);
   assert.equal((await c.query("SELECT count(*)::int n FROM pg_indexes WHERE indexname LIKE '%label_identity_v1'")).rows[0].n,0);
   assert.equal((await c.query('SELECT count(*)::int n FROM schema_migrations')).rows[0].n,0);
   await c.query(`DELETE FROM ${table} WHERE id=$1`,[duplicate]); // synthetic fixture cleanup only
  }
  await c.query('ALTER TABLE cap_rules ADD COLUMN unreviewed text');
  await assert.rejects(runProductMigrations(c,{dbDir}),e=>e.cause?.code==='55000');
  await c.query('ALTER TABLE cap_rules DROP COLUMN unreviewed');
  other=new Client({connectionString:base+'/postgres',ssl:false});await other.connect();
  await other.query('BEGIN');await other.query('LOCK TABLE cap_rules IN ROW EXCLUSIVE MODE');
  await assert.rejects(runProductMigrations(c,{dbDir}),e=>e.cause?.code==='55P03');
  await other.query('ROLLBACK');
  const before=await snapshot();
  await runProductMigrations(c,{dbDir});assert.deepEqual(await snapshot(),before,'migration must preserve every row and original label');
  await runProductMigrations(c,{dbDir});assert.deepEqual(await snapshot(),before,'checksummed rerun must skip');
  const reviewed=await reviewDataCleanup(c,{scope:'product',restoredCopy:true});
  for(const name of ['cap_rule_normalized_identity_v1','benefit_normalized_identity_v1']){
   const check=reviewed.checks.find(value=>value.name===name);assert.equal(check.status,'completed');assert.equal(check.extra_rows,'0');
  }
  assert.equal((await c.query('SELECT count(*)::int n FROM schema_migrations')).rows[0].n,1);
  await c.query('BEGIN');await assert.rejects(c.query(migration),e=>e.code==='55000');await c.query('ROLLBACK');
  for(const value of [null,'',' \t\n\v\f\r ','  Dining\t\nCAP  ','Ä A\u00a0B','İ É é','A-B']){
   const sql=labelIdentitySql('t');const out=await c.query(`SELECT ${sql} value FROM (VALUES($1::text)) t(label)`,[value]);
   assert.equal(out.rows[0].value,normalizeCatalogueLabel(value));
  }
  for(const [table,record,label,index] of [
   ['cap_rules',cap,'dining cap','uq_cap_rules_label_identity_v1'],
   ['card_benefits',benefit,'lounge pass','uq_card_benefits_label_identity_v1']]){
   await assert.rejects(insert(table,{...record,label}),e=>e.code==='23505' && e.constraint===index);
   for(const unicode of ['Ä','ä','a\u00a0b','a b','é','e'])await insert(table,{...record,label:'Unicode '+unicode});
  }
  const capChanges={card_product_id:card2,reward_rule_id:reward,category_id:category,benefit_kind:'other',measure:'txn_count',period:'annual',cap_value:200,post_cap_unit:'flat_points',post_cap_rate:1,resets_on_day:2};
  const benefitChanges={card_product_id:card2,kind:'lounge_international',description:'',quota_count:1,quota_period:'annual',network_program:'',value_estimate_inr:1,conditions:{different:true}};
  for(const [table,record,changes] of [['cap_rules',cap,capChanges],['card_benefits',benefit,benefitChanges]]){
   for(const [key,value] of Object.entries(changes))await insert(table,{...record,[key]:value});
  }
  const updateId=await insert('cap_rules',{...cap,label:'Update fixture'}),beforeUpdate=await snapshot();
  await c.query('BEGIN');await assert.rejects(c.query('UPDATE cap_rules SET label=$1 WHERE id=$2',['dining cap',updateId]),e=>e.code==='23505');await c.query('ROLLBACK');
  assert.deepEqual(await snapshot(),beforeUpdate,'failed update must not alter rule or dependent history');
  // A second connection must serialize a competing identity, not race past it.
  await c.query('BEGIN');await insert('cap_rules',{...cap,label:'Race\tcap'});
  const blocked=insert('cap_rules',{...cap,label:' race cap '},other).then(()=>null,e=>e);
  await c.query('COMMIT');const race=await blocked;assert.equal(race.code,'23505');
  // Actual 0015 policies under a non-owner role: public sees published parents
  // and children; the fixture admin predicate still uses the real admin table.
  await c.query('CREATE ROLE catalogue_fixture_runtime NOLOGIN; GRANT USAGE ON SCHEMA public,pandapay TO catalogue_fixture_runtime; GRANT SELECT ON card_products,cap_rules,card_benefits TO catalogue_fixture_runtime');
  await c.query('BEGIN');await c.query('SET LOCAL ROLE catalogue_fixture_runtime');
  assert.equal((await c.query('SELECT count(*)::int n FROM card_products')).rows[0].n,1);
  for(const table of ['cap_rules','card_benefits'])assert.equal((await c.query(`SELECT count(*)::int n FROM ${table} WHERE card_product_id=$1`,[card2])).rows[0].n,0);
  await c.query('ROLLBACK');
  await c.query("INSERT INTO admin_users(id,email) VALUES($1,'synthetic-admin@example.invalid')",[profile]);
  await c.query('BEGIN');await c.query('SET LOCAL ROLE catalogue_fixture_runtime');
  await c.query("SELECT set_config('app.user_id',$1,true)",[profile]);
  assert.equal((await c.query('SELECT count(*)::int n FROM card_products')).rows[0].n,2);
  for(const table of ['cap_rules','card_benefits'])assert.equal((await c.query(`SELECT count(*)::int n FROM ${table} WHERE card_product_id=$1`,[card2])).rows[0].n,1);
  await c.query('ROLLBACK');
  const exportBefore=await snapshot();
  const dump=path.join(work,'catalogue.dump');run('pg_dump',['--format=custom','--file',dump,base+'/postgres'],{env});
  await c.query('CREATE DATABASE catalogue_restored');run('pg_restore',['--exit-on-error','--dbname',base+'/catalogue_restored',dump],{env});
  restored=new Client({connectionString:base+'/catalogue_restored',ssl:false});await restored.connect();
  assert.deepEqual(await snapshot(restored),exportBefore,'provider-style dump/restore must preserve IDs and history');
  await assert.rejects(insert('cap_rules',{...cap,label:' DINING CAP '},restored),e=>e.code==='23505');
  await assert.rejects(insert('card_benefits',{...benefit,label:' LOUNGE PASS '},restored),e=>e.code==='23505');
  await runProductMigrations(restored,{dbDir});assert.deepEqual(await snapshot(restored),exportBefore);
  console.log('PASS: catalogue identity PostgreSQL fixture; collision/schema refusal, complete rollback, SQL/JS parity, NULL identity, all discriminators, Unicode, concurrent writers, update rollback, actual 0015 non-owner RLS, checksummed rerun and full dump/restore preservation');
 }finally{
  for(const client of [restored,other,c])if(client)await client.end().catch(()=>{});
  if(started)try{run('pg_ctl',['-D',data,'-m','immediate','stop'],{env});}catch{}
  fs.rmSync(work,{recursive:true,force:true});
 }
}
if(require.main===module)main().catch(e=>{process.stderr.write(`Catalogue synthetic fixture failed: ${e.message}\n`);process.exitCode=1;});
