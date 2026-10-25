#!/usr/bin/env node
'use strict';
// Explicit operator recovery. Reads no .env and never starts services/workers.
const fs=require('node:fs/promises'),path=require('node:path'),{constants}=require('node:fs');
const {initializeJournal,readLifecycleJournal,createLifecycleJournal,MAX_RECORDS}=require('../../api/src/account_lifecycle_journal');
const {reconcileAccountLifecycleTombstones}=require('../../api/src/account_lifecycle_recovery');
const {resolveDatabaseTls}=require('../../api/src/db_tls');
async function checkpoint(file){
 if(!path.isAbsolute(file||''))throw Error('Explicit independently retained checkpoint required');
 const handle=await fs.open(file,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{const stat=await handle.stat();if(!stat.isFile()||stat.size>2048||(stat.mode&0o077))throw Error('Private bounded checkpoint required');const raw=JSON.parse(await handle.readFile()),v=raw.format==='pandapay-lifecycle-checkpoint-v1'?raw.checkpoint:raw;if(Object.keys(v).sort().join(',')!=='head,journal_id,sequence')throw Error('Checkpoint format invalid');return v;}finally{await handle.close();}
}
async function main(argv=process.argv.slice(2),env=process.env){
 const command=argv[0];if(!['--initialize','--verify','--reconcile'].includes(command)||argv.length!==(command==='--reconcile'?2:1)||(command==='--reconcile'&&argv[1]!=='--quiesced'))throw Error('Usage: lifecycle_journal.js --initialize | --verify | --reconcile --quiesced');
 const options={roots:[env.ACCOUNT_LIFECYCLE_JOURNAL_A,env.ACCOUNT_LIFECYCLE_JOURNAL_B],checkpointRoot:env.ACCOUNT_LIFECYCLE_CHECKPOINT_ROOT,journalId:env.ACCOUNT_LIFECYCLE_JOURNAL_ID,signingKey:env.ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY,recipientsFile:env.ACCOUNT_LIFECYCLE_JOURNAL_RECIPIENTS_FILE,ageBinary:env.ACCOUNT_LIFECYCLE_JOURNAL_AGE_BINARY||'age'};
 if(command==='--initialize'){console.log(JSON.stringify(await initializeJournal(options)));return;}
 const expected=await checkpoint(env.LIFECYCLE_JOURNAL_EXPECTED_CHECKPOINT_FILE);
 const verified=await readLifecycleJournal(options,{expectedCheckpoint:expected,identityFile:env.LIFECYCLE_JOURNAL_RECOVERY_IDENTITY_FILE});
 if(command==='--verify'){console.log(JSON.stringify({status:'verified',records:verified.intents.length,checkpoint:verified.checkpoint}));return;}
 if(!env.LIFECYCLE_REPLAY_PRODUCT_DATABASE_URL||!env.LIFECYCLE_REPLAY_AUTH_DATABASE_URL||!env.LIFECYCLE_REPLAY_CONTROL_DATABASE_URL)throw Error('Explicit replay database connections required');
 const {Client}=require('../../api/node_modules/pg');const clients=[];
 try{
  for(const url of [env.LIFECYCLE_REPLAY_PRODUCT_DATABASE_URL,env.LIFECYCLE_REPLAY_AUTH_DATABASE_URL,env.LIFECYCLE_REPLAY_CONTROL_DATABASE_URL]){const client=new Client({...resolveDatabaseTls(url),connectionTimeoutMillis:5000,query_timeout:6000,statement_timeout:5000,application_name:'pandapay-quiesced-lifecycle-replay'});clients.push(client);await client.connect();}
  const [product,auth,controlClient]=clients;
  const control=(await controlClient.query('SELECT worker_enabled,journal_id,journal_sequence,journal_head FROM account_lifecycle.control WHERE singleton')).rows[0];
  if(!control||control.worker_enabled!==false)throw Error('Disable lifecycle worker database gate before replay');
  if(control.journal_id!==null&&(control.journal_id!==expected.journal_id||!Number.isSafeInteger(Number(control.journal_sequence))||verified.checkpoint_heads[Number(control.journal_sequence)]!==control.journal_head))throw Error('Restored database requires a newer or different trusted journal checkpoint');
  // Both services, their jobs and external writers must be fenced by operator.
  // Replay denial in product first, then auth. Any failure leaves the fence on.
  const plan=await require('../../api/src/account_lifecycle_replay_plan').collectRetainedTombstones({product,auth,retained:verified.intents});
  const retainedUsers=new Set(verified.intents.map(r=>r.user_id));
  const missing=plan.filter(r=>!retainedUsers.has(r.user_id));
  if(expected.sequence+missing.length>MAX_RECORDS)throw Error('Journal capacity insufficient for complete retained history');
  const journal=createLifecycleJournal(options);let latest=expected;
  for(const row of missing)latest=await journal.append(row,latest);
  const result=await reconcileAccountLifecycleTombstones({product,auth,quiesced:true,additionalTombstones:plan});
  await controlClient.query('UPDATE account_lifecycle.control SET journal_id=$1,journal_sequence=$2,journal_head=$3 WHERE singleton AND worker_enabled=false',[latest.journal_id,latest.sequence,latest.head]);
  console.log(JSON.stringify({status:'reconciled_keep_services_fenced',...result,journaled_existing_records:missing.length,checkpoint:latest}));
 }finally{for(const client of clients)await client.end().catch(()=>{});}
}
if(require.main===module)main().catch(()=>{console.error('Lifecycle journal operation failed; keep services fenced. No credentials or intent contents are logged.');process.exitCode=1;});
module.exports={main,checkpoint};
