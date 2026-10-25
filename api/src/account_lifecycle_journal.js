'use strict';
// External encrypted denial-intent log. No database, .env, automatic key
// generation, retention pruning, shell invocation or plaintext file is used.
const fs=require('node:fs/promises'),constants=require('node:fs').constants,path=require('node:path');
const {createHash,createHmac,timingSafeEqual,randomBytes}=require('node:crypto');
const {spawn}=require('node:child_process');
const FORMAT='pandapay-lifecycle-journal-v1',MAX_RECORDS=4096,MAX_BYTES=64*1024*1024,MAX_FILE=65536;
const HEX=/^[a-f0-9]{64}$/,UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const sha=b=>createHash('sha256').update(b).digest('hex');
const json=x=>JSON.stringify(x);
function record(value){
 if(!value||Object.keys(value).sort().join(',')!=='generation,request_id,user_id'||!UUID.test(value.request_id)||!UUID.test(value.user_id)||! /^[1-9][0-9]{0,18}$/.test(String(value.generation))||BigInt(value.generation)>9223372036854775807n)throw Error('Invalid journal intent');
 return {request_id:value.request_id.toLowerCase(),user_id:value.user_id.toLowerCase(),generation:String(value.generation)};
}
function configuration({roots,checkpointRoot,journalId,signingKey,recipientsFile,ageBinary='age',encrypt}={}){
 if(!Array.isArray(roots)||roots.length!==2||roots.some(x=>typeof x!=='string'||!path.isAbsolute(x))||!HEX.test(journalId||''))throw Error('Two explicit journal roots and stable journal ID required');
 if(typeof checkpointRoot!=='string'||!path.isAbsolute(checkpointRoot))throw Error('Separate latest-checkpoint root required');
 const key=Buffer.from(signingKey||'','base64');if(key.length!==32||key.toString('base64')!==signingKey)throw Error('Separate retained journal authentication key required');
 if(!encrypt&&(!path.isAbsolute(recipientsFile||'')||typeof ageBinary!=='string'||(!path.isAbsolute(ageBinary)&&ageBinary!=='age')))throw Error('Journal encryption configuration invalid');
 const mac=value=>createHmac('sha256',key).update(json(value)).digest('hex');
 const verify=value=>{const {authentication,...body}=value;if(!HEX.test(authentication||'')||!timingSafeEqual(Buffer.from(authentication,'hex'),Buffer.from(mac(body),'hex')))throw Error('Journal authentication failed');return body;};
 return {roots:roots.map(x=>path.resolve(x)),checkpointRoot:path.resolve(checkpointRoot),journalId,recipientsFile,ageBinary,encrypt,mac,verify};
}
async function readPrivate(file,limit=MAX_FILE){
 const handle=await fs.open(file,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{const before=await handle.stat();if(!before.isFile()||before.size>limit||(before.mode&0o077)||(typeof process.getuid==='function'&&before.uid!==process.getuid()))throw Error('Journal file is not private/bounded');const bytes=await handle.readFile();const after=await handle.stat();if(bytes.length!==before.size||before.size!==after.size||before.mtimeMs!==after.mtimeMs)throw Error('Journal changed during read');return bytes;}finally{await handle.close();}
}
async function syncDirectory(directory){const h=await fs.open(directory,constants.O_RDONLY);try{await h.sync();}finally{await h.close();}}
async function writeAtomic(directory,name,bytes){
 const temp=path.join(directory,'.pending-'+randomBytes(16).toString('hex'));
 const h=await fs.open(temp,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 try{
  try{await h.writeFile(bytes);await h.sync();}finally{await h.close();}
  await fs.link(temp,path.join(directory,name));await syncDirectory(directory);
 }finally{await fs.unlink(temp).catch(()=>{});}
}
async function rootsChecked(config){
 const roots=[];
 for(const root of [...config.roots,config.checkpointRoot]){const s=await fs.lstat(root);if(!s.isDirectory()||s.isSymbolicLink()||(s.mode&0o077)||(typeof process.getuid==='function'&&s.uid!==process.getuid()))throw Error('Journal root must be an owned private directory');roots.push(await fs.realpath(root));}
 if(roots.some((r,i)=>roots.some((other,j)=>i!==j&&(r===other||r.startsWith(other+path.sep)))))throw Error('Journal copies/checkpoint require distinct non-overlapping roots');
 return roots.slice(0,2);
}
const genesis=id=>sha(Buffer.from(FORMAT+'\0'+id));
async function initializeJournal(options){
 const c=configuration(options);
 // Operator creates roots explicitly; startup never initializes over evidence.
 for(const root of [...c.roots,c.checkpointRoot])await fs.mkdir(root,{mode:0o700,recursive:false});
 const roots=await rootsChecked(c),body={format:FORMAT,journal_id:c.journalId};
 for(const root of roots)await writeAtomic(root,'journal.json',Buffer.from(json({...body,authentication:c.mac(body)})));
 const checkpoint={journal_id:c.journalId,sequence:0,head:genesis(c.journalId)};
 await saveCheckpoint(c,checkpoint);return checkpoint;
}

async function saveCheckpoint(c,checkpoint){
 const body={format:'pandapay-lifecycle-checkpoint-v1',checkpoint};
 const temp=path.join(c.checkpointRoot,'.pending-'+randomBytes(16).toString('hex'));
 const h=await fs.open(temp,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
 try{try{await h.writeFile(json({...body,authentication:c.mac(body)}));await h.sync();}finally{await h.close();}
  const target=path.join(c.checkpointRoot,'latest-checkpoint.json');
  try{await readPrivate(target,2048);}catch(error){if(error.code!=='ENOENT')throw error;}
  await fs.rename(temp,target);await syncDirectory(c.checkpointRoot);
 }finally{await fs.unlink(temp).catch(()=>{});}
}
async function trustedCheckpoint(c){
 const body=c.verify(JSON.parse(await readPrivate(path.join(c.checkpointRoot,'latest-checkpoint.json'),2048)));
 if(body.format!=='pandapay-lifecycle-checkpoint-v1'||!body.checkpoint||Object.keys(body).sort().join(',')!=='checkpoint,format')throw Error('Latest checkpoint invalid');
 return body.checkpoint;
}
async function scan(root,c){
 const marker=c.verify(JSON.parse(await readPrivate(path.join(root,'journal.json'))));
 if(marker.format!==FORMAT||marker.journal_id!==c.journalId||Object.keys(marker).length!==2)throw Error('Wrong journal identity');
 const names=[];let scanned=0;
 for await(const entry of await fs.opendir(root)){if(++scanned>MAX_RECORDS+16)throw Error('Journal directory capacity exceeded');if(/^\d{8}\.json$/.test(entry.name))names.push(entry.name);}
 names.sort();
 if(names.length>MAX_RECORDS)throw Error('Journal capacity exceeded');
 let head=genesis(c.journalId),size=0;const frames=[];
 for(let i=0;i<names.length;i++){
  if(names[i]!==String(i+1).padStart(8,'0')+'.json')throw Error('Journal sequence incomplete');
  const bytes=await readPrivate(path.join(root,names[i]));size+=bytes.length;if(size>MAX_BYTES)throw Error('Journal capacity exceeded');
  const frame=c.verify(JSON.parse(bytes));
  if(Object.keys(frame).sort().join(',')!=='ciphertext,format,journal_id,previous,sequence'||frame.format!==FORMAT||frame.journal_id!==c.journalId||frame.sequence!==i+1||frame.previous!==head||typeof frame.ciphertext!=='string')throw Error('Journal chain invalid');
  const ciphertext=Buffer.from(frame.ciphertext,'base64');if(!ciphertext.length||ciphertext.toString('base64')!==frame.ciphertext)throw Error('Journal ciphertext invalid');
  head=sha(bytes);frames.push({bytes,ciphertext});
 }
 return {checkpoint:{journal_id:c.journalId,sequence:names.length,head},frames,size};
}
// Cheap admission check after full startup verification. Recovery and every
// append still authenticate the complete chain. Listing is bounded and the
// authenticated tail + expected DB checkpoint detects truncation/rollback.
async function headOnly(root,c){
 const marker=c.verify(JSON.parse(await readPrivate(path.join(root,'journal.json'))));
 if(marker.format!==FORMAT||marker.journal_id!==c.journalId)throw Error('Wrong journal identity');
 const names=[];let scanned=0;
 const entries=await fs.opendir(root);
 for await(const entry of entries){
  if(++scanned>MAX_RECORDS+16)throw Error('Journal directory capacity exceeded');
  if(/^\d{8}\.json$/.test(entry.name))names.push(entry.name);
 }
 names.sort();if(names.length>MAX_RECORDS||names.some((n,i)=>n!==String(i+1).padStart(8,'0')+'.json'))throw Error('Journal sequence incomplete');
 let head=genesis(c.journalId);
 if(names.length){const bytes=await readPrivate(path.join(root,names.at(-1))),body=c.verify(JSON.parse(bytes));if(body.format!==FORMAT||body.journal_id!==c.journalId||body.sequence!==names.length)throw Error('Journal tail invalid');head=sha(bytes);}
 return {journal_id:c.journalId,sequence:names.length,head};
}
function same(a,b){return a.journal_id===b.journal_id&&a.sequence===b.sequence&&a.head===b.head;}
async function pair(c){const roots=await rootsChecked(c),copies=await Promise.all(roots.map(r=>scan(r,c)));if(!same(copies[0].checkpoint,copies[1].checkpoint)||!same(copies[0].checkpoint,await trustedCheckpoint(c)))throw Error('Journal copies/checkpoint disagree; keep writers fenced');return {roots,...copies[0]};}
async function age(args,input,{binary='age',maximum=MAX_FILE}={}){
 return new Promise((resolve,reject)=>{
  const child=spawn(binary,args,{stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH||'/usr/bin:/bin'}});let size=0,parts=[],settled=false;
  const finish=(err,value)=>{if(settled)return;settled=true;clearTimeout(timer);if(err){child.kill('SIGKILL');reject(Error('Journal encryption operation failed'));}else resolve(value);};
  const timer=setTimeout(()=>finish(true),8000);timer.unref();child.on('error',()=>finish(true));child.stdin.on('error',()=>finish(true));
  child.stdout.on('data',b=>{size+=b.length;if(size>maximum)finish(true);else parts.push(b);});child.stderr.resume();
  child.on('close',code=>finish(code!==0,Buffer.concat(parts)));child.stdin.end(input);
 });
}
async function locks(roots,fn){const held=[];try{for(const root of [...roots].sort()){const lock=path.join(root,'.append-lock');await fs.mkdir(lock,{mode:0o700});held.push(lock);}return await fn();}finally{for(const lock of held.reverse())await fs.rmdir(lock);}}
function createLifecycleJournal(options){
 const c=configuration(options);let busy=false,verifiedStartup=false;
 async function inspect(){const value=await pair(c);verifiedStartup=true;return value.checkpoint;}
 async function head(){if(!verifiedStartup)await inspect();const roots=await rootsChecked(c),values=await Promise.all(roots.map(r=>headOnly(r,c)));if(!same(values[0],values[1])||!same(values[0],await trustedCheckpoint(c)))throw Error('Journal copies/checkpoint disagree');return values[0];}
 async function append(value,expected){
  if(busy)throw Error('Journal append busy');busy=true;
  try{const roots=await rootsChecked(c);return await locks([...roots,c.checkpointRoot],async()=>{
    const state=await pair(c);if(!same(state.checkpoint,expected||{}))throw Error('Journal checkpoint mismatch; reconcile before traffic');
    if(state.frames.length>=MAX_RECORDS)throw Error('Journal capacity exceeded');
    const intent=record(value),plaintext=Buffer.from(json({format:FORMAT,journal_id:c.journalId,intent}));
    let ciphertext;
    try{ciphertext=c.encrypt?await c.encrypt(plaintext):await age(['-R',c.recipientsFile],plaintext,{binary:c.ageBinary});}finally{plaintext.fill(0);}
    if(!Buffer.isBuffer(ciphertext)||!ciphertext.length||ciphertext.length>32768)throw Error('Journal ciphertext invalid');
    const body={format:FORMAT,journal_id:c.journalId,sequence:state.checkpoint.sequence+1,previous:state.checkpoint.head,ciphertext:ciphertext.toString('base64')};
    const bytes=Buffer.from(json({...body,authentication:c.mac(body)}));if(state.size+bytes.length>MAX_BYTES)throw Error('Journal capacity exceeded');
    for(const root of [...roots,c.checkpointRoot]){const space=await fs.statfs(root);if(space.bavail*space.bsize<512*1024*1024+bytes.length||space.bavail/space.blocks<0.05)throw Error('Journal disk reserve unavailable');}
    const filename=String(body.sequence).padStart(8,'0')+'.json';
    // A one-copy failure deliberately leaves divergent durable evidence.
    // Never delete the successful copy or commit the database denial.
    for(const root of roots)await writeAtomic(root,filename,bytes);
    const next={journal_id:c.journalId,sequence:body.sequence,head:sha(bytes)};
    await saveCheckpoint(c,next);return next;
  });}finally{busy=false;}
 }
 return {inspect,head,append};
}
async function readLifecycleJournal(options,{expectedCheckpoint,identityFile,decrypt}={}){
 const c=configuration(options);if(!expectedCheckpoint||!Number.isSafeInteger(expectedCheckpoint.sequence)||!HEX.test(expectedCheckpoint.head||''))throw Error('Independently trusted latest checkpoint required');
 const state=await pair(c);if(!same(state.checkpoint,expectedCheckpoint))throw Error('Journal rollback/truncation or wrong checkpoint');
 if(!decrypt&&!path.isAbsolute(identityFile||''))throw Error('Explicit recovery identity required');
 const intents=[],seen=new Map();
 for(const frame of state.frames){const plaintext=decrypt?await decrypt(frame.ciphertext):await age(['-d','-i',identityFile],frame.ciphertext,{binary:c.ageBinary,maximum:2048});
  try{const value=JSON.parse(plaintext);if(value.format!==FORMAT||value.journal_id!==c.journalId||Object.keys(value).sort().join(',')!=='format,intent,journal_id')throw Error('Invalid journal payload');const intent=record(value.intent),prior=seen.get(intent.user_id);if(prior&&json(prior)!==json(intent))throw Error('Conflicting irreversible journal intent');if(!prior){seen.set(intent.user_id,intent);intents.push(intent);}}finally{plaintext.fill(0);}
 }
 // Verify and decrypt the complete bounded journal before returning any rows.
 return {checkpoint:state.checkpoint,intents,checkpoint_heads:[genesis(c.journalId),...state.frames.map(f=>sha(f.bytes))]};
}
module.exports={createLifecycleJournal,initializeJournal,readLifecycleJournal,genesis,FORMAT,MAX_RECORDS,MAX_BYTES};
