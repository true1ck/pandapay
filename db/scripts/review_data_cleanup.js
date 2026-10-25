#!/usr/bin/env node
'use strict';

// Explicit restored-copy review only. Reports counts, catalog metadata and
// reconciliation digests. It never returns customer values/IDs or proposes a
// survivor, merges history, deletes rows, drops indexes, or changes constraints.
const crypto=require('node:crypto');
const {labelIdentitySql,RULE_KEYS,FORMAT:LABEL_IDENTITY_FORMAT}=require('../../api/src/catalogue_label_identity');
const {resolveDatabaseTls}=require('../../api/src/db_tls');
const FORMAT='pandapay-data-cleanup-review-v1';
const CATALOG_LIMIT=10000;
const sqlDigest=expression=>`encode(sha256(convert_to(${expression},'UTF8')),'hex')`;
const SCHEMAS={product:['public','pandapay','promotions','partner_webhook','backup_status','imap_worker','account_lifecycle','account_recovery','maintenance'],auth:['public','auth_private','console_private']};
const DUPLICATE_RULES=[
 {name:'cap_rule_business_equivalence',table:'public.cap_rules',exclude:['id','created_at','updated_at'],normalize:['label']},
 {name:'benefit_business_equivalence',table:'public.card_benefits',exclude:['id','created_at','updated_at'],normalize:['label']},
 {name:'card_product_name_candidates',table:'public.card_products',keys:['issuer_id','name','network','card_type'],normalize:['name']},
 {name:'issuer_name_candidates',table:'public.issuers',keys:['name'],normalize:['name']},
 {name:'category_name_candidates',table:'public.spend_categories',keys:['name'],normalize:['name']},
 {name:'parser_definition_equivalence',table:'public.parser_patterns',exclude:['id','created_at','updated_at','sample_text','success_count','failure_count'],normalize:[]},
 {name:'parser_failure_shape_candidates',table:'public.parser_failures',keys:['channel','sender_pattern','redacted_shape'],normalize:[]},
 ...Object.entries(RULE_KEYS).map(([table,keys])=>({name:table==='cap_rules'?'cap_rule_normalized_identity_v1':'benefit_normalized_identity_v1',table:'public.'+table,keys,normalize:['label'],normalizationVersion:LABEL_IDENTITY_FORMAT})),
];
const FINANCIAL_RULES=[
 {name:'transactions',table:'public.transactions',amount:'amount_inr',positive:true},
 {name:'transaction_splits',table:'public.transaction_splits',amount:'amount_inr',positive:true},
 {name:'points_ledger',table:'public.points_ledger',amount:'delta_points',positive:false},
 {name:'cap_consumption',table:'public.cap_states',amount:'consumed',positive:false},
 {name:'milestone_spend',table:'public.milestone_states',amount:'qualified_spend',positive:false},
 {name:'fee_waiver_spend',table:'public.fee_waiver_states',amount:'qualified_spend',positive:false},
 {name:'lounge_history',table:'public.lounge_usage',amount:null,positive:false},
];
const CATALOG={
 metadata:`SELECT current_setting('server_version_num')::int AS server_version_num,
   current_setting('transaction_read_only') AS read_only,current_setting('transaction_isolation') AS isolation,
   current_setting('server_encoding') AS encoding,
   (SELECT datcollate FROM pg_database WHERE datname=current_database()) AS collation,
   (SELECT datctype FROM pg_database WHERE datname=current_database()) AS character_classification`,
 columns:`SELECT n.nspname AS schema,c.relname AS relation,a.attname AS column
   FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname=ANY($1::text[]) AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped
   ORDER BY n.nspname,c.relname,a.attnum LIMIT $2`,
 indexes:`SELECT n.nspname AS schema,t.relname AS relation,i.relname AS name,am.amname AS method,
   x.indisunique AS unique,x.indisprimary AS primary,x.indisexclusion AS exclusion,
   x.indisvalid AS valid,x.indisready AS ready,x.indisreplident AS replica_identity,x.indisclustered AS clustered,
   x.indnkeyatts AS key_count,x.indnatts AS total_columns,x.indkey::text AS columns,
   x.indclass::text AS opclasses,x.indcollation::text AS collations,x.indoption::text AS options,
   x.indnullsnotdistinct AS nulls_not_distinct,
   ${sqlDigest("COALESCE(pg_get_expr(x.indexprs,x.indrelid),'')")} AS expression_digest,
   ${sqlDigest("COALESCE(pg_get_expr(x.indpred,x.indrelid),'')")} AS predicate_digest,
   COALESCE(i.reloptions,'{}') AS storage_options,i.reltablespace AS tablespace,
   ARRAY(SELECT conname::text FROM pg_constraint c WHERE c.conindid=x.indexrelid ORDER BY conname) AS constraints,
   pg_relation_size(i.oid)::text AS size_bytes,COALESCE(s.idx_scan,0)::text AS scans,
   COALESCE(s.idx_tup_read,0)::text AS tuples_read,COALESCE(s.idx_tup_fetch,0)::text AS tuples_fetched
   FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid
   JOIN pg_namespace n ON n.oid=t.relnamespace JOIN pg_am am ON am.oid=i.relam
   LEFT JOIN pg_stat_user_indexes s ON s.indexrelid=i.oid
   WHERE n.nspname=ANY($1::text[]) ORDER BY n.nspname,t.relname,i.relname LIMIT $2`,
 foreignKeys:`SELECT ns.nspname AS schema,t.relname AS relation,c.conname AS name,
   target_ns.nspname AS target_schema,target.relname AS target_relation,c.confmatchtype AS match,
   c.convalidated AS validated,
   ARRAY(SELECT a.attname::text FROM unnest(c.conkey) WITH ORDINALITY k(attnum,position)
     JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum ORDER BY k.position) AS columns,
   ARRAY(SELECT a.attname::text FROM unnest(c.confkey) WITH ORDINALITY k(attnum,position)
     JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.attnum ORDER BY k.position) AS target_columns
   FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace ns ON ns.oid=t.relnamespace
   JOIN pg_class target ON target.oid=c.confrelid JOIN pg_namespace target_ns ON target_ns.oid=target.relnamespace
   WHERE c.contype='f' AND ns.nspname=ANY($1::text[]) AND target_ns.nspname=ANY($1::text[])
   ORDER BY ns.nspname,t.relname,c.conname LIMIT $2`,
 statistics:`SELECT stats_reset FROM pg_stat_database WHERE datname=current_database() LIMIT $2`,
};

function quote(value){if(typeof value!=='string'||!value||Buffer.byteLength(value)>63||/[\x00-\x1f\x7f]/.test(value))throw new Error('Invalid reviewed identifier');return '"'+value.replaceAll('"','""')+'"';}
function tableSql(table){const pieces=table.split('.');if(pieces.length!==2)throw new Error('A reviewed schema-qualified table is required');return pieces.map(quote).join('.');}
function literal(value){return "'"+value.replaceAll("'","''")+"'";}
function normalized(alias,column){const value=`${alias}.${quote(column)}`;return `pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(${value}::text),'[[:space:]]+',' ','g'))`;}
function duplicateSql(rule){
 const table=tableSql(rule.table);
 let signature;
 if(rule.keys){signature=`pg_catalog.jsonb_build_array(${rule.keys.map(column=>rule.normalize.includes(column)?(rule.normalizationVersion===LABEL_IDENTITY_FORMAT?labelIdentitySql('t'):normalized('t',column)):`t.${quote(column)}`).join(',')})`;}
 else{
  signature=`(pg_catalog.to_jsonb(t)-ARRAY[${rule.exclude.map(literal).join(',')}]::text[])`;
  if(rule.normalize.length)signature+=` || pg_catalog.jsonb_build_object(${rule.normalize.flatMap(column=>[literal(column),normalized('t',column)]).join(',')})`;
 }
 return `SELECT count(*)::text AS duplicate_groups,COALESCE(sum(n-1),0)::text AS extra_rows,
   COALESCE(max(n),0)::text AS largest_group FROM (SELECT count(*) AS n FROM ${table} t
   GROUP BY ${signature} HAVING count(*)>1) duplicates`;
}
function financialSql(rule){
 const table=tableSql(rule.table),amount=rule.amount?quote(rule.amount):null;
 const bad=amount?`${amount} IS NULL OR ${amount}::text IN ('NaN','Infinity','-Infinity')${rule.positive?` OR ${amount}<=0`:''}`:'false';
 // Values never leave PostgreSQL. Row order is canonical, and timestamps/UUIDs
 // remain in the digest so an accidental history rewrite cannot look equal.
 return `SELECT count(*)::text AS rows,count(*) FILTER(WHERE ${bad})::text AS invalid_amount_rows,
   ${amount?sqlDigest(`COALESCE(sum(${amount})::text,'0')`):'NULL::text'} AS amount_sum_digest,
   ${sqlDigest('COALESCE(string_agg(row_digest,\'\' ORDER BY row_digest COLLATE "C"),\'\')')} AS row_multiset_digest
   FROM (SELECT ${amount?`t.${amount},`:''}${sqlDigest('pg_catalog.to_jsonb(t)::text')} AS row_digest FROM ${table} t) reviewed`;
}
function foreignKeySql(fk){
 if(!Array.isArray(fk.columns)||!fk.columns.length||fk.columns.length!==fk.target_columns?.length||fk.columns.length>32)throw new Error('Unsupported foreign key metadata');
 const source=tableSql(`${fk.schema}.${fk.relation}`),target=tableSql(`${fk.target_schema}.${fk.target_relation}`);
 const notNull=fk.columns.map(column=>`s.${quote(column)} IS NOT NULL`).join(' AND ');
 const anyNull=fk.columns.map(column=>`s.${quote(column)} IS NULL`).join(' OR ');
 const anyNotNull=fk.columns.map(column=>`s.${quote(column)} IS NOT NULL`).join(' OR ');
 const match=fk.columns.map((column,index)=>`t.${quote(fk.target_columns[index])}=s.${quote(column)}`).join(' AND ');
 return `SELECT count(*)::text AS orphan_rows FROM ${source} s WHERE
   ((${notNull}) AND NOT EXISTS(SELECT 1 FROM ${target} t WHERE ${match}))${fk.match==='f'?` OR ((${anyNull}) AND (${anyNotNull}))`:''}`;
}
function structuralKey(index,{includeUnique=true}={}){
 const keys=['schema','relation','method','key_count','total_columns','columns','opclasses','collations','options','nulls_not_distinct','expression_digest','predicate_digest','storage_options','tablespace'];
 if(includeUnique)keys.push('unique');
 return JSON.stringify(Object.fromEntries(keys.map(key=>[key,index[key]])));
}
function indexReview(indexes){
 const grouped=new Map(),overlap=new Map();
 for(const index of indexes){for(const [groups,options] of [[grouped,{}],[overlap,{includeUnique:false}]]){const key=structuralKey(index,options);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(index);}}
 const summarize=values=>({table:`${values[0].schema}.${values[0].relation}`,indexes:values.map(index=>({name:index.name,unique:index.unique,constraint_backed:index.constraints.length>0,primary:index.primary,exclusion:index.exclusion,replica_identity:index.replica_identity,valid:index.valid,ready:index.ready,clustered:index.clustered,size_bytes:index.size_bytes,scans:index.scans})),
   removal_approved:false,requires:['constraint and dependency review','known statistics window','representative query plans and write/read measurements','reviewed recreation path']});
 return {equivalent_groups:[...grouped.values()].filter(values=>values.length>1).map(summarize),
  uniqueness_overlap_groups:[...overlap.values()].filter(values=>values.length>1&&values.some(index=>index.unique)&&values.some(index=>!index.unique)).map(summarize),
  zero_scan_indexes:indexes.filter(index=>index.scans==='0').map(index=>({table:`${index.schema}.${index.relation}`,index:index.name,removal_approved:false}))};
}

async function reviewDataCleanup(client,{scope='product',maxChecks=160,maxDurationMs=60000,maxRowsPerTable=100000,now=Date.now}={}){
 if(!SCHEMAS[scope]||!Number.isInteger(maxChecks)||maxChecks<1||maxChecks>500||!Number.isInteger(maxDurationMs)||maxDurationMs<1000||maxDurationMs>300000||!Number.isInteger(maxRowsPerTable)||maxRowsPerTable<1||maxRowsPerTable>1000000)throw new Error('Invalid cleanup review bounds');
 const started=now(),catalog={},checks=[],rowCounts=new Map();let begun=false,attempted=0;
 const report={format:FORMAT,scope,generated_at:new Date(started).toISOString(),restored_copy_acknowledged:true,
  bounds:{max_checks:maxChecks,max_duration_ms:maxDurationMs,max_rows_per_table:maxRowsPerTable,catalog_rows:CATALOG_LIMIT},
  review_rules_sha256:crypto.createHash('sha256').update(JSON.stringify({duplicates:DUPLICATE_RULES,financial:FINANCIAL_RULES})).digest('hex'),
  changes_performed:false,customer_values_included:false,id_maps_included:false,
  normalization:'Broad label/name candidates use database-locale lowercase and whitespace matching. Separate normalized_identity_v1 checks use versioned ASCII-only label case/whitespace folding, preserving all other keys and null versus empty. Candidate equality is not merge approval.',
  label_identity_version:LABEL_IDENTITY_FORMAT,
  checks};
 async function check(name,object,sql){
  if(attempted>=maxChecks||now()-started>=maxDurationMs){const skipped={name,object,status:'not_run',reason:'review_budget_exhausted'};checks.push(skipped);return skipped;}
  attempted++;
  await client.query('SAVEPOINT data_review_check');
  try{const result=await client.query(sql);await client.query('RELEASE SAVEPOINT data_review_check');const item={name,object,status:'completed',...result.rows[0]};checks.push(item);return item;}
  catch(error){await client.query('ROLLBACK TO SAVEPOINT data_review_check');await client.query('RELEASE SAVEPOINT data_review_check');const item={name,object,status:'not_run',reason:error.code==='57014'?'statement_deadline':error.code==='42501'?'full_visibility_or_permission_required':'check_failed'};checks.push(item);return item;}
 }
 async function withinRows(table){
  if(rowCounts.has(table))return rowCounts.get(table);
  const count=await check('bounded_row_count',table,`SELECT count(*)::text AS rows FROM (SELECT 1 FROM ${tableSql(table)} LIMIT ${maxRowsPerTable+1}) bounded`);
  const okay=count.status==='completed'&&Number(count.rows)<=maxRowsPerTable;rowCounts.set(table,okay);
  if(!okay&&count.status==='completed'){count.status='not_run';count.reason='table_row_bound_exceeded';}
  return okay;
 }
 try{
  await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');begun=true;
  await client.query("SET LOCAL statement_timeout='3000ms'");await client.query("SET LOCAL lock_timeout='500ms'");
  await client.query("SET LOCAL idle_in_transaction_session_timeout='15000ms'");await client.query('SET LOCAL search_path=pg_catalog');
  await client.query("SET LOCAL work_mem='4MB'");await client.query('SET LOCAL max_parallel_workers_per_gather=0');
  await client.query("SET LOCAL timezone='UTC'");await client.query("SET LOCAL datestyle='ISO,YMD'");
  // This does not bypass or disable RLS. PostgreSQL raises an error if RLS
  // would filter rows, preventing a partial review from claiming completeness.
  await client.query('SET LOCAL row_security=off');
  for(const [name,sql] of Object.entries(CATALOG)){
   const query=name==='metadata'?sql:sql.includes('$1')?sql:`WITH review_parameters AS(SELECT $1::text[] AS schemas) ${sql}`;
   const result=await client.query(query,name==='metadata'?[]:[SCHEMAS[scope],CATALOG_LIMIT+1]);
   if(name==='metadata'){catalog.metadata=result.rows[0];if(catalog.metadata?.read_only!=='on'||catalog.metadata?.isolation!=='repeatable read'||catalog.metadata.server_version_num<150000)throw new Error('Unsupported or non-read-only cleanup review');}
   else{if(result.rows.length>CATALOG_LIMIT)throw new Error('Catalog review limit exceeded');catalog[name]=result.rows;}
  }
  const available=new Map();for(const column of catalog.columns){const key=`${column.schema}.${column.relation}`;if(!available.has(key))available.set(key,new Set());available.get(key).add(column.column);}
  const duplicates=scope==='product'?DUPLICATE_RULES:[];
  const financial=scope==='product'?FINANCIAL_RULES:[];
  for(const rule of [...duplicates,...financial]){
   const columns=available.get(rule.table),required=[...(rule.keys||[]),...(rule.normalize||[]),...(rule.amount?[rule.amount]:[])];
   if(!columns||required.some(column=>!columns.has(column))){checks.push({name:rule.name,object:rule.table,status:'not_applicable',reason:'reviewed_table_or_columns_absent'});continue;}
   if(!await withinRows(rule.table)){checks.push({name:rule.name,object:rule.table,status:'not_run',reason:'table_review_unavailable'});continue;}
   await check(rule.name,rule.table,rule.amount!==undefined?financialSql(rule):duplicateSql(rule));
  }
  for(const fk of catalog.foreignKeys){
   const object=`${fk.schema}.${fk.relation}`;
   if(!await withinRows(object)||!await withinRows(`${fk.target_schema}.${fk.target_relation}`)){checks.push({name:'foreign_key_orphans',object,constraint:fk.name,status:'not_run',reason:'table_review_unavailable'});continue;}
   const item=await check('foreign_key_orphans',object,foreignKeySql(fk));item.constraint=fk.name;item.validated=fk.validated;
  }
  await client.query('COMMIT');begun=false;
 }catch(error){if(begun)await client.query('ROLLBACK').catch(()=>{});throw error;}
 report.catalog=catalog;
 report.index_review=indexReview(catalog.indexes);
 report.complete=checks.every(check=>check.status==='completed'||check.status==='not_applicable');
 report.acceptance={canonicalization_approved:false,index_removal_approved:false,
  required:['fresh exact-candidate restored copy','review candidate semantics and historical rules/parser fixtures','explicit private old-to-new ID map before any rewiring','reconcile transaction/cap/benefit/entitlement history and digests','constraint dependency and query plan review','repeat restore and application compatibility evidence']};
 return report;
}

function parseArgs(argv){const result={scope:'product',restoredCopy:false,requireComplete:false};for(let i=0;i<argv.length;i++){if(argv[i]==='--restored-copy')result.restoredCopy=true;else if(argv[i]==='--require-complete')result.requireComplete=true;else if(argv[i]==='--scope'&&argv[i+1])result.scope=argv[++i];else throw new Error('Usage: review_data_cleanup.js --restored-copy [--scope product|auth] [--require-complete]');}if(!result.restoredCopy||!SCHEMAS[result.scope])throw new Error('Explicit restored-copy acknowledgement and known scope are required');return result;}
function connectionOptions(env=process.env){if(!env.DATA_REVIEW_DATABASE_URL)throw new Error('DATA_REVIEW_DATABASE_URL is required');return {...resolveDatabaseTls(env.DATA_REVIEW_DATABASE_URL,{NODE_ENV:env.NODE_ENV,DB_SSL:env.DATA_REVIEW_DB_SSL,DB_SSL_CA:env.DATA_REVIEW_DB_SSL_CA,DB_SSL_CA_FILE:env.DATA_REVIEW_DB_SSL_CA_FILE}),connectionTimeoutMillis:5000,query_timeout:5000,application_name:'pandapay-data-cleanup-review'};}
async function main(argv=process.argv.slice(2),env=process.env){const options=parseArgs(argv),{Client}=require('../../api/node_modules/pg'),client=new Client(connectionOptions(env));client.on('error',()=>{});try{await client.connect();const report=await reviewDataCleanup(client,{scope:options.scope});process.stdout.write(JSON.stringify(report,null,2)+'\n');if(options.requireComplete&&!report.complete)process.exitCode=2;}finally{await client.end().catch(()=>{});}}
if(require.main===module)main().catch(()=>{process.stderr.write('Restored-copy data review failed; no complete report produced.\n');process.exitCode=1;});
module.exports={FORMAT,SCHEMAS,DUPLICATE_RULES,FINANCIAL_RULES,CATALOG,quote,tableSql,duplicateSql,financialSql,foreignKeySql,indexReview,reviewDataCleanup,parseArgs,connectionOptions};
