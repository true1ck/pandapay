'use strict';
// Explicitly named synthetic loopback database only. No ambient URLs or .env.
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const {Client}=require('../../api/node_modules/pg');
const {reviewDataCleanup}=require('../scripts/review_data_cleanup');
async function main(){
 const raw=process.env.DATA_CLEANUP_REVIEW_TEST_URL;if(!raw)throw new Error('DATA_CLEANUP_REVIEW_TEST_URL is required');const url=new URL(raw);
 if(!['postgres:','postgresql:'].includes(url.protocol)||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.pathname!=='/data_cleanup_review_test'||url.search||url.hash)throw new Error('A fresh loopback data_cleanup_review_test is required');
 const admin=new Client({connectionString:raw,ssl:false,connectionTimeoutMillis:3000});await admin.connect();let reader;
 try{
  const existing=await admin.query("SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_' AND c.relkind IN ('r','p','v','m','S','f')");assert.equal(existing.rows[0].count,0,'fixture refuses nonempty database');
  const marker='Synthetic_private_customer_'+crypto.randomBytes(8).toString('hex'),runtime='cleanup_reader_'+crypto.randomBytes(5).toString('hex');
  await admin.query(`CREATE TABLE issuers(id uuid PRIMARY KEY,name text);
   CREATE TABLE card_products(id uuid PRIMARY KEY,issuer_id uuid REFERENCES issuers(id),name text,network text,card_type text);
   CREATE TABLE cap_rules(id uuid PRIMARY KEY,card_product_id uuid,label text,cap_value numeric,conditions jsonb,created_at timestamptz);
   CREATE TABLE card_benefits(id uuid PRIMARY KEY,card_product_id uuid,label text,quota_count integer,conditions jsonb,created_at timestamptz);
   CREATE TABLE parser_patterns(id uuid PRIMARY KEY,issuer_id uuid,channel text,sender_pattern text,regex text,field_map jsonb,version integer,is_active boolean,sample_text text);
   CREATE TABLE parser_failures(id uuid PRIMARY KEY,channel text,sender_pattern text,redacted_shape text,occurrences integer);
   CREATE TABLE transactions(id uuid PRIMARY KEY,amount_inr numeric(12,2),note text);
   CREATE TABLE orphan_reference(issuer_id uuid);
   CREATE TABLE composite_parent(a integer,b integer,PRIMARY KEY(a,b));
   CREATE TABLE composite_child(a integer,b integer);
   INSERT INTO issuers VALUES('00000000-0000-4000-8000-000000000001',' Bank '),('00000000-0000-4000-8000-000000000002','bank');
   INSERT INTO card_products VALUES('00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000001',' Card  One ','visa','credit'),('00000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000001','card one','visa','credit');
   INSERT INTO cap_rules VALUES(gen_random_uuid(),'00000000-0000-4000-8000-000000000003',' Dining  cap ',100,'{}',now()),(gen_random_uuid(),'00000000-0000-4000-8000-000000000003','dining cap',100,'{}',now()),(gen_random_uuid(),'00000000-0000-4000-8000-000000000003','Dining cap',200,'{}',now());
   INSERT INTO card_benefits VALUES(gen_random_uuid(),'00000000-0000-4000-8000-000000000003',' Lounge ',2,'{}',now()),(gen_random_uuid(),'00000000-0000-4000-8000-000000000003','lounge',2,'{}',now()),(gen_random_uuid(),'00000000-0000-4000-8000-000000000003','lounge',4,'{}',now());
   INSERT INTO parser_patterns SELECT gen_random_uuid(),null,'sms','bank','regex-v1','{"amount":1}',1,true,'${marker}' FROM generate_series(1,2);
   INSERT INTO parser_patterns VALUES(gen_random_uuid(),null,'sms','bank','regex-v2','{"amount":1}',1,true,'${marker}');
   INSERT INTO parser_failures VALUES(gen_random_uuid(),'sms','bank','####',1),(gen_random_uuid(),'sms','bank','####',8);
   INSERT INTO transactions VALUES(gen_random_uuid(),25.00,'${marker}'),(gen_random_uuid(),75.00,'${marker}');
   INSERT INTO orphan_reference VALUES('00000000-0000-4000-8000-000000000099');
   ALTER TABLE orphan_reference ADD CONSTRAINT orphan_fixture FOREIGN KEY(issuer_id) REFERENCES issuers(id) NOT VALID;
   INSERT INTO composite_child VALUES(1,null);
   ALTER TABLE composite_child ADD CONSTRAINT composite_orphan_fixture FOREIGN KEY(a,b) REFERENCES composite_parent(a,b) MATCH FULL NOT VALID;
   CREATE INDEX transactions_amount_copy_a ON transactions(amount_inr);CREATE INDEX transactions_amount_copy_b ON transactions(amount_inr);
   ALTER TABLE transactions ADD CONSTRAINT transaction_amount_unique UNIQUE(amount_inr);`);
  const before=(await admin.query("SELECT count(*)::text AS rows,md5(string_agg(md5(row_to_json(t)::text),'' ORDER BY id)) AS digest FROM transactions t")).rows[0];
  const report=await reviewDataCleanup(admin);
  assert.equal(report.complete,true,JSON.stringify(report.checks.filter(value=>value.status==='not_run')));
  const check=name=>report.checks.find(value=>value.name===name);
  for(const name of ['cap_rule_business_equivalence','benefit_business_equivalence','card_product_name_candidates','issuer_name_candidates','parser_definition_equivalence','parser_failure_shape_candidates'])assert.equal(check(name)?.extra_rows,'1',name);
  assert.equal(check('transactions').rows,'2');assert.equal(check('transactions').invalid_amount_rows,'0');assert.equal(check('transactions').amount_sum_digest,crypto.createHash('sha256').update('100.00').digest('hex'));
  assert.equal(report.checks.find(value=>value.constraint==='orphan_fixture').orphan_rows,'1');assert.equal(report.checks.find(value=>value.constraint==='composite_orphan_fixture').orphan_rows,'1');
  assert.ok(report.index_review.equivalent_groups.some(value=>value.indexes.some(index=>index.name==='transactions_amount_copy_a')));
  assert.ok(report.index_review.uniqueness_overlap_groups.some(value=>value.indexes.some(index=>index.name==='transaction_amount_unique'&&index.constraint_backed)));
  const serialized=JSON.stringify(report);assert.equal(serialized.includes(marker),false);assert.equal(serialized.includes('00000000-0000-4000-8000-000000000001'),false);assert.equal(report.id_maps_included,false);assert.equal(report.changes_performed,false);
  const after=(await admin.query("SELECT count(*)::text AS rows,md5(string_agg(md5(row_to_json(t)::text),'' ORDER BY id)) AS digest FROM transactions t")).rows[0];assert.deepEqual(after,before,'no synthetic history was modified');
  const repeat=await reviewDataCleanup(admin);assert.equal(repeat.checks.find(value=>value.name==='transactions').row_multiset_digest,check('transactions').row_multiset_digest);
  await admin.query(`ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;ALTER TABLE transactions FORCE ROW LEVEL SECURITY;
   CREATE ROLE ${runtime} LOGIN PASSWORD 'synthetic-no-secret' NOSUPERUSER NOBYPASSRLS;GRANT USAGE ON SCHEMA public TO ${runtime};GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${runtime};`);
  const loginUrl=new URL(raw);loginUrl.username=runtime;loginUrl.password='synthetic-no-secret';reader=new Client({connectionString:loginUrl.toString(),ssl:false,connectionTimeoutMillis:3000});await reader.connect();
  const partial=await reviewDataCleanup(reader);assert.equal(partial.complete,false);assert.ok(partial.checks.some(value=>value.object==='public.transactions'&&value.reason==='full_visibility_or_permission_required'));
  const bounded=await reviewDataCleanup(admin,{maxRowsPerTable:1});assert.equal(bounded.complete,false);assert.ok(bounded.checks.some(value=>value.reason==='table_row_bound_exceeded'));
  console.log('PASS: restored-copy duplicate candidates preserve cap/benefit/parser discriminators; equivalent/unique indexes protected; composite orphan counts and financial digests verified; actual data/IDs absent; no history changes; RLS-hidden and oversized reviews cannot pass');
 }finally{if(reader)await reader.end();await admin.end();}
}
main().catch(error=>{console.error('Synthetic data cleanup review fixture failed',error.stack);process.exitCode=1;});
