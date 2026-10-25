'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {createReadinessHandler}=require('../src/readiness');
const response=()=>({code:200,headers:{},status(code){this.code=code;return this;},set(key,value){this.headers[key]=value;},json(value){this.body=value;return this;}});
test('readiness excludes draining processes before probes and after an in-flight dependency probe',async()=>{
 for(const initiallyDraining of [false,true]){
  let draining=initiallyDraining,calls=0;
  const handler=createReadinessHandler({isDraining:()=>draining,checkDependencies:async()=>{calls++;draining=true;}});
  const res=response();await handler({},res);
  assert.equal(res.code,503);assert.equal(res.body.database,'draining');assert.equal(calls,initiallyDraining?0:1);
  assert.equal(res.headers['Cache-Control'],'no-store');
 }
});
test('readiness preserves ready/unavailable contracts with redacted dependency errors',async()=>{
 const logs=[];const failed=createReadinessHandler({checkDependencies:async()=>{throw Error('private database credentials');},logger:{error:(...args)=>logs.push(args)}});
 const unavailable=response();await failed({},unavailable);assert.equal(unavailable.code,503);assert.doesNotMatch(JSON.stringify(logs),/private|credentials/);
 const healthy=response();await createReadinessHandler({checkDependencies:async()=>{}})({},healthy);assert.deepEqual(healthy.body,{ok:true,database:'ready'});
});
