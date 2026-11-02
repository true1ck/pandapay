// Opt-in disposable loopback fixture. Never consumes API_DATABASE_URL.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {Pool}=require('pg');
const payments=require('../src/foreign_payments');
const owner='11111111-1111-4111-8111-111111111111';
const other='22222222-2222-4222-8222-222222222222';
const card='33333333-3333-4333-8333-333333333333';
const hash=(value)=>crypto.createHash('sha256').update(value).digest('hex');

test('real PostgreSQL migration, owner isolation, estimates, atomic confirmation, reconciliation, refunds and ledger edits', {skip:!process.env.PANDAPAY_FX_FIXTURE_URL},async()=>{
  const url=new URL(process.env.PANDAPAY_FX_FIXTURE_URL);
  assert.ok(['localhost','127.0.0.1','::1'].includes(url.hostname));
  assert.match(url.pathname,/_fx_test$/);
  const pool=new Pool({connectionString:url.toString(),ssl:false});
  const admin=await pool.connect();
  const within=async(user,fn)=>{
    const client=await pool.connect();
    try{await client.query('BEGIN');await client.query('SET LOCAL ROLE app_user');await client.query("SELECT set_config('app.user_id',$1,true)",[user]);const result=await fn(client);await client.query('COMMIT');return result;}
    catch(error){await client.query('ROLLBACK');throw error;}finally{client.release();}
  };
  try{
    await admin.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public; DROP SCHEMA IF EXISTS pandapay CASCADE;');
    await admin.query(`CREATE SCHEMA IF NOT EXISTS pandapay;
      DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='app_user') THEN CREATE ROLE app_user NOLOGIN; END IF; END $$;
      CREATE OR REPLACE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$;
      GRANT USAGE ON SCHEMA public,pandapay TO app_user;
      CREATE TABLE profiles(id uuid PRIMARY KEY);
      CREATE TABLE card_products(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),card_type text);
      CREATE TABLE user_cards(id uuid PRIMARY KEY,profile_id uuid REFERENCES profiles(id),last4 text,card_product_id uuid);
      CREATE TABLE spend_categories(id uuid PRIMARY KEY,name text);
      CREATE TABLE user_categories(id uuid PRIMARY KEY,profile_id uuid REFERENCES profiles(id),name text,archived_at timestamptz);
      CREATE TABLE transactions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),profile_id uuid NOT NULL REFERENCES profiles(id),
        user_card_id uuid,amount_inr numeric(12,2) NOT NULL,occurred_at timestamptz NOT NULL,category_id uuid,user_category_id uuid,
        merchant_name text,rail text,instrument text,entry_kind text,status text DEFAULT 'active',source text,source_key text,
        source_account_last4 text,note text,state_applied boolean DEFAULT false,updated_at timestamptz DEFAULT now(),
        UNIQUE(profile_id,id),UNIQUE(profile_id,source_key));
      CREATE TABLE transaction_observations(id uuid DEFAULT gen_random_uuid(),profile_id uuid,transaction_id uuid,source_key text,external_ref text,metadata jsonb DEFAULT '{}');
      GRANT SELECT,INSERT,UPDATE,DELETE ON profiles,user_cards,card_products,spend_categories,user_categories,transactions,transaction_observations TO app_user;
      INSERT INTO profiles VALUES('${owner}'),('${other}');
      INSERT INTO card_products(card_type) VALUES('credit');
      INSERT INTO user_cards SELECT '${card}','${owner}','1234',id FROM card_products;`);
    const migration=fs.readFileSync(path.resolve(__dirname,'../../db/supabase/migrations/20261102100000_foreign_payments.sql'),'utf8');
    await admin.query('BEGIN');await admin.query(migration);await admin.query('COMMIT');
    await admin.query('BEGIN');await admin.query(migration);await admin.query('COMMIT');
    const base={source_key:hash('one'),original_currency:'USD',original_amount:'20',occurred_at:'2026-03-05T12:00:00Z',merchant_name:'Synthetic Subscription',user_card_id:card,card_last4:'1234'};
    let pending=await within(owner,c=>payments.upsertForeignPayment(c,owner,base,{referenceRate:{rate:'85',rate_date:'2026-03-05',rate_source:'Fixture'}}));
    assert.equal(pending.valuation_status,'estimated');assert.equal(pending.estimated_inr,'1700.00');
    assert.equal((await admin.query('SELECT count(*) FROM transactions')).rows[0].count,'0');
    assert.equal(await within(other,c=>payments.loadPayment(c,other,pending.id)),null);
    assert.equal((await within(other,c=>c.query('SELECT * FROM foreign_payments'))).rows.length,0,'RLS hides other account records even without a WHERE clause');
    await assert.rejects(within(other,c=>c.query('UPDATE foreign_payments SET profile_id=$1 WHERE id=$2 RETURNING *',[other,pending.id])).then(r=>{assert.equal(r.rows.length,0);throw Error('no cross-owner mutation');}),/no cross-owner mutation/);
    pending=await within(owner,c=>payments.patchForeignPayment(c,owner,pending.id,{original_amount:'21'},{referenceRate:{rate:'85',rate_date:'2026-03-05',rate_source:'Fixture'}}));
    assert.equal(pending.original_amount,'21.0000');
    const replay=await within(owner,c=>payments.upsertForeignPayment(c,owner,base));assert.equal(replay.original_amount,'21.0000');
    const insertWriter=async(client,user,input)=>{
      const r=await client.query(`INSERT INTO transactions(profile_id,user_card_id,amount_inr,occurred_at,merchant_name,source,source_key,instrument,entry_kind,status)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'active') ON CONFLICT(profile_id,source_key) DO UPDATE SET source_key=EXCLUDED.source_key RETURNING *`,
      [user,input.userCardId,input.amount,input.occurred,input.merchantName,input.source,input.sourceKey,input.instrument,input.entryKind]);
      return {status:201,transaction:r.rows[0]};
    };
    const confirmations=await Promise.all([1,2].map(()=>within(owner,c=>payments.confirmForeignPayment(c,owner,pending.id,{billed_inr:'1800',confirmation_source:'user'},{insertTransactionAndUpdateState:insertWriter}))));
    assert.equal(confirmations[0].transaction_id,confirmations[1].transaction_id);
    assert.equal((await admin.query('SELECT count(*) FROM transactions')).rows[0].count,'1');
    await assert.rejects(within(owner,c=>payments.confirmForeignPayment(c,owner,pending.id,{billed_inr:'1900'},{insertTransactionAndUpdateState:insertWriter})),/confirmation_conflict/);
    await within(owner,c=>c.query('UPDATE transactions SET amount_inr=1850 WHERE profile_id=$1 AND id=$2',[owner,confirmations[0].transaction_id]));
    assert.equal((await within(owner,c=>payments.loadPayment(c,owner,pending.id))).billed_inr,'1850.00','later ledger corrections update the original-currency view');
    await within(owner,c=>c.query("UPDATE transactions SET status='ignored' WHERE profile_id=$1 AND id=$2",[owner,confirmations[0].transaction_id]));
    assert.equal((await within(owner,c=>payments.loadPayment(c,owner,pending.id))).valuation_status,'ignored');
    await within(owner,c=>c.query("UPDATE transactions SET status='active' WHERE profile_id=$1 AND id=$2",[owner,confirmations[0].transaction_id]));
    const next=await within(owner,c=>payments.upsertForeignPayment(c,owner,{...base,source_key:hash('next'),reference:'ABC123456'}));
    const statement=await within(owner,async c=>{
      const t=(await c.query(`INSERT INTO transactions(profile_id,user_card_id,amount_inr,occurred_at,source,source_key,instrument,entry_kind,status)
        VALUES($1,$2,1742,'2026-03-06','statement',$3,'credit_card','spend','active') RETURNING *`,[owner,card,hash('statement')])).rows[0];
      return payments.reconcileStatementForeignPayment(c,owner,{transactionId:t.id,sourceKey:t.source_key,billedInr:'1742',occurredAt:t.occurred_at,userCardId:card,bankReference:'ABC123456',entryKind:'spend'});
    });
    assert.equal(statement.id,next.id);assert.equal(statement.valuation_status,'confirmed');
    const refund=await within(owner,c=>payments.upsertForeignPayment(c,owner,{...base,source_key:hash('refund'),original_amount:'5',direction:'refund',refund_of_id:pending.id}));
    const credited=await within(owner,c=>payments.confirmForeignPayment(c,owner,refund.id,{billed_inr:'420'},{insertTransactionAndUpdateState:insertWriter}));
    assert.equal((await admin.query('SELECT entry_kind FROM transactions WHERE id=$1',[credited.transaction_id])).rows[0].entry_kind,'transfer');
    const rollback=await within(owner,c=>payments.upsertForeignPayment(c,owner,{...base,source_key:hash('rollback')}));
    const countBefore=(await admin.query('SELECT count(*) FROM transactions')).rows[0].count;
    await assert.rejects(within(owner,c=>payments.confirmForeignPayment(c,owner,rollback.id,{billed_inr:'1000'},{insertTransactionAndUpdateState:async(client,user,input)=>{await insertWriter(client,user,input);throw Error('synthetic failure');}})),/synthetic failure/);
    assert.equal((await admin.query('SELECT count(*) FROM transactions')).rows[0].count,countBefore,'canonical insert and FX confirmation roll back together');
    assert.notEqual((await within(owner,c=>payments.loadPayment(c,owner,rollback.id))).valuation_status,'confirmed');
  }finally{admin.release();await pool.end();}
});
