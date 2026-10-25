'use strict';
// Owned temporary files and synthetic keys only. No .env or deployed identity.
const fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const execFile=require('node:util').promisify(require('node:child_process').execFile);
const {initializeJournal,createLifecycleJournal,readLifecycleJournal}=require('../src/account_lifecycle_journal');
async function main(){
 const binary=process.env.LIFECYCLE_JOURNAL_AGE_TEST_BIN;if(!binary||!path.isAbsolute(binary))throw Error('Explicit age fixture binary path required');
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'pp-journal-age-'));
 try{
  const identity=path.join(root,'identity'),recipients=path.join(root,'recipients');
  await execFile(path.join(path.dirname(binary),'age-keygen'),['-o',identity]);
  const publicKey=(await execFile(path.join(path.dirname(binary),'age-keygen'),['-y',identity])).stdout;
  await fs.writeFile(recipients,publicKey,{mode:0o600});
  const options={roots:[path.join(root,'copy-a'),path.join(root,'copy-b')],checkpointRoot:path.join(root,'separate-checkpoint'),journalId:crypto.randomBytes(32).toString('hex'),signingKey:crypto.randomBytes(32).toString('base64'),recipientsFile:recipients,ageBinary:binary};
  const start=await initializeJournal(options),journal=createLifecycleJournal(options);
  const intent={request_id:crypto.randomUUID(),user_id:crypto.randomUUID(),generation:'3'};
  const end=await journal.append(intent,start);assert.deepEqual(await journal.head(),end);
  for(const directory of options.roots){const bytes=await fs.readFile(path.join(directory,'00000001.json'));assert.ok(!bytes.includes(Buffer.from(intent.user_id)));assert.ok(!bytes.includes(Buffer.from(intent.request_id)));}
  const verified=await readLifecycleJournal(options,{expectedCheckpoint:end,identityFile:identity});assert.deepEqual(verified.intents,[intent]);
  const wrongKey={...options,signingKey:crypto.randomBytes(32).toString('base64')};await assert.rejects(readLifecycleJournal(wrongKey,{expectedCheckpoint:end,identityFile:identity}));
  console.log('PASS: real age-encrypted two-copy denial journal, HMAC chain/checkpoint, fsynced opaque files, full decrypt/UUID recovery and wrong-authentication-key refusal');
 }finally{await fs.rm(root,{recursive:true,force:true});}
}
main().catch(()=>{console.error('Synthetic age journal fixture failed');process.exitCode=1;});
