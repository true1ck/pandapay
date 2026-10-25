#!/usr/bin/env node
'use strict';

// Reviewed index decisions only. This module never discovers a preferred
// survivor or accepts caller supplied SQL.
const crypto = require('node:crypto');
const fs=require('node:fs'); const path=require('node:path');
const {sourceSnapshot}=require('./release_security_check');
const {resolveDatabaseTls}=require('../../api/src/db_tls');
const {SCHEMAS,FINANCIAL_RULES,financialSql}=require('./review_data_cleanup');
const TARGET_SQL=`SELECT current_database() AS database,(SELECT oid::text FROM pg_database WHERE datname=current_database()) AS database_oid,current_user AS operator,inet_server_addr()::text AS server_address,inet_server_port() AS server_port,current_setting('server_version_num')::integer AS server_version_num`;
const MAX_INPUT=16*1024*1024;
const FORMAT = 'pandapay-reviewed-index-plan-v1';
const RECEIPT = 'pandapay-reviewed-index-rehearsal-v1';
const REVIEW_FORMAT='pandapay-reviewed-index-review-v1';
function stable(value){ if(Array.isArray(value)) return `[${value.map(stable).join(',')}]`; if(value&&typeof value==='object') return `{${Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+stable(value[k])).join(',')}}`; return JSON.stringify(value); }
const hash = value => crypto.createHash('sha256').update(stable(value)).digest('hex');
const same = (a,b) => stable(a) === stable(b);
function fail(message) { throw new Error(message); }
function exactFields(value,allowed){if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!allowed.includes(k)))fail('Unknown review input fields');}
function quote(s) { if (typeof s !== 'string' || !s || Buffer.byteLength(s)>63 || /[\x00-\x1f\x7f]/.test(s)) fail('Invalid reviewed identifier'); return `"${s.replaceAll('"','""')}"`; }
function fresh(iso, now) { const t=Date.parse(iso); return Number.isFinite(t)&&t<=now&&now-t<=86400000; }
function protection(i) { return [i.schema,i.table,i.method,i.key_columns,i.included_columns,i.key_count,i.total_columns,i.opclasses,i.collations,i.options,i.nulls_not_distinct,i.expression_digest,i.predicate_digest,i.storage_options,i.tablespace,i.unique]; }
function inventoryDigest(snapshot) { return hash(snapshot); }
function readBounded(file){const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const b=fs.fstatSync(fd);if(!b.isFile()||b.size>MAX_INPUT)fail('Review input exceeds safe file bounds');const out=Buffer.alloc(b.size+1),n=fs.readSync(fd,out,0,out.length,0),a=fs.fstatSync(fd);if(n!==b.size||a.size!==b.size||a.mtimeMs!==b.mtimeMs||a.ctimeMs!==b.ctimeMs)fail('Review input changed during read');return JSON.parse(out.subarray(0,n).toString('utf8'));}finally{fs.closeSync(fd);}}
async function readIndexSnapshot(client,{scope='product'}={}){
 if(!SCHEMAS[scope])fail('Unknown index review scope');
 const schemas=SCHEMAS[scope];
 const indexes=(await client.query(`SELECT ns.nspname AS schema,t.relname AS table_name,i.relname AS name,i.oid::text AS index_oid,am.amname AS method,x.indisunique AS unique,x.indisprimary AS primary,x.indisexclusion AS exclusion,x.indisvalid AS valid,x.indisready AS ready,x.indislive AS live,x.indisreplident AS replica_identity,x.indisclustered AS clustered,x.indnkeyatts AS key_count,x.indnatts AS total_columns,
 ARRAY(SELECT a.attname::text FROM unnest(x.indkey) WITH ORDINALITY k(attnum,ord) LEFT JOIN pg_attribute a ON a.attrelid=x.indrelid AND a.attnum=k.attnum ORDER BY k.ord) AS all_columns,
 ARRAY(SELECT a.attname::text FROM unnest(x.indkey) WITH ORDINALITY k(attnum,ord) LEFT JOIN pg_attribute a ON a.attrelid=x.indrelid AND a.attnum=k.attnum WHERE k.ord<=x.indnkeyatts ORDER BY k.ord) AS key_columns,
 ARRAY(SELECT a.attname::text FROM unnest(x.indkey) WITH ORDINALITY k(attnum,ord) LEFT JOIN pg_attribute a ON a.attrelid=x.indrelid AND a.attnum=k.attnum WHERE k.ord>x.indnkeyatts ORDER BY k.ord) AS included_columns,
 x.indclass::text AS opclasses,x.indcollation::text AS collations,x.indoption::text AS options,x.indnullsnotdistinct AS nulls_not_distinct,COALESCE(pg_get_expr(x.indexprs,x.indrelid),'') AS expressions,COALESCE(pg_get_expr(x.indpred,x.indrelid),'') AS predicate,COALESCE(i.reloptions,'{}') AS storage_options,i.reltablespace AS tablespace,
 ARRAY(SELECT c.conname::text FROM pg_constraint c WHERE c.conindid=x.indexrelid ORDER BY c.conname) AS constraints,
 EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=i.oid AND d.refclassid='pg_extension'::regclass AND d.deptype='e') AS extension_owned,
 (t.relispartition OR EXISTS(SELECT 1 FROM pg_inherits h WHERE h.inhparent=x.indrelid OR h.inhrelid=x.indrelid)) AS partition_dependent,
 pg_get_indexdef(i.oid) AS definition
 FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid JOIN pg_namespace ns ON ns.oid=t.relnamespace JOIN pg_am am ON am.oid=i.relam WHERE ns.nspname=ANY($1::text[]) ORDER BY ns.nspname,t.relname,i.relname LIMIT 10001`,[schemas])).rows;
 if(indexes.length>10000)fail('Index catalog exceeds review bound');
 for(const i of indexes){i.table=i.table_name;i.expression_digest=hash(i.expressions);i.predicate_digest=hash(i.predicate);i.opclasses=i.opclasses.split(' ');i.collations=i.collations.split(' ');i.options=i.options.split(' ');}
 const ids=indexes.map(i=>i.index_oid);const dependencyRows=ids.length?(await client.query(`SELECT d.objid::text AS index_oid,d.deptype,c.relkind FROM pg_depend d LEFT JOIN pg_class c ON d.refclassid='pg_class'::regclass AND c.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=ANY($1::oid[]) AND d.deptype='n' AND d.refclassid<>'pg_constraint'::regclass ORDER BY d.objid,d.deptype`,[ids])).rows:[];const dependenciesByOid=new Map();for(const row of dependencyRows){if(!dependenciesByOid.has(row.index_oid))dependenciesByOid.set(row.index_oid,[]);dependenciesByOid.get(row.index_oid).push({deptype:row.deptype,relkind:row.relkind});}for(const i of indexes)i.dependencies=dependenciesByOid.get(i.index_oid)||[];
 const depsComplete=true;const metadata=(await client.query(`SELECT n.nspname AS schema,c.relname AS table_name,a.attname AS column_name FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=ANY($1::text[]) AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped LIMIT 100001`,[schemas])).rows;if(metadata.length>100000)fail('Relation metadata exceeds review bound');
 const rules=scope==='product'?FINANCIAL_RULES:[...new Set(metadata.map(r=>`${r.schema}.${r.table_name}`))].sort().map(table=>({name:table,table,amount:null}));
 const financial={};for(const rule of rules){const cols=new Set(metadata.filter(r=>`${r.schema}.${r.table_name}`===rule.table).map(r=>r.column_name));if(!cols.size)continue;if(rule.amount&&!cols.has(rule.amount))fail('Financial digest column is unavailable');const [schema,table]=rule.table.split('.'),count=(await client.query(`SELECT count(*)::int AS n FROM (SELECT 1 FROM ${quote(schema)}.${quote(table)} LIMIT 100001) bounded`)).rows[0];if(!count||count.n>100000)fail('Financial digest row bound exceeded');const r=await client.query(financialSql(rule));if(!r.rows[0])fail('Financial digest unavailable');financial[rule.name]=r.rows[0];}
 const relation_contracts=(await client.query(`SELECT n.nspname AS schema,c.relname AS table_name,c.relowner::text AS owner,c.relacl::text AS acl,c.relrowsecurity AS rls,c.relforcerowsecurity AS force_rls,c.relkind,
 ARRAY(SELECT pg_get_constraintdef(k.oid,true) FROM pg_constraint k WHERE k.conrelid=c.oid ORDER BY k.conname) AS constraints,
 ARRAY(SELECT row(p.polname,p.polcmd,p.polpermissive,p.polroles::text,pg_get_expr(p.polqual,p.polrelid),pg_get_expr(p.polwithcheck,p.polrelid))::text FROM pg_policy p WHERE p.polrelid=c.oid ORDER BY p.polname) AS policies
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=ANY($1::text[]) AND c.relkind IN ('r','p') ORDER BY n.nspname,c.relname LIMIT 10001`,[schemas])).rows;
 if(relation_contracts.length>10000)fail('Relation contracts exceed review bound');
 if(Object.keys(financial).length===0)fail('No data digests were available');return {scope,indexes,relation_contracts,dependencies:Object.fromEntries(indexes.map(i=>[`${i.schema}.${i.name}`,i.dependencies])),dependencies_complete:depsComplete,financial_digests:financial};
}

// Require complete, exact catalog attributes. Missing fields mean unknown.
function eligibility(index, retained, dependencies=[]) {
  if (!index || !retained) return 'missing_index';
  if (index.unique || index.primary || index.exclusion || index.replica_identity || index.clustered || !index.valid || !index.ready || index.live!==true || index.extension_owned || index.partition_dependent || index.constraints?.length || retained.exclusion || !retained.valid || !retained.ready || retained.live!==true || retained.extension_owned || retained.partition_dependent) return 'protected_index';
  if (dependencies.length || index.unknown_dependencies) return 'unknown_or_external_dependency';
  const required=['schema','table','name','method','key_columns','included_columns','key_count','total_columns','opclasses','collations','options','expression_digest','predicate_digest','nulls_not_distinct','storage_options','tablespace','definition','extension_owned','partition_dependent','unique','primary','exclusion','valid','ready','live','replica_identity','clustered','constraints'];
  if (required.some(k=>index[k]===undefined) || required.some(k=>retained[k]===undefined)) return 'incomplete_catalog_semantics';
  if (index.schema!==retained.schema || index.table!==retained.table) return 'different_table';
  if (index.unique) return 'unique_removal_refused';
  // Only exact equivalent definitions are eligible. Included columns never
  // count as keys and a wider/prefix index is not guessed to be equivalent.
  // An exact-key unique/constraint index can remain as the stronger survivor;
  // no unique or constraint-backed index is ever a removal target.
  if (same(protection({...index,unique:retained.unique}),protection(retained))) return null;
  return 'no_equivalent_protection';
}
function makePlan({source,target,snapshot,review,now=Date.now()}) {
  if (!source || !target || !snapshot?.indexes || !snapshot?.financial_digests || snapshot.dependencies_complete!==true) fail('Source, target and complete catalog/dependency snapshot are required');
  exactFields(review,['format','scope','reviewed_at','reviewed_by','review_reference','source_sha256','target_sha256','catalog_sha256','decisions']);
  if (!review || review.format!==REVIEW_FORMAT || review.scope!==snapshot.scope || review.source_sha256!==hash(source) || review.target_sha256!==hash(target) || review.catalog_sha256!==inventoryDigest(snapshot) || !fresh(review.reviewed_at,now) || !Array.isArray(review.decisions) || !review.decisions.length) fail('Fresh explicit review bound to exact source, target and catalog is required');
  if(typeof review.reviewed_by!=='string'||review.reviewed_by.length<3||review.reviewed_by.length>160||typeof review.review_reference!=='string'||review.review_reference.length<20||review.review_reference.length>1000)fail('Reviewer identity and review reference are required');
  const identities=new Set();
  const retainedDecisions=new Set();
  const plans=review.decisions.map(d=>{
    if(d.action==='retain'){
      exactFields(d,['action','schema','table','index_name','definition','reason']);
      const item=snapshot.indexes.find(i=>i.schema===d.schema&&i.table===d.table&&i.name===d.index_name);
      if(!item||item.definition!==d.definition||typeof d.reason!=='string'||d.reason.length<10||d.reason.length>1000)fail('Retained-index decision must bind its exact catalog definition and reason');
      const key=`${item.schema}.${item.name}`;if(retainedDecisions.has(key))fail('Duplicate reviewed index decision');retainedDecisions.add(key);return null;
    }
    exactFields(d,['action','schema','table','index_name','retain_name','original_definition','retained_definition','measurement']);
    exactFields(d.measurement,['explain_sha256','workload_sha256','measured_at']);
    if (d.action!=='drop' || typeof d.index_name!=='string' || typeof d.retain_name!=='string') fail('Only exact drop/retain decisions are modelled');
    if (!d.measurement || !d.measurement.explain_sha256 || !d.measurement.workload_sha256 || !d.measurement.measured_at || !fresh(d.measurement.measured_at,now)) fail('Fresh operator plan and workload evidence is required');
    const drop=snapshot.indexes.find(i=>i.schema===d.schema&&i.table===d.table&&i.name===d.index_name);
    const keep=snapshot.indexes.find(i=>i.schema===d.schema&&i.table===d.table&&i.name===d.retain_name);
    if (!drop||!keep) fail('Reviewed index identity is absent from exact inventory');
    const identity=`${drop.schema}.${drop.name}`; if(identities.has(identity)||drop.name===keep.name) fail('Duplicate or cyclic reviewed index decision'); identities.add(identity);
    if(!/^[a-f0-9]{64}$/.test(d.measurement.explain_sha256)||!/^[a-f0-9]{64}$/.test(d.measurement.workload_sha256)||!review.reviewed_by||!review.review_reference) fail('Reviewer identity and measured evidence digests are required');
    const reason=eligibility(drop,keep,snapshot.dependencies?.[`${drop.schema}.${drop.name}`]||[]); if(reason) fail(`Index removal refused: ${reason}`);
    if (drop.definition!==d.original_definition || keep.definition!==d.retained_definition) fail('Reviewed definitions do not match catalog');
    return {schema:drop.schema,table:drop.table,name:drop.name,retain:keep.name,definition:drop.definition,measurement:d.measurement};
  }).filter(Boolean);
  const dropped=new Set(plans.map(p=>`${p.schema}.${p.name}`));if([...retainedDecisions].some(key=>dropped.has(key))||plans.some(p=>plans.some(q=>q.name===p.retain&&q.schema===p.schema)))fail('Review contains a contradictory or cyclic retain/drop decision');
  return {format:FORMAT,generated_at:new Date(now).toISOString(),source_sha256:hash(source),target_sha256:hash(target),inventory_sha256:inventoryDigest(snapshot),financial_digests:snapshot.financial_digests,review_sha256:hash(review),operations:plans,retained_decisions:[...retainedDecisions].sort(),source,target,snapshot,review};
}
async function execute(client,{plan,source,target,snapshotProvider,sourceProvider,targetProvider,mode='rehearse',receipt=null,quiesced=false,now=Date.now()}={}) {
  if(!['rehearse','apply'].includes(mode)||quiesced!==true||typeof snapshotProvider!=='function'||typeof sourceProvider!=='function'||typeof targetProvider!=='function') fail('Explicit mode, quiesced acknowledgement and fresh source/target/catalog providers required');
  let begun=false;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ'); begun=true;
    await client.query("SET LOCAL statement_timeout='5000ms'"); await client.query("SET LOCAL lock_timeout='1000ms'"); await client.query("SET LOCAL idle_in_transaction_session_timeout='15000ms'"); await client.query('SET LOCAL search_path=pg_catalog'); await client.query('SET LOCAL row_security=off');
    const lock=await client.query('SELECT pg_try_advisory_xact_lock(1346458690,72) AS acquired');if(lock.rows[0]?.acquired!==true)fail('Another reviewed index reconciliation is active');
    const current=await snapshotProvider(client);
    if(plan?.format!==FORMAT||!fresh(plan.generated_at,now)||plan.source_sha256!==hash(source)||plan.target_sha256!==hash(target)||plan.inventory_sha256!==inventoryDigest(current)||!same(source,plan.source)||!same(target,plan.target)||!same(plan,makePlan({source:plan.source,target:plan.target,snapshot:plan.snapshot,review:plan.review,now:Date.parse(plan.generated_at)}))) fail('Plan is stale, tampered or not bound to exact source, target and catalog');
    if(!same(await sourceProvider(),source)) fail('Source changed before index reconciliation');
    if(!same(await targetProvider(client),target)) fail('Database target changed before index reconciliation');
    if(mode==='apply'&&(!receipt||receipt.format!==RECEIPT||!receipt.rolled_back||!fresh(receipt.verified_at,now)||receipt.plan_sha256!==hash(plan)||!/^([a-f0-9]{64})$/.test(receipt.after_inventory_sha256||''))) fail('Apply requires a fresh exact rehearsal receipt');
    for(const op of plan.operations) await client.query(`DROP INDEX ${quote(op.schema)}.${quote(op.name)} RESTRICT`);
    const after=await snapshotProvider(client);
    if(!same(after.financial_digests,plan.financial_digests)) fail('Financial digests changed');
    if(!same(after.relation_contracts,plan.snapshot.relation_contracts)) fail('Relation ownership, ACL, RLS or constraints changed');
    if(!same(await sourceProvider(),source)) fail('Source changed during index reconciliation');
    if(!same(await targetProvider(client),target)) fail('Database target changed during index reconciliation');
    const removed=new Set(plan.operations.map(o=>`${o.schema}.${o.name}`));
    const expected=plan.snapshot.indexes.filter(i=>!removed.has(`${i.schema}.${i.name}`));
    const sortIndexes=values=>values.slice().sort((a,b)=>`${a.schema}.${a.name}`.localeCompare(`${b.schema}.${b.name}`));
    if(!same(sortIndexes(after.indexes),sortIndexes(expected))) fail('Index catalog changed outside exact reviewed removals');
    for(const op of plan.operations) if(after.indexes.some(i=>i.schema===op.schema&&i.name===op.name)||!after.indexes.some(i=>i.schema===op.schema&&i.name===op.retain)) fail('Index catalog verification failed');
    if(mode==='apply'&&receipt.after_inventory_sha256!==inventoryDigest(after)) fail('Applied result differs from rehearsed catalog');
    if(mode==='apply') await client.query('COMMIT'); else await client.query('ROLLBACK'); begun=false;
    return {format:mode==='rehearse'?RECEIPT:'pandapay-reviewed-index-result-v1',verified_at:new Date(now).toISOString(),plan_sha256:hash(plan),after_inventory_sha256:inventoryDigest(after),rolled_back:mode==='rehearse',committed:mode==='apply',recreation_definitions:plan.operations.map(o=>o.definition),financial_digests:after.financial_digests};
  } catch(e) { if(begun) await client.query('ROLLBACK').catch(()=>{}); throw e; }
}
function connectionOptions(env=process.env){const url=env.INDEX_RECONCILIATION_DATABASE_URL;if(!url)fail('INDEX_RECONCILIATION_DATABASE_URL is required');return {...resolveDatabaseTls(url,{NODE_ENV:env.NODE_ENV,DB_SSL:env.INDEX_RECONCILIATION_DB_SSL,DB_SSL_CA:env.INDEX_RECONCILIATION_DB_SSL_CA,DB_SSL_CA_FILE:env.INDEX_RECONCILIATION_DB_SSL_CA_FILE}),connectionTimeoutMillis:5000,query_timeout:7000,application_name:'pandapay-reviewed-index-reconciliation'};}
function parseArgs(argv){const [mode,...rest]=argv;const o={mode,scope:'product',root:path.resolve(__dirname,'../..'),quiesced:false,restoredCopyAck:false};if(!['inspect','plan','rehearse','apply'].includes(mode))fail('Usage: reviewed_index_reconciliation.js inspect --restored-copy-ack [--scope product|auth] | plan --inspection FILE --review FILE | rehearse|apply --plan FILE --quiesced');for(let i=0;i<rest.length;i++){const a=rest[i];if(a==='--quiesced')o.quiesced=true;else if(a==='--restored-copy-ack')o.restoredCopyAck=true;else if(['--scope','--root','--inspection','--review','--plan','--receipt'].includes(a)&&rest[i+1])o[a.slice(2)]=a==='--root'?path.resolve(rest[++i]):rest[++i];else fail('Invalid index review arguments');}if(!['product','auth'].includes(o.scope))fail('Invalid review scope');if(mode==='inspect'&&!o.restoredCopyAck)fail('Read-only inspection requires explicit restored-copy acknowledgement');if(mode==='plan'&&(!o.inspection||!o.review))fail('Plan requires an inspection and explicit review file');if(['rehearse','apply'].includes(mode)&&(!o.plan||!o.quiesced))fail('Rehearsal/apply requires plan and quiesced maintenance acknowledgement');if(mode==='apply'&&!o.receipt)fail('Apply requires exact rehearsal receipt');return o;}
async function main(argv=process.argv.slice(2),env=process.env){const o=parseArgs(argv),source=sourceSnapshot(o.root);if(o.mode==='plan'){const inspection=readBounded(o.inspection),review=readBounded(o.review),now=Date.now();if(inspection.format!=='pandapay-reviewed-index-inspection-v1'||!fresh(inspection.generated_at,now)||inspection.source_sha256!==hash(source)||inspection.target_sha256!==hash(inspection.target)||review.format!==REVIEW_FORMAT||review.source_sha256!==inspection.source_sha256||review.target_sha256!==inspection.target_sha256||review.catalog_sha256!==inventoryDigest(inspection.snapshot))fail('Inspection/review is stale or not source/target/catalog bound');const plan=makePlan({source,target:inspection.target,snapshot:inspection.snapshot,review,now});process.stdout.write(JSON.stringify(plan,null,2)+'\n');return;}
 const {Client}=require('../../api/node_modules/pg'),client=new Client(connectionOptions(env));client.on('error',()=>{});try{await client.connect();if(o.mode==='inspect'){await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');try{await client.query("SET LOCAL statement_timeout='5000ms'");await client.query("SET LOCAL lock_timeout='1000ms'");await client.query('SET LOCAL search_path=pg_catalog');await client.query('SET LOCAL row_security=off');const target=(await client.query(TARGET_SQL)).rows[0],snapshot=await readIndexSnapshot(client,{scope:o.scope});await client.query('COMMIT');const source_sha256=hash(source),target_sha256=hash(target),catalog_sha256=inventoryDigest(snapshot);const review_template={format:REVIEW_FORMAT,scope:o.scope,reviewed_at:'',reviewed_by:'',review_reference:'',source_sha256,target_sha256,catalog_sha256,decisions:[]};process.stdout.write(JSON.stringify({format:'pandapay-reviewed-index-inspection-v1',generated_at:new Date().toISOString(),source_sha256,target_sha256,target,snapshot,review_template},null,2)+'\n');}catch(e){await client.query('ROLLBACK').catch(()=>{});throw e;}}
 else {const plan=readBounded(o.plan),receipt=o.receipt?readBounded(o.receipt):null,target=(await client.query(TARGET_SQL)).rows[0];const result=await execute(client,{plan,source,target,snapshotProvider:c=>readIndexSnapshot(c,{scope:plan.snapshot.scope||'product'}),sourceProvider:()=>sourceSnapshot(o.root),targetProvider:async c=>(await c.query(TARGET_SQL)).rows[0],mode:o.mode,receipt,quiesced:o.quiesced});process.stdout.write(JSON.stringify(result,null,2)+'\n');}}finally{await client.end().catch(()=>{});}}
if(require.main===module)main().catch(()=>{process.stderr.write('Reviewed index reconciliation failed; no successful receipt produced.\n');process.exitCode=1;});
module.exports={FORMAT,RECEIPT,TARGET_SQL,quote,hash,eligibility,makePlan,execute,inventoryDigest,readBounded,readIndexSnapshot,connectionOptions,parseArgs,main};
