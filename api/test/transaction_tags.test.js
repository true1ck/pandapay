const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('pg');
const { validateChange, readTagFilter, tagQueryClient, applyChange, mergeTransactionTags, attachTags, importTagNames } = require('../src/transaction_tags');
const reports = require('../src/spend_reports');
const id = () => crypto.randomUUID();

test('tag filters validate IDs and never interpolate user input', async () => {
  assert.throws(() => readTagFilter({ tagIds: "'); drop table transactions;--" }), /Invalid/);
  const tag = id();
  const filter = readTagFilter({ tagIds: `${tag},${tag}` });
  assert.deepEqual(filter.tagIds, [tag]);
  let sql; let params;
  const client = tagQueryClient({ query: async (s,p) => { sql=s; params=p; return { rows:[] }; } }, id(), filter);
  await client.query('WITH rows AS (SELECT * FROM transactions t WHERE t.profile_id=$1) SELECT * FROM rows', ['account']);
  assert.match(sql, /WITH __tagged_transactions AS/);
  assert.match(sql, /EXISTS/);
  assert.ok(!sql.includes(tag));
  assert.deepEqual(params[2], [tag]);
});
test('invalid definitions, future clocks and malformed operations are rejected', () => {
  const base = { mutationId:id(),operation:'upsert_tag',updatedAt:new Date().toISOString(),tag:{id:id(),name:'Office'} };
  assert.doesNotThrow(()=>validateChange(base));
  assert.throws(()=>validateChange({...base,tag:{...base.tag,name:' '}}));
  assert.throws(()=>validateChange({...base,tag:{...base.tag,color:'red'}}));
  assert.throws(()=>validateChange({...base,updatedAt:'2100-01-01'}));
  assert.throws(()=>validateChange({...base,operation:'delete_everything'}));
});

test('real database: overlap counts once, stale removals, replay, budgets, aliases and isolation',
  { skip: !process.env.PANDAPAY_TAGS_TEST_DATABASE_URL }, async () => {
    const client=new Client({connectionString:process.env.PANDAPAY_TAGS_TEST_DATABASE_URL});
    await client.connect(); await client.query('BEGIN');
    try {
      const profile=id(); const other=id(); const trip=id(); const office=id(); const one=id(); const two=id(); const three=id();
      await client.query('INSERT INTO profiles(id) VALUES($1),($2)',[profile,other]);
      await client.query("SELECT set_config('app.user_id',$1,true)",[profile]);
      const now=new Date();
      const at=new Date(now.getTime()-60000).toISOString();
      const later=new Date(now.getTime()-30000).toISOString();
      const change=(operation,fields,time=at)=>({mutationId:id(),operation,updatedAt:time,...fields});
      for(const [tag,name] of [[trip,'Thailand trip'],[office,'Office']]) await applyChange(client,profile,change('upsert_tag',{tag:{id:tag,name}}));
      for(const [transaction,amount] of [[one,500],[two,1000],[three,250]]) {
        await client.query("INSERT INTO transactions(id,profile_id,amount_inr,occurred_at,instrument,entry_kind,source,status) VALUES($1,$2,$3,now(),'cash','spend','manual','active')",[transaction,profile,amount]);
      }
      const assign=change('assign',{transactionId:one,tagId:trip});
      await applyChange(client,profile,assign); await applyChange(client,profile,assign);
      const clientMutation=id();
      const sourceKey=crypto.createHash('sha256').update(`${profile}\0manual\0client-mutation\0${clientMutation}`).digest('hex');
      await client.query('UPDATE transactions SET source_key=$1 WHERE id=$2',[sourceKey,one]);
      await applyChange(client,profile,change('assign',{transactionId:`local-outbox:${clientMutation}`,tagId:trip}));
      await applyChange(client,profile,change('assign',{transactionId:one,tagId:office}));
      await applyChange(client,profile,change('assign',{transactionId:two,tagId:trip}));
      const bounds={start:new Date(now.getTime()-86400000),end:new Date(now.getTime()+86400000)};
      const both=tagQueryClient(client,profile,{tagIds:[trip,office],untagged:false});
      const totals=await reports.periodTotals(both,profile,bounds);
      assert.equal(totals.spend.totalInr,1500);
      assert.equal(totals.spend.txnCount,2);
      assert.equal((await reports.periodTotals(tagQueryClient(client,profile,{tagIds:[],untagged:true}),profile,bounds)).spend.totalInr,250);
      assert.equal((await reports.budgetSpend(client,profile,{scope:'tag',scope_ref_id:trip},bounds)).spentInr,1500);
      await applyChange(client,profile,change('unassign',{transactionId:one,tagId:office},later));
      await applyChange(client,profile,change('assign',{transactionId:one,tagId:office},at));
      assert.equal((await attachTags(client,profile,[{id:one}]))[0].tags.length,1);
      await importTagNames(client,profile,three,['Office','Office']);
      await mergeTransactionTags(client,profile,three,one);
      await applyChange(client,profile,change('assign',{transactionId:three,tagId:trip},later));
      assert.equal((await attachTags(client,profile,[{id:one}]))[0].tags.length,2);
      assert.equal(Number((await client.query('SELECT count(*) n FROM transaction_tag_links WHERE profile_id=$1 AND transaction_id=$2 AND tag_id=$3',[profile,one,trip])).rows[0].n),1);
      await client.query('SAVEPOINT denied');
      await assert.rejects(()=>applyChange(client,other,change('assign',{transactionId:one,tagId:trip})),/not found/);
      await client.query('ROLLBACK TO SAVEPOINT denied');
      await client.query("SELECT set_config('app.user_id',$1,true)",[other]);
      // Explicit ownership guard is also tested as a database owner, which
      // bypasses RLS; production additionally has forced owner policies.
      assert.equal((await attachTags(client,other,[{id:one}]))[0].tags.length,0);
      const unchanged=await client.query('SELECT amount_inr,state_applied FROM transactions WHERE id=$1',[one]);
      assert.equal(Number(unchanged.rows[0].amount_inr),500);
      assert.equal(unchanged.rows[0].state_applied,false);
    } finally { await client.query('ROLLBACK'); await client.end(); }
});
