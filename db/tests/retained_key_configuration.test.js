'use strict';
// One external configuration contract across independently packaged readers.
// Synthetic keys only; no process environment, database or network is used.
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {wrappingKey}=require('../../api/src/account_recovery_routes');
const {template,evaluateRelease}=require('../scripts/release_security_check');
const key=Buffer.alloc(32,19).toString('base64');
const cases=[
 ['unset',undefined,true],['null option',null,true],['blank','',true],['empty list','[]',true],
 ['one reader',JSON.stringify([['old-v1',key]]),true],
 ['prototype-safe ID',JSON.stringify([['__proto__',key],['constructor',key]]),true],
 ['eight readers',JSON.stringify(Array.from({length:8},(_,i)=>['key-'+i,key])),true],
 ['object root',JSON.stringify({old:key}),false],['JSON null','null',false],['JSON scalar','42',false],
 ['nonstring',{},false],['whitespace only',' ',false],['malformed','[',false],
 ['duplicate ID',JSON.stringify([['old',key],['old',key]]),false],
 ['bad ID',JSON.stringify([['old.key',key]]),false],['extra pair field',JSON.stringify([['old',key,'extra']]),false],
 ['unpadded key',JSON.stringify([['old',key.replace(/=+$/,'')]]),false],
 ['short key',JSON.stringify([['old',Buffer.alloc(31).toString('base64')]]),false],
 ['nine readers',JSON.stringify(Array.from({length:9},(_,i)=>['key-'+i,key])),false],
 ['byte bound',JSON.stringify([['old',key]]).padEnd(8193,' '),false],
 ['exact byte bound',JSON.stringify([['old',key]]).padEnd(8192,' '),true],
];
function phoneAccepts(raw){
 const context={module:{exports:{}},require,Buffer,process:{env:{NODE_ENV:'production',ENCRYPTION_ENABLED:'true',ENCRYPTION_KEY:key,ENCRYPTION_READ_KEYS_JSON:raw}}};
 try{vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../auth/src/utils/fieldEncryption.js'),'utf8'),context);return true;}catch{return false;}
}
function recoveryAccepts(raw){try{wrappingKey(key,'active',raw);return true;}catch{return false;}}
function releaseAccepts(name,raw){
 const inputs=template(),env={[name]:raw,ACCOUNT_RECOVERY_WRAPPING_KEY_ID:'active'};
 let pairs=[];try{pairs=typeof raw==='string'?JSON.parse(raw):[];}catch{}
 if(Array.isArray(pairs)&&pairs.every(p=>Array.isArray(p)&&typeof p[0]==='string'&&/^[A-Za-z0-9_-]{1,64}$/.test(p[0]))) {
  inputs.retainedReadKeyIds={[name]:Object.fromEntries(pairs.map(p=>[p[0],'synthetic-escrow-version']))};
 }
 const report=evaluateRelease({source:{candidate_sha256:'0'.repeat(64),file_sha256:{}},inputs,env});
 assert.equal(JSON.stringify(report).includes(key),false,'release output must omit key material');
 return !report.missing_gates.includes('retained_read_key_inventory');
}
for(const [name,raw,expected]of cases)test(`retained reader configuration parity: ${name}`,()=>{
 assert.equal(phoneAccepts(raw),expected,'phone reader');
 assert.equal(recoveryAccepts(raw),expected,'recovery reader');
 for(const variable of ['ENCRYPTION_READ_KEYS_JSON','ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON'])assert.equal(releaseAccepts(variable,raw),expected,variable);
});
test('active recovery ID is reserved while the unversioned phone legacy key has no ID',()=>{
 const raw=JSON.stringify([['active',key]]);
 assert.equal(phoneAccepts(raw),true);assert.equal(recoveryAccepts(raw),false);
 assert.equal(releaseAccepts('ENCRYPTION_READ_KEYS_JSON',raw),true);
 assert.equal(releaseAccepts('ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON',raw),false);
});
