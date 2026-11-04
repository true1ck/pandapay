'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {canonicalJson,commandHash}=require('../src/shared_expenses/canonical');
const vectors=require('../../contracts/shared_expenses/v1/command_vectors.json');
for(const vector of vectors.cases)test('shared canonical fixture: '+vector.id,()=>{
  assert.equal(canonicalJson(vector.input),vector.canonical);
  assert.equal(commandHash(vector.input),vector.sha256);
});
test('canonical JSON sorts keys and retains array order and exact monetary strings',()=>{
  assert.equal(canonicalJson({z:['10','2'],a:{b:'₹100.01',a:1}}),' {"a":{"a":1,"b":"₹100.01"},"z":["10","2"]}'.trim());
  assert.equal(commandHash({b:2,a:1}),commandHash({a:1,b:2}));
  assert.notEqual(commandHash({a:['1','2']}),commandHash({a:['2','1']}));
});
test('reject non-JSON/coerced numbers, Unicode corruption and prototype hooks',()=>{
  for(const value of [NaN,Infinity,1.5,Number.MAX_SAFE_INTEGER+1,-0,undefined,1n,()=>1,Symbol('x'),new Date(),{x:undefined},['\ud800'],['\udc00']]) {
    assert.throws(()=>canonicalJson(value),{code:'INVALID_INPUT'});
  }
  assert.throws(()=>canonicalJson(Object.create({secret:'private'})),{code:'INVALID_INPUT'});
  const cyclic={};cyclic.self=cyclic;
  assert.throws(()=>canonicalJson(cyclic),{code:'INVALID_INPUT'});
  assert.throws(()=>canonicalJson({'title\n':'private'}),{code:'INVALID_INPUT'});
});
test('bounded serialization rejects byte, depth, collection and node overflow',()=>{
  assert.throws(()=>canonicalJson({text:'x'.repeat(65536)}),{code:'PAYLOAD_TOO_LARGE'});
  let deep={};for(let i=0;i<17;i++)deep={next:deep};
  assert.throws(()=>canonicalJson(deep),{code:'INVALID_INPUT'});
  assert.throws(()=>canonicalJson(Array(1001).fill(0)),{code:'INVALID_INPUT'});
});
test('canonicalization never runs an array accessor supplied by an in-process caller',()=>{
  let called=false;const input=[];
  Object.defineProperty(input,'0',{enumerable:true,get:()=>{called=true;throw new Error('private');}});
  assert.throws(()=>canonicalJson(input),{code:'INVALID_INPUT'});
  assert.equal(called,false);
});
