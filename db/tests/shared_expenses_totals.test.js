'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {transactionalSql}=require('../scripts/product_migrate');
test('totals projection is additive, isolated and only follows accepted-head changes',()=>{
  const sql=fs.readFileSync(path.resolve(__dirname,'../supabase/migrations/20261112213000_shared_expense_totals.sql'),'utf8');
  assert.doesNotThrow(()=>transactionalSql(sql));
  assert.match(sql,/AFTER UPDATE OF accepted_revision_id/);
  assert.match(sql,/FORCE ROW LEVEL SECURITY/);
  assert.match(sql,/REVOKE ALL ON FUNCTION shared_expenses\._update_totals/);
  assert.doesNotMatch(sql,/ALTER TABLE (?:public\.)?(?:transactions|transaction_splits)\b/);
});
