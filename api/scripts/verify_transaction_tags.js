// Local-only HTTP smoke check. Synthetic account is removed in finally.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('pg');
const jwt = require('jsonwebtoken');
async function main() {
  const base = process.env.PANDAPAY_TAGS_TEST_API || 'http://127.0.0.1:4000';
  const url = new URL(base);
  const database = process.env.PANDAPAY_TAGS_TEST_DATABASE_URL;
  if (!['127.0.0.1','localhost'].includes(url.hostname) || !database || !['127.0.0.1','localhost'].includes(new URL(database).hostname)) throw Error('Use explicit local test API and database URLs.');
  const profile=crypto.randomUUID();
  const db=new Client({connectionString:database}); await db.connect();
  const token=jwt.sign({},process.env.PANDAPAY_TAGS_TEST_JWT_SECRET || 'dev_access_secret_change_me',{
    subject:profile,issuer:'pandapay-auth',audience:'mobile-app',expiresIn:300,
  });
  const request=async(path,body)=>{
    const response=await fetch(`${base}${path}`,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
    const raw=await response.text();
    assert.ok(response.ok,`${path}: ${response.status} ${raw}`);
    return response.headers.get('content-type')?.includes('json')?JSON.parse(raw):raw;
  };
  try {
    await db.query('INSERT INTO profiles(id,display_name) VALUES($1,$2)',[profile,'Temporary tags HTTP verification']);
    const trip=crypto.randomUUID(); const office=crypto.randomUUID();
    const op=async(operation,fields)=>request('/transaction-tags/changes',{mutationId:crypto.randomUUID(),operation,updatedAt:new Date().toISOString(),...fields});
    for (const [tag,name] of [[trip,'Thailand trip'],[office,'Office']]) await op('upsert_tag',{tag:{id:tag,name}});
    const transactions=[];
    for (const [name,amount] of [['Cafe',500],['Taxi',1000],['Shop',250]]) {
      const value=await request('/transactions',{amountInr:amount,instrument:'cash',entryKind:'spend',merchantName:`TAG HTTP QA ${name}`,
        occurredAt:'2026-10-02T10:00:00+05:30',clientMutationId:crypto.randomUUID()});
      transactions.push(value.transaction.id);
    }
    await op('assign',{transactionId:transactions[0],tagId:trip});
    await op('assign',{transactionId:transactions[0],tagId:office});
    await op('assign',{transactionId:transactions[1],tagId:trip});
    const snapshot=await request('/transaction-tags');
    assert.equal(snapshot.tags.length,2); assert.equal(snapshot.assignments.length,3);
    const all=await request('/transactions'); assert.equal(all.transactions.length,3); assert.equal(all.transactions.find((t)=>t.id===transactions[0]).tags.length,2);
    const query=`period=custom&from=2026-10-01&to=2026-10-31&tagIds=${trip},${office}`;
    const report=await request(`/spend-report?${query}`);
    assert.equal(report.totals.spend.totalInr,1500); assert.equal(report.totals.spend.txnCount,2);
    assert.equal(report.byCategory.reduce((sum,row)=>sum+row.totalInr,0),1500);
    assert.equal((await request('/spend-report?period=custom&from=2026-10-01&to=2026-10-31&untagged=true')).totals.spend.totalInr,250);
    await request('/budgets',{scope:'tag',scopeRefId:trip,period:'monthly',amountInr:2000});
    const budget=(await request('/budgets')).budgets[0];
    assert.equal(budget.scope,'tag'); assert.equal(budget.label,'Thailand trip');
    const exported=await request('/export?format=json');
    assert.equal(exported.tags.length,2); assert.equal(exported.transactions.find((t)=>t.id===transactions[0]).tags.length,2);
    assert.match(await request('/export/transactions.csv'),/Tags/);
    await op('unassign',{transactionId:transactions[0],tagId:office});
    assert.equal((await request(`/transactions/${transactions[0]}`)).transaction.tags.length,1);
    assert.equal(Number((await db.query('SELECT sum(amount_inr) total FROM transactions WHERE profile_id=$1',[profile])).rows[0].total),1750);
    console.log('PASS: live tag CRUD/links, transaction reads, filtered reports, tag budget, CSV/JSON exports; financial total unchanged.');
  } finally {
    await db.query('DELETE FROM profiles WHERE id=$1',[profile]);
    await db.end();
    console.log('Removed the temporary verification account and its synthetic transactions/tags.');
  }
}
main().catch((error)=>{console.error(error.message);process.exitCode=1;});
