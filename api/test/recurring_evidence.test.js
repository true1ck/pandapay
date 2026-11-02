const test=require('node:test');
const assert=require('node:assert/strict');
const {filterCurrentRecurringRows}=require('../src/recurring_evidence');
test('ignored erroneous expenses cannot keep a stale detected subscription alive',()=>{
  const rows=[{merchant_key:'bad',detection_source:'observed'},{merchant_key:'good',detection_source:'observed'},{merchant_key:'reviewed',detection_source:'observed',user_edited:true},{merchant_key:'manual',detection_source:'manual'},{merchant_key:'mandate',detection_source:'mandate'}];
  assert.deepEqual(filterCurrentRecurringRows(rows,[{merchantKey:'good'}]).map(r=>r.merchant_key),['good','reviewed','manual','mandate']);
});
