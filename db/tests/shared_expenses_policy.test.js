'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const policy=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../security/product-runtime-privileges.json'),'utf8'));
const publicCommands=[
  'shared_expenses.capabilities()',
  'shared_expenses.create_context(uuid,text,text,uuid,text)',
  'shared_expenses.respond_membership(uuid,uuid,boolean,uuid,text)',
  'shared_expenses.inspect_source(jsonb)',
  'shared_expenses.admit_source(jsonb)',
  'shared_expenses.submit_proposal(jsonb,uuid,text)',
  'shared_expenses.respond_expense(jsonb,uuid,text)',
  'shared_expenses.report_settlement(jsonb,uuid,text)',
  'shared_expenses.respond_settlement(jsonb,uuid,text)',
];
test('runtime audit inventories shared schema and cannot classify its owner as runtime',()=>{
  assert.ok(policy.managedSchemas.includes('shared_expenses'));
  assert.deepEqual(policy.roles.find(role=>role.name==='shared_expenses_owner'),{name:'shared_expenses_owner',kind:'owner',required:false});
});
test('only explicit authenticated shared commands are required and exposure roles remain forbidden',()=>{
  for(const identity of publicCommands) {
    assert.ok(policy.requiredRoutineAccess.some(row=>row.role==='app_user'&&row.identity===identity),identity);
    for(const role of ['anon','authenticated']) {
      assert.ok(policy.forbiddenRoutineAccess.some(row=>row.role===role&&row.identity===identity),`${role}:${identity}`);
    }
  }
  assert.ok(!policy.requiredRoutineAccess.some(row=>row.identity.startsWith('shared_expenses._post')));
  assert.ok(!policy.memberships.some(row=>row.role==='shared_expenses_owner'));
});
