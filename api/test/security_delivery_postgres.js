'use strict';
// Explicitly opt-in disposable fixture. Never loads .env or application config.
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Client, Pool } = require('pg');
const { checkNotificationCapabilityReadiness } = require('../src/service_pools');
async function main() {
  const value = process.env.SECURITY_DELIVERY_TEST_URL;
  if (!value) throw new Error('SECURITY_DELIVERY_TEST_URL must name the owned disposable fixture');
  const url = new URL(value);
  if (url.hostname !== '127.0.0.1' || url.pathname !== '/sync_isolation_upgrade_test') throw new Error('Only the owned loopback fixture is allowed');
  const admin = new Client({ connectionString: value, ssl: false }); await admin.connect();
  const clients = [];
  const login = async name => { const u = new URL(value);u.username=name;const c=new Client({connectionString:u.toString(),ssl:false,statement_timeout:1500});await c.connect();clients.push(c);return c; };
  const deny = async (client, sql, args = []) => { await assert.rejects(client.query(sql,args),error=>error.code==='42501'); };
  try {
    for (const [name,cap] of [['delivery_feedback_login','pandapay_feedback_admission'],['delivery_worker_login','notification_worker'],['delivery_app_login','app_user'],['delivery_monitor_login','notification_monitor']]) {
      await admin.query(`CREATE ROLE ${name} LOGIN INHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION`);
      await admin.query(`GRANT ${cap} TO ${name}`);
    }
    const feedback1=await login('delivery_feedback_login'),feedback2=await login('delivery_feedback_login');
    for (const [name,kind] of [['delivery_feedback_login','feedback'],['delivery_worker_login','outbox']]) {
      const u=new URL(value);u.username=name;const p=new Pool({connectionString:u.toString(),ssl:false,max:1,statement_timeout:1500});
      try { await checkNotificationCapabilityReadiness(p,kind); } finally { await p.end(); }
    }
    await deny(feedback1,'SELECT * FROM feedback_admission.buckets');
    await feedback1.query('BEGIN');await feedback1.query('SELECT pg_advisory_xact_lock(742019261)');
    const start=Date.now();await assert.rejects(feedback2.query('SELECT * FROM feedback_admission.consume($1,$2,true)',['support_tickets','1'.repeat(64)]),e=>e.code==='P0001');
    assert.ok(Date.now()-start<1500);await feedback1.query('ROLLBACK');
    for(let i=0;i<5;i++)assert.equal((await [feedback1,feedback2][i%2].query('SELECT * FROM feedback_admission.consume($1,$2,true)',['support_tickets','1'.repeat(64)])).rows[0].allowed,true);
    const restarted=await login('delivery_feedback_login');assert.equal((await restarted.query('SELECT * FROM feedback_admission.consume($1,$2,true)',['support_tickets','1'.repeat(64)])).rows[0].allowed,false);
    assert.equal((await admin.query('SELECT used_rows=(SELECT count(*) FROM feedback_admission.buckets) AS correct FROM feedback_admission.capacity')).rows[0].correct,true);
    // Keep this independent fixture rolled back for the preservation check.
    await admin.query('TRUNCATE feedback_admission.buckets');await admin.query('UPDATE feedback_admission.capacity SET used_rows=0');
    const a=randomUUID(),b=randomUUID(),n1=randomUUID(),n2=randomUUID();
    await admin.query('INSERT INTO profiles(id) VALUES ($1),($2)',[a,b]);
    await admin.query("INSERT INTO notification_preferences(profile_id) VALUES ($1)",[a]);
    await admin.query("INSERT INTO notifications(id,profile_id,category,title) VALUES ($1,$2,'transactions','First'),($3,$4,'caps','Other')",[n1,a,n2,b]);
    const app=await login('delivery_app_login');
    await deny(app,'SELECT notification_delivery.enqueue($1)',[n1]);
    await app.query("SELECT set_config('app.user_id',$1,false)",[a]);
    await deny(app,'SELECT notification_delivery.enqueue($1)',[n2]);
    await app.query('SELECT notification_delivery.enqueue($1)',[n1]);
    await app.query('SELECT notification_delivery.enqueue($1)',[n1]);
    assert.equal((await admin.query('SELECT count(*)::integer AS n FROM notification_delivery.outbox')).rows[0].n,1);
    const worker1=await login('delivery_worker_login'),worker2=await login('delivery_worker_login');
    await worker1.query("SELECT notification_delivery.report_worker_status('integration-worker',true,false,0,0,0,null)");
    const monitor=await login('delivery_monitor_login');
    await deny(monitor,'SELECT * FROM notification_delivery.revisions');
    const health=(await monitor.query('SELECT notification_delivery.health() AS h')).rows[0].h;
    assert.equal(health.queued,1);assert.equal(health.retained,1);assert.equal(health.missing_worker,false);
    assert.equal(Object.keys(health).length,14);
    const {probe}=require('../../db/scripts/notification_delivery_health');
    const monitorUrl=new URL(value);monitorUrl.username='delivery_monitor_login';
    const output=[];const probeEnv={NOTIFICATION_MONITOR_DATABASE_URL:monitorUrl.toString(),DB_SSL:'false',NODE_ENV:'test'};
    assert.equal(await probe({env:probeEnv,write:v=>output.push(v)}),0);assert.equal(JSON.parse(output[0]).health.queued,1);
    await admin.query('GRANT SELECT ON notification_delivery.profile_queue_counts TO delivery_monitor_login');
    await assert.rejects(probe({env:probeEnv,write:()=>assert.fail('unsafe monitor cannot emit')}),/Unsafe/);
    await admin.query('REVOKE SELECT ON notification_delivery.profile_queue_counts FROM delivery_monitor_login');
    await worker1.query("SELECT notification_delivery.report_worker_status('integration-worker',false,false,0,0,0,'notification_worker_stopped')");
    assert.equal((await monitor.query('SELECT notification_delivery.health() AS h')).rows[0].h.missing_worker,true);


    await deny(worker1,'SELECT * FROM notification_delivery.revisions');
    await worker1.query('BEGIN');const claimed=(await worker1.query("SELECT * FROM notification_delivery.claim('first',1,90)")).rows[0];assert.ok(claimed);
    const other=(await worker2.query("SELECT * FROM notification_delivery.claim('second',1,90)")).rows;assert.equal(other.length,0);
    await worker1.query('COMMIT');
    await admin.query("UPDATE notification_delivery.outbox SET lease_until=now()-interval '1 second' WHERE id=$1",[claimed.id]);
    assert.equal((await worker1.query('SELECT notification_delivery.allowed($1,$2) AS allowed',[claimed.id,claimed.lease_token])).rows[0].allowed,false);
    assert.equal((await worker1.query('SELECT notification_delivery.finish($1,$2,true,null,false) AS r',[claimed.id,claimed.lease_token])).rows[0].r.accepted,false);
    const reclaimed=(await worker2.query("SELECT * FROM notification_delivery.claim('second',1,90)")).rows[0];assert.equal(reclaimed.id,claimed.id);assert.notEqual(reclaimed.lease_token,claimed.lease_token);
    await admin.query('UPDATE notification_preferences SET category_transactions=false WHERE profile_id=$1',[a]);
    assert.equal((await worker2.query('SELECT notification_delivery.allowed($1,$2) AS allowed',[reclaimed.id,reclaimed.lease_token])).rows[0].allowed,false);
    await admin.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])',[[a,b]]);
    assert.deepEqual((await admin.query('SELECT pending,retained FROM notification_delivery.global_queue_count')).rows,[{pending:0,retained:0}]);
    console.log('PASS: independent LOGIN least privilege; cross-session fail-closed contention; shared/restart quotas; anonymous/wrong-profile enqueue denied; dedupe; SKIP LOCKED; expiry/token fencing; latest transaction preference; cascade counters');
  } finally { await Promise.allSettled(clients.map(c=>c.end()));await admin.end(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
