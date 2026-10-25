'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {createLifecycleJournal,initializeJournal,readLifecycleJournal,genesis}=require('../src/account_lifecycle_journal');
const {createAccountLifecycleWorker,CLAIM_SQL,CHECKPOINT_SQL,ADVANCE_SQL}=require('../src/account_lifecycle_worker');
async function fixture(t){
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'pp-denial-journal-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));
 const options={roots:[path.join(root,'one'),path.join(root,'two')],checkpointRoot:path.join(root,'separate-checkpoint'),journalId:crypto.randomBytes(32).toString('hex'),signingKey:crypto.randomBytes(32).toString('base64'),encrypt:async b=>Buffer.from('encrypted-fixture:'+b.toString('base64'))};
 const checkpoint=await initializeJournal(options),journal=createLifecycleJournal(options);
 const decrypt=async b=>Buffer.from(b.toString().slice('encrypted-fixture:'.length),'base64');
 return {root,options,checkpoint,journal,decrypt};
}
const intent=()=>({request_id:crypto.randomUUID(),user_id:crypto.randomUUID(),generation:'1'});
test('journal requires separate retained key, stable identity and two distinct private roots',async t=>{
 assert.throws(()=>createLifecycleJournal({}),/required/);
 const f=await fixture(t);assert.deepEqual(await f.journal.inspect(),f.checkpoint);
 await assert.rejects(initializeJournal(f.options),/EEXIST/);
 const bad=createLifecycleJournal({...f.options,roots:[f.options.roots[0],f.options.roots[0]]});await assert.rejects(bad.inspect(),/distinct/);
 await fs.chmod(f.options.roots[0],0o755);await assert.rejects(f.journal.inspect(),/private/);
});
test('journal authenticates chain, preserves stable intent and verifies complete copies before replay',async t=>{
 const f=await fixture(t),value=intent();const head=await f.journal.append(value,f.checkpoint);
 assert.equal(head.sequence,1);assert.notEqual(head.head,genesis(f.options.journalId));
 const replay=await readLifecycleJournal(f.options,{expectedCheckpoint:head,decrypt:f.decrypt});assert.deepEqual(replay.intents,[value]);assert.deepEqual(replay.checkpoint,head);assert.equal(replay.checkpoint_heads[1],head.head);
 await assert.rejects(readLifecycleJournal(f.options,{decrypt:f.decrypt}),/checkpoint/);
 await assert.rejects(f.journal.append(intent(),f.checkpoint),/mismatch/);
 // Old independently retained checkpoint cannot certify a longer/shorter log.
 await assert.rejects(readLifecycleJournal(f.options,{expectedCheckpoint:f.checkpoint,decrypt:f.decrypt}),/rollback/);
});
test('single-copy loss, tampering, symlink and truncation all fail closed',async t=>{
 const f=await fixture(t),head=await f.journal.append(intent(),f.checkpoint);
 const a=path.join(f.options.roots[0],'00000001.json'),b=path.join(f.options.roots[1],'00000001.json'),original=await fs.readFile(a);
 await fs.writeFile(a,Buffer.from(original.toString().replace('ciphertext','Ciphertext')));await assert.rejects(f.journal.inspect(),/authentication/);
 await fs.writeFile(a,original);await fs.unlink(b);await assert.rejects(f.journal.inspect(),/disagree/);
 await fs.symlink(a,b);await assert.rejects(f.journal.inspect());await fs.unlink(b);await fs.unlink(a);
 await assert.rejects(readLifecycleJournal(f.options,{expectedCheckpoint:head,decrypt:f.decrypt}),/rollback|checkpoint disagree/);
});
test('encryption failure leaves both copies empty and never emits plaintext on disk',async t=>{
 const f=await fixture(t),value=intent(),broken=createLifecycleJournal({...f.options,encrypt:async()=>{throw Error('private error');}});
 await assert.rejects(broken.append(value,f.checkpoint));assert.deepEqual(await f.journal.inspect(),f.checkpoint);
 for(const root of f.options.roots){const names=await fs.readdir(root);assert.deepEqual(names,['journal.json']);}
});
test('concurrent append is refused and conflicting irreversible histories cannot be replayed',async t=>{
 const f=await fixture(t);let release;const hold=new Promise(r=>{release=r;});
 const journal=createLifecycleJournal({...f.options,encrypt:async b=>{await hold;return f.options.encrypt(b);}}),value=intent();
 const first=journal.append(value,f.checkpoint);await assert.rejects(journal.append(intent(),f.checkpoint),/busy/);release();const one=await first;
 const two=await f.journal.append({...value,request_id:crypto.randomUUID()},one);
 await assert.rejects(readLifecycleJournal(f.options,{expectedCheckpoint:two,decrypt:f.decrypt}),/Conflicting/);
});
test('worker refuses to claim without journal and commits only after durable acknowledgement',async()=>{
 let checkpoint={journal_id:'a'.repeat(64),sequence:0,head:'b'.repeat(64)},events=[],claims=0;
 const job={...intent(),profile_id:crypto.randomUUID(),lease_token:crypto.randomUUID()};delete job.user_id;
 const pool={query:async()=>({rows:[{acknowledged:true}]}),connect:async()=>({release(){events.push('release');},query:async(sql,args)=>{
  if(sql===CHECKPOINT_SQL)return {rows:[checkpoint]};if(sql===ADVANCE_SQL){checkpoint={...checkpoint,sequence:Number(args[1])+1,head:args[3]};events.push('checkpoint');return {rows:[]};}
  if(sql===CLAIM_SQL){events.push('claim');return {rows:claims++===0?[job]:[]};}events.push(sql);return {rows:[]};
 }})};
 await assert.rejects(createAccountLifecycleWorker({pool,enabled:true,applyAuthDeletion:async()=>{}})(),/not configured/);assert.equal(claims,0);
 const journal={inspect:async()=>({...checkpoint}),append:async(_,old)=>{events.push('durable-two-copy');return {...old,sequence:old.sequence+1,head:'c'.repeat(64)};}};
 const worker=createAccountLifecycleWorker({pool,enabled:true,journal,applyAuthDeletion:async()=>{events.push('auth');return{applied:true};}});
 assert.equal((await worker()).completed,1);assert.ok(events.indexOf('durable-two-copy')<events.indexOf('COMMIT'));assert.ok(events.indexOf('COMMIT')<events.indexOf('auth'));
});
test('journal failure rolls back claim, avoids auth and destroys uncertain connections',async()=>{
 const checkpoint={journal_id:'a'.repeat(64),sequence:0,head:'b'.repeat(64)},events=[];
 const job={request_id:crypto.randomUUID(),profile_id:crypto.randomUUID(),lease_token:crypto.randomUUID(),generation:'1'};
 const pool={query:async()=>assert.fail('must not acknowledge'),connect:async()=>({release:e=>events.push(e?'discard':'release'),query:async sql=>{
  events.push(sql);if(sql===CHECKPOINT_SQL)return {rows:[checkpoint]};if(sql===CLAIM_SQL)return {rows:[job]};if(sql==='ROLLBACK')throw Error('uncertain');return {rows:[]};
 }})};
 const worker=createAccountLifecycleWorker({pool,enabled:true,journal:{inspect:async()=>checkpoint,append:async()=>{throw Error('full');}},applyAuthDeletion:async()=>assert.fail('must not call auth')});
 await assert.rejects(worker(),/full/);assert.ok(events.includes('ROLLBACK'));assert.equal(events.at(-1),'discard');assert.equal(events.includes('COMMIT'),false);
});
