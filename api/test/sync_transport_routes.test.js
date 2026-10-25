'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const helpers=require('../src/sync_request_validation');
const source=fs.readFileSync(require.resolve('../src/index'),'utf8');
const user='10000000-0000-4000-8000-000000000001';
const device='20000000-0000-4000-8000-000000000001';
const entityId='30000000-0000-4000-8000-000000000001';
// Execute the actual route registrations without booting index.js, loading
// dotenv, starting workers or opening a configured database/provider.
const sections=[
 ["app.post('/sync/register-device'",'/**\n * POST /notification-devices'],
 ["app.post('/sync/push'",'/**\n * GET /sync/pull?'],
 ["app.get('/sync/pull'",'/** POST /sync/ack'],
 ["app.post('/sync/ack'",'/** POST /sync/conflicts'],
 ["app.post('/sync/conflicts/:id/acknowledge'",'/**\n * POST /analytics/events'],
];
function fixture(query=async()=>({rows:[]}), {typed=false, transactionApplier}={}){
 const routes=new Map(),calls=[];
 const context={...helpers,config:{syncTypedWritesEnabled:typed},applyTransactionSync:transactionApplier,console:{error(){}},safeErrorCode:()=> 'safe_code',requireAuth(){},
  withUserClient:async(id,callback)=>{assert.equal(id,user);return callback({query:async(sql,args)=>{calls.push({sql,args:args===undefined?undefined:Array.from(args)});return query(sql,args);}});},
  app:Object.fromEntries(['post','get'].map(method=>[method,(url,auth,handler)=>routes.set(method+' '+url,handler)]))};
 for(const [begin,end]of sections){const start=source.indexOf(begin),stop=source.indexOf(end,start);assert.ok(start>=0&&stop>start);vm.runInNewContext(source.slice(start,stop),context);}
 return{calls,async invoke(method,url,request={}){const res={code:200,status(n){this.code=n;return this;},json(body){this.body=JSON.parse(JSON.stringify(body));return this;}};await routes.get(method+' '+url)({userId:user,body:{},query:{},params:{},...request},res);return res;}};
}
test('wired sync routes reject malformed IDs/sequences before any database call',async()=>{
 const f=fixture(()=>{throw Error('must not query');});
 for(const [method,url,request]of [
  ['post','/sync/register-device',{body:{deviceId:'invalid'}}],
  ['post','/sync/push',{body:{deviceId:'invalid',changes:[]}}],
  ['get','/sync/pull',{query:{deviceId:device,since:'1.2'}}],
  ['get','/sync/pull',{query:{deviceId:[device]}}],
  ['post','/sync/ack',{body:{deviceId:device,serverSeq:0.1}}],
  ['post','/sync/conflicts/:id/acknowledge',{params:{id:'invalid'}}],
 ])assert.equal((await f.invoke(method,url,request)).code,400);
 assert.equal(f.calls.length,0);
});
test('registration defaults and stale-device ID still reach the original RPC',async()=>{
 const f=fixture(async()=>({rows:[{device_id:device}]}));
 assert.equal((await f.invoke('post','/sync/register-device',{body:null})).code,201);
 assert.deepEqual(f.calls[0].args,[user,'web',null,null,null]);
 const response=await f.invoke('post','/sync/register-device',{body:{platform:'old-client-platform',deviceId:device,label:'PandaPay',appVersion:'1.0.5+40'}});
 assert.equal(response.body.deviceId,device);assert.deepEqual(f.calls[1].args,[user,'old-client-platform','PandaPay','1.0.5+40',device]);
});
test('push preserves ordered per-item outcomes and never returns SQL error contents',async()=>{
 const f=fixture(async(sql,args)=>{
  if(sql.startsWith('SELECT out_applied')){
   if(JSON.parse(args[5]).note==='reject')throw Object.assign(Error('private SQL customer@example.invalid'),{code:'23505',detail:'private reference'});
   return{rows:[{out_applied:true,out_conflicts:0,out_reason:'applied'}]};
  }
  return{rows:[]};
 });
 const change=(clientSeq,note)=>({entity:'transactions',entityId,op:'update',payload:{note},fieldClocks:{note:1000},clientSeq});
 const response=await f.invoke('post','/sync/push',{body:{deviceId:device,changes:[change(1,'first'),null,change(2,'reject'),change(3,'last')]}});
 assert.equal(response.code,200);assert.equal(response.body.appliedCount,2);
 assert.deepEqual(response.body.results.map(r=>[r.clientSeq,r.applied,r.reason]),[[1,true,'applied'],[null,false,'malformed'],[2,false,'rejected'],[3,true,'applied']]);
 assert.ok(f.calls.some(c=>c.sql==='ROLLBACK TO SAVEPOINT sync_item'));
 assert.equal(f.calls.filter(c=>c.sql==='SAVEPOINT sync_item').length,3);
 assert.equal(JSON.stringify(response.body).includes('private'),false);
 assert.equal(JSON.stringify(response.body).includes('customer@example.invalid'),false);
});
test('pull and acknowledgement retain existing successful response contracts',async()=>{
 const f=fixture(async(sql)=>({rows:sql.includes('sync_pull')?[{server_seq:'7'}]:[]}));
 const response=await f.invoke('get','/sync/pull',{query:{deviceId:device,since:'0',limit:'-2'}});
 assert.deepEqual(f.calls[0].args,[user,device,0,1]);assert.equal(response.body.hasMore,true);assert.equal(response.body.latestServerSeq,7);
 const ack=await f.invoke('post','/sync/ack',{body:{deviceId:device,serverSeq:7}});assert.deepEqual(ack.body,{ok:true});
 assert.deepEqual(f.calls.at(-1).args,[user,device,7]);
});


test('status/delete cannot use raw transaction sync and later valid work continues',async()=>{
 const f=fixture(async()=>({rows:[{out_applied:true,out_conflicts:0,out_reason:null}]}));
 const change=(clientSeq,op,payload)=>({entity:'transactions',entityId,op,payload,fieldClocks:{},clientSeq});
 const response=await f.invoke('post','/sync/push',{body:{deviceId:device,changes:[change(1,'update',{status:'ignored'}),change(2,'delete',{}),change(3,'update',{note:'valid'})]}});
 assert.deepEqual(response.body.results.map(r=>[r.clientSeq,r.applied,r.reason]),[[1,false,'rejected'],[2,false,'rejected'],[3,true,null]]);
 assert.equal(f.calls.filter(c=>c.sql.startsWith('SELECT out_applied')).length,1);
 assert.equal(response.body.results[0].detail,'Use the transaction status route for status changes or deletion.');
});

test('typed activation dispatches transactions to domain applier and other entities to V2',async()=>{
 const domain=[];
 const f=fixture(async()=>({rows:[{out_applied:true,out_conflicts:0,out_reason:null}]}),{typed:true,transactionApplier:async(client,input)=>{domain.push(input);return{out_applied:true,out_conflicts:0,out_reason:null};}});
 const item=entity=>({entity,entityId,op:'update',payload:{note:'value'},fieldClocks:{note:1},clientSeq:1});
 const response=await f.invoke('post','/sync/push',{body:{deviceId:device,changes:[item('transactions'),item('card_overrides')]}});
 assert.equal(response.body.appliedCount,2);assert.equal(domain.length,1);assert.equal(domain[0].userId,user);
 const queries=f.calls.filter(c=>c.sql.startsWith('SELECT out_applied'));assert.equal(queries.length,1);assert.match(queries[0].sql,/sync_apply_change_v2/);
});
