'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {MemoryStore}=require('../../src/sms_v2/rules_store');
const {listRules,ruleDetail}=require('../../src/sms_v2/rules_admin_route');
test('console metadata and daily history distinguish 7-day and 30-day totals',async()=>{
 const store=new MemoryStore();
 store.state.rules=[{ruleId:'R-1',version:1,status:'active',family:'bank_debit',senders:['TESTBK'],createdBy:'reviewer',body:{createdBy:'baseline',updatedAt:'2026-11-20T00:00:00Z',emit:[{factType:'movement'}],examples:[{body:'SYNTHETIC',expectFactTypes:['movement']}]}}];
 store.state.daily=[{day:'2026-11-19',ruleId:'R-1',version:1,hits:10,toReview:1,corrected:1,devices:2},{day:'2026-11-01',ruleId:'R-1',version:1,hits:90,toReview:4,corrected:2,devices:3}];
 const now=new Date('2026-11-20T00:00:00Z');
 const rows=await store.tx('admin',tx=>listRules(tx,{},now));
 assert.deepEqual(rows[0].factTypes,['movement']);assert.equal(rows[0].positiveExample,'SYNTHETIC');
 assert.equal(rows[0].changedBy,'reviewer');assert.equal(rows[0].metrics7d.hits,10);
 const detail=await store.tx('admin',tx=>ruleDetail(tx,'R-1',now));
 assert.equal(detail.versions[0].metrics30d.hits,100);assert.equal(detail.versions[0].dailyMetrics.length,2);
});
