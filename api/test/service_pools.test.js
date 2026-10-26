'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createPartnerWebhookPool, createImapWorkerPool, checkPartnerWebhookReadiness, checkImapWorkerReadiness } = require('../src/service_pools');
const {createAccountLifecyclePool,checkAccountLifecycleReadiness}=require('../src/service_pools');
const {createSharedFeedbackPool,createNotificationOutboxPool,checkNotificationCapabilityReadiness}=require('../src/service_pools');
test('new capability pools are optional, separate and small with bounded database work', () => {
  for (const create of [createSharedFeedbackPool, createNotificationOutboxPool]) {
    assert.equal(create(null), null);
    let options;
    create('synthetic', { tlsResolver: () => ({ connectionString: 'scoped', ssl: { rejectUnauthorized: true } }),
      PoolClass: class { constructor(value) { options = value; } on() {} } });
    assert.equal(options.max, 1); assert.equal(options.ssl.rejectUnauthorized, true);
    assert.ok(options.connectionTimeoutMillis <= 5000); assert.ok(options.statement_timeout <= 15000);
    if (create === createSharedFeedbackPool) assert.equal(options.statement_timeout, 1000);
  }
});
test('new capability readiness rejects elevated, broad and missing privileges', async () => {
  const valid = { bounded: true, can_execute: true, direct_table: false, can_create: false, unsafe_capability: false, unsafe_membership: false };
  for (const kind of ['feedback', 'outbox']) {
    await checkNotificationCapabilityReadiness(null, kind);
    await checkNotificationCapabilityReadiness({ query: async () => ({ rows: [valid] }) }, kind);
    for (const key of Object.keys(valid)) await assert.rejects(checkNotificationCapabilityReadiness({ query: async () => ({ rows: [{ ...valid, [key]: !valid[key] }] }) }, kind), /Unsafe/);
  }
});
test('concurrent readiness probes share one permission query and failed probes retry', async () => {
  let queries = 0; let release;
  const valid = { bounded: true, can_execute: true, direct_table: false, can_create: false, unsafe_capability: false, unsafe_membership: false };
  const pool = { query: async () => { queries++; await new Promise(r => { release = r; }); return { rows: [valid] }; } };
  const a = checkNotificationCapabilityReadiness(pool, 'feedback');
  const b = checkNotificationCapabilityReadiness(pool, 'feedback');
  assert.equal(queries, 1); release(); await Promise.all([a, b]);
  await checkNotificationCapabilityReadiness(pool, 'feedback'); assert.equal(queries, 1);
  let failures = 0; const broken = { query: async () => { failures++; throw new Error('offline'); } };
  await assert.rejects(checkNotificationCapabilityReadiness(broken, 'feedback'));
  await assert.rejects(checkNotificationCapabilityReadiness(broken, 'feedback')); assert.equal(failures, 2);
});
test('lifecycle pool is opt-in and reserves one separate bounded connection',()=>{
  assert.equal(createAccountLifecyclePool(null),null);
  let config;
  createAccountLifecyclePool('synthetic-url',{tlsResolver:()=>({connectionString:'url',ssl:{rejectUnauthorized:true}}),PoolClass:class {constructor(value){config=value;}on(){}}});
  assert.equal(config.max,1);assert.equal(config.ssl.rejectUnauthorized,true);
  assert.equal(config.application_name,'pandapay-account-lifecycle');
});
test('lifecycle readiness rejects permissions, memberships and capability drift',async()=>{
  await checkAccountLifecycleReadiness(null);
  const valid={bounded:true,can_claim:true,can_finish:true,direct_profiles:false,can_create:false,unsafe_capability:false,unsafe_membership:false};
  await checkAccountLifecycleReadiness({query:async()=>({rows:[valid]})});
  for(const key of Object.keys(valid))await assert.rejects(checkAccountLifecycleReadiness({query:async()=>({rows:[{...valid,[key]:!valid[key]}]})}),/Unsafe account lifecycle runtime/);
  await assert.rejects(checkAccountLifecycleReadiness({query:async()=>({rows:[]})}),/Unsafe account lifecycle runtime/);
});
test('missing partner database configuration never falls back to the ordinary app pool', () => {
  assert.equal(createPartnerWebhookPool(null, { PoolClass: class { constructor() { assert.fail('must not connect'); } } }), null);
});
test('separate IMAP worker pool reserves two bounded connections and never falls back to app credentials', () => {
  assert.equal(createImapWorkerPool(null),null);
  let config;
  createImapWorkerPool('synthetic-url',{tlsResolver:()=>({connectionString:'url',ssl:{rejectUnauthorized:true}}),PoolClass:class {constructor(value){config=value;}on(){}}});
  assert.equal(config.max,2);assert.equal(config.application_name,'pandapay-imap-worker');
});
test('configured partner readiness rejects broad roles or missing capability', async () => {
  await checkPartnerWebhookReadiness(null);
  const valid={bounded_role:true,can_execute:true,direct_click_read:false,direct_conversion_write:false};
  await checkPartnerWebhookReadiness({query:async()=>({rows:[valid]})});
  for(const key of Object.keys(valid)) await assert.rejects(checkPartnerWebhookReadiness({query:async()=>({rows:[{...valid,[key]:!valid[key]}]})}),/unavailable/);
});
test('configured IMAP readiness rejects broad roles, raw credential reads, or schema creation',async()=>{
  await checkImapWorkerReadiness(null);
  const valid={bounded_role:true,can_execute:true,can_defer:true,direct_credentials_read:false,schema_create:false};
  await checkImapWorkerReadiness({query:async(sql)=>{
    assert.match(sql,/imap_worker\.next_connections\(text,integer\)/);
    assert.match(sql,/imap_worker\.defer_connections\(uuid\)/);
    return {rows:[valid]};
  }});
  for(const key of Object.keys(valid)) await assert.rejects(checkImapWorkerReadiness({query:async()=>({rows:[{...valid,[key]:!valid[key]}]})}),/unavailable/);
});
test('IMAP readiness can borrow a connection while the poll session holds its advisory lock', async () => {
  const valid={bounded_role:true,can_execute:true,can_defer:true,direct_credentials_read:false,schema_create:false};
  class BoundedPool {
    constructor(config) { this.max=config.max; this.borrowed=0; }
    on() {}
    async connect() {
      if (this.borrowed >= this.max) throw new Error('connection acquisition timed out');
      this.borrowed++;
      return {release:()=>{this.borrowed--;}};
    }
    async query() {
      const client=await this.connect();
      try { return {rows:[valid]}; }
      finally { client.release(); }
    }
  }
  const pool=createImapWorkerPool('synthetic-url',{
    tlsResolver:()=>({connectionString:'url',ssl:{rejectUnauthorized:true}}),PoolClass:BoundedPool,
  });
  const pollClient=await pool.connect();
  try {
    await checkImapWorkerReadiness(pool);
    assert.equal(pool.borrowed,1,'readiness releases only its own connection');
    assert.equal(pool.max,2);
  } finally {pollClient.release();}
  assert.equal(pool.borrowed,0);
});
test('separate partner service pool has verified TLS and two bounded connections', () => {
  const calls = []; let onError;
  const pool = createPartnerWebhookPool('synthetic-url', {
    tlsResolver: url => { assert.equal(url,'synthetic-url'); return {connectionString:'sanitized-url',ssl:{rejectUnauthorized:true}}; },
    PoolClass: class { constructor(options) { calls.push(options); } on(event,handler) { assert.equal(event,'error'); onError=handler; } },
    logger: {error: (...args) => calls.push(args)},
  });
  assert.ok(pool); assert.equal(calls[0].max,2); assert.equal(calls[0].statement_timeout,15000);
  assert.equal(calls[0].ssl.rejectUnauthorized,true);
  onError(new Error('private connection details'));
  assert.equal(JSON.stringify(calls[1]).includes('private'),false);
});
