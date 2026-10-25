'use strict';

// Separate LOGINs, synthetic rows and an explicitly owned loopback database.
// Seed is an operator-only fixture setup. Verify rolls every request back.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('pg');
const identities = [
  'pandapay.register_sync_device(uuid,text,text,text,uuid)',
  'pandapay.sync_apply_change(uuid,uuid,text,uuid,public.sync_op,jsonb,jsonb,bigint)',
  'pandapay.sync_pull(uuid,uuid,bigint,integer)',
  'pandapay.sync_ack(uuid,uuid,bigint)',
  'pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,jsonb,bigint)',
  'pandapay.sync_insert_user_category(uuid,uuid,uuid,text,text,uuid,uuid,text[],jsonb,bigint)',
  'pandapay.sync_apply_user_merchant_category_rule(uuid,uuid,uuid,public.sync_op,jsonb,bigint)',
];
const ids = { alice: '11111111-1111-4111-8111-111111111111', bob: '22222222-2222-4222-8222-222222222222',
  deviceA: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', deviceB: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  txnA: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', txnB: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  categoryA: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', categoryB: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
  ruleA: '33333333-3333-4333-8333-333333333333', ruleB: '44444444-4444-4444-8444-444444444444',
  flagRule: '66666666-6666-4666-8666-666666666666',
  spendCategory: '55555555-5555-4555-8555-555555555555' };
const tables = ['profiles', 'user_devices', 'transactions', 'change_log', 'sync_cursors', 'sync_conflicts', 'user_categories', 'user_merchant_category_rules'];
function fixtureUrl() {
  const raw = process.env.PANDAPAY_SYNC_ISOLATION_TEST_URL;
  if (!raw) throw new Error('Explicit synthetic fixture URL required');
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      !['/sync_isolation_upgrade_test', '/sync_transport_test'].includes(url.pathname) || !url.username || !url.password || url.search || url.hash) throw new Error('Owned loopback fixture required');
  return url;
}
async function fingerprint(client) {
  const result = {};
  for (const table of tables) {
    const rows = await client.query(`SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text AS value FROM public.${table} t`);
    result[table] = crypto.createHash('sha256').update(rows.rows[0].value).digest('hex');
  }
  return result;
}
async function seed(admin) {
  assert.equal(Number((await admin.query('SELECT count(*) FROM public.profiles')).rows[0].count), 0);
  await admin.query('BEGIN');
  try {
    await admin.query('INSERT INTO public.profiles(id) VALUES($1),($2)', [ids.alice, ids.bob]);
    await admin.query("INSERT INTO public.user_devices(id,profile_id,platform) VALUES($1,$2,'web'),($3,$4,'web')", [ids.deviceA, ids.alice, ids.deviceB, ids.bob]);
    for (const [txn, profile, device, note] of [[ids.txnA, ids.alice, ids.deviceA, 'alice original'], [ids.txnB, ids.bob, ids.deviceB, 'bob original']]) {
      await admin.query("INSERT INTO public.transactions(id,profile_id,amount_inr,occurred_at,instrument,entry_kind,source,status,note) VALUES($1,$2,1000,'2026-10-01T10:00:00Z','cash','spend','manual','active',$3)", [txn, profile, note]);
      await admin.query("INSERT INTO public.change_log(profile_id,device_id,entity,entity_id,op,payload,client_seq) VALUES($1,$2,'transactions',$3,'update',jsonb_build_object('note',$4::text),0)", [profile, device, txn, note]);
      await admin.query('INSERT INTO public.sync_cursors(device_id,profile_id) VALUES($1,$2)', [device, profile]);
    }
    await admin.query("INSERT INTO public.spend_categories(id,slug,name) VALUES($1,'isolation-fixture','Isolation fixture')", [ids.spendCategory]);
    await admin.query("INSERT INTO public.user_categories(id,profile_id,name,slug) VALUES($1,$2,'Alice','alice'),($3,$4,'Bob','bob')", [ids.categoryA, ids.alice, ids.categoryB, ids.bob]);
    for (const [rule, profile, txn] of [[ids.ruleA, ids.alice, ids.txnA], [ids.ruleB, ids.bob, ids.txnB]]) {
      await admin.query("INSERT INTO public.user_merchant_category_rules(id,profile_id,match_basis,match_value,category_id,source_transaction_id) VALUES($1,$2,'strict_name','isolation merchant',$3,$4)", [rule, profile, ids.spendCategory, txn]);
    }
    await admin.query("INSERT INTO public.user_merchant_category_rules(id,profile_id,match_basis,match_value,action,flag,category_id) VALUES($1,$2,'strict_name','flag merchant','flag','suspected_issue',null)", [ids.flagRule, ids.alice]);
    await admin.query('COMMIT');
  } catch (error) { await admin.query('ROLLBACK'); throw error; }
}
async function verify(admin, url) {
  const before = await fingerprint(admin);
  const metadata = (await admin.query(`SELECT p.oid::text AS oid,p.oid::regprocedure::text AS identity,p.prosecdef,
    p.proconfig,coalesce(bool_or(a.grantee=0 AND a.privilege_type='EXECUTE'),false) AS public_execute
    FROM pg_proc p LEFT JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a ON true
    WHERE p.oid=ANY($1::regprocedure[]) GROUP BY p.oid ORDER BY p.oid`, [identities])).rows;
  assert.equal(metadata.length, 7);
  for (const fn of metadata) {
    assert.equal(fn.public_execute, false); assert.equal(fn.prosecdef, true);
    assert.ok(fn.proconfig.some(value => ['search_path=""', 'search_path='].includes(value)));
  }
  await admin.query(`CREATE ROLE sync_exposure_probe LOGIN PASSWORD 'synthetic-isolation-password' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
    GRANT USAGE ON SCHEMA public,pandapay TO sync_exposure_probe`);
  const connectAs = async (role, password) => {
    const target = new URL(url); target.username = role; target.password = password;
    const client = new Client({ connectionString: target.toString(), ssl: false, connectionTimeoutMillis: 3000 });
    await client.connect();
    const row = (await client.query('SELECT current_user AS role,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')).rows[0];
    assert.equal(row.role, role); assert.equal(row.rolsuper, false); assert.equal(row.rolbypassrls, false);
    return client;
  };
  const app = await connectAs('app_user', process.env.APP_USER_PASSWORD), exposure = await connectAs('sync_exposure_probe', 'synthetic-isolation-password');
  const calls = [
    { name: 'register', sql: 'SELECT pandapay.register_sync_device($1,\'web\',null,null,$2)', args: [ids.alice, ids.deviceA] },
    { name: 'push', sql: 'SELECT * FROM pandapay.sync_apply_change($1,$2,\'transactions\',$3,\'update\',\'{"note":"accepted note"}\',\'{"note":2000}\',1)', args: [ids.alice, ids.deviceA, ids.txnA] },
    { name: 'pull', sql: 'SELECT * FROM pandapay.sync_pull($1,$2,0,500)', args: [ids.alice, ids.deviceA] },
    { name: 'ack', sql: 'SELECT pandapay.sync_ack($1,$2,1)', args: [ids.alice, ids.deviceA] },
    { name: 'category7', sql: 'SELECT * FROM pandapay.sync_insert_user_category($1,$2,$3,\'Child\',\'child\',\'{}\',1)', args: [ids.alice, ids.deviceA, crypto.randomUUID()] },
    { name: 'category10', sql: 'SELECT * FROM pandapay.sync_insert_user_category($1,$2,$3,\'Nested\',\'nested\',null,$4,ARRAY[\'Office\'],\'{}\',1)', args: [ids.alice, ids.deviceA, crypto.randomUUID(), ids.categoryA] },
    { name: 'rule', sql: 'SELECT * FROM pandapay.sync_apply_user_merchant_category_rule($1,$2,$3,\'update\',jsonb_build_object(\'version\',2,\'category_id\',$4::uuid,\'is_active\',false),1)', args: [ids.alice, ids.deviceA, ids.ruleA, ids.spendCategory] },
  ];
  async function denied(client, call, code = '42501') {
    await client.query('SAVEPOINT denied_probe');
    await assert.rejects(client.query(call.sql, call.args), error => error.code === code);
    await client.query('ROLLBACK TO SAVEPOINT denied_probe'); await client.query('RELEASE SAVEPOINT denied_probe');
  }
  try {
    await exposure.query('BEGIN'); await exposure.query("SELECT set_config('app.user_id',$1,true)", [ids.alice]);
    for (const call of calls) await denied(exposure, call);
    await exposure.query('ROLLBACK');
    await app.query('BEGIN');
    for (const call of calls) await denied(app, call); // No authenticated context.
    await app.query("SELECT set_config('app.user_id',$1,true)", [ids.bob]);
    for (const call of calls) await denied(app, call); // Claiming Alice as Bob.
    await app.query("SELECT set_config('app.user_id',$1,true)", [ids.alice]);
    for (const call of calls.filter(call => call.name !== 'register')) {
      await denied(app, { ...call, args: [ids.alice, ids.deviceB, ...call.args.slice(2)] });
      await denied(app, { ...call, args: [ids.alice, null, ...call.args.slice(2)] });
    }
    // Fully qualified product relations resist session temp-table shadowing.
    for (const table of tables) await app.query(`CREATE TEMP TABLE ${table}(probe integer)`);
    await app.query('SET LOCAL search_path=pg_temp,public,pandapay');
    const registered = (await app.query(calls[0].sql, calls[0].args)).rows[0].register_sync_device;
    assert.equal(registered, ids.deviceA);
    const fresh = (await app.query("SELECT pandapay.register_sync_device($1,'android','Fresh','1',null) AS id", [ids.alice])).rows[0].id;
    assert.notEqual(fresh, ids.deviceA);
    const foreignRecovery = (await app.query("SELECT pandapay.register_sync_device($1,'web',null,null,$2) AS id", [ids.alice, ids.deviceB])).rows[0].id;
    assert.notEqual(foreignRecovery, ids.deviceB); // Preserve stale-device recovery.
    assert.equal((await app.query(calls[1].sql, calls[1].args)).rows[0].out_applied, true);
    assert.equal((await app.query('SELECT note FROM public.transactions WHERE id=$1', [ids.txnA])).rows[0].note, 'accepted note');
    for (const sql of ["SELECT * FROM pandapay.sync_apply_change($1,$2,'transactions',$3,'delete','{}','{}',2)", "SELECT * FROM pandapay.sync_apply_change($1,$2,'transactions',$3,'update','{\"status\":\"ignored\"}','{}',2)"]) {
      await denied(app, { sql, args: [ids.alice, ids.deviceA, ids.txnA] });
    }
    assert.equal((await app.query(calls[4].sql, calls[4].args)).rows[0].out_applied, true);
    assert.equal((await app.query(calls[5].sql, calls[5].args)).rows[0].out_applied, true);
    for (const call of [calls[4], calls[5]]) {
      const collision = await app.query(call.sql, [ids.alice, ids.deviceA, ids.categoryB, ...call.args.slice(3)]);
      assert.equal(collision.rows[0].out_applied, false); assert.equal(collision.rows[0].out_reason, 'not_found');
    }
    assert.equal(Number((await app.query('SELECT count(*) FROM public.change_log WHERE entity_id=$1', [ids.categoryB])).rows[0].count), 0, 'foreign category collision must not append a false-success change');
    assert.equal((await app.query(calls[6].sql, calls[6].args)).rows[0].out_applied, true);
    assert.equal((await app.query(calls[6].sql, calls[6].args)).rows[0].out_reason, 'stale_revision');
    const foreignRule = await app.query(calls[6].sql, [ids.alice, ids.deviceA, ids.ruleB, ids.spendCategory]);
    assert.equal(foreignRule.rows[0].out_applied, false); assert.equal(foreignRule.rows[0].out_reason, 'not_found');
    const flag = await app.query("SELECT * FROM pandapay.sync_apply_user_merchant_category_rule($1,$2,$3,'update','{\"version\":2,\"is_active\":false}',1)", [ids.alice, ids.deviceA, ids.flagRule]);
    assert.equal(flag.rows[0].out_applied, true);
    const savedFlag = (await app.query('SELECT action,flag,category_id,is_active FROM public.user_merchant_category_rules WHERE id=$1', [ids.flagRule])).rows[0];
    assert.deepEqual(savedFlag, { action: 'flag', flag: 'suspected_issue', category_id: null, is_active: false });
    // A separate owned device receives the change; foreign profile history
    // stays absent. Pull retains its ordered server sequence and limit.
    const pulled = await app.query('SELECT * FROM pandapay.sync_pull($1,$2,0,500)', [ids.alice, fresh]);
    assert.ok(pulled.rows.some(row => row.entity_id === ids.txnA)); assert.ok(pulled.rows.every(row => row.entity_id !== ids.txnB));
    await app.query('SELECT pandapay.sync_ack($1,$2,50)', [ids.alice, ids.deviceA]);
    await app.query('SELECT pandapay.sync_ack($1,$2,10)', [ids.alice, ids.deviceA]);
    assert.equal(Number((await app.query('SELECT last_server_seq FROM public.sync_cursors WHERE device_id=$1', [ids.deviceA])).rows[0].last_server_seq), 50);
    await denied(app, { sql: 'SELECT pandapay.sync_ack($1,$2,-1)', args: [ids.alice, ids.deviceA] }, '22023');
    await app.query('ROLLBACK');
    // Reused connection must not carry the previous transaction's identity.
    await app.query('BEGIN'); for (const call of calls) await denied(app, call); await app.query('ROLLBACK');
    await admin.query('UPDATE public.sync_cursors SET profile_id=$1 WHERE device_id=$2', [ids.bob, ids.deviceA]);
    try {
      await app.query('BEGIN'); await app.query("SELECT set_config('app.user_id',$1,true)", [ids.alice]);
      await denied(app, calls[3]); await app.query('ROLLBACK');
    } finally {
      await app.query('ROLLBACK');
      await admin.query('UPDATE public.sync_cursors SET profile_id=$1 WHERE device_id=$2', [ids.alice, ids.deviceA]);
    }
    assert.deepEqual(await fingerprint(admin), before, 'request rollback preserves every seeded row and history');
    console.log('PASS: seven legacy sync RPCs deny PUBLIC even with forged context; independent app LOGIN rejects absent/wrong identity and foreign/null devices; temp shadows ignored; registration/category/note/pull/monotonic ack preserved; status/delete denied; transaction-local identity cleared; all synthetic data digests preserved');
    return { public_execute: false, guarded_routines: 7, independent_logins: true, data_fingerprint: before };
  } finally {
    await app.query('ROLLBACK').catch(() => {}); await exposure.query('ROLLBACK').catch(() => {});
    await app.end(); await exposure.end();
    await admin.query('DROP OWNED BY sync_exposure_probe; DROP ROLE sync_exposure_probe');
  }
}
async function main() {
  const url = fixtureUrl(), admin = new Client({ connectionString: url.toString(), ssl: false, connectionTimeoutMillis: 3000 });
  await admin.connect();
  try {
    const identity = (await admin.query('SELECT current_database() AS db,host(inet_server_addr()) AS server')).rows[0];
    assert.equal(identity.db, url.pathname.slice(1)); assert.ok(['127.0.0.1', '::1'].includes(identity.server));
    if (process.argv[2] === '--seed') { await seed(admin); console.log('PASS: synthetic pre-upgrade rows committed'); }
    else if (process.argv.length === 2) await verify(admin, url);
    else throw new Error('Invalid synthetic fixture mode');
  } finally { await admin.end(); }
}
if (require.main === module) main().catch(error => { console.error('Synthetic sync isolation fixture failed:', error.stack); process.exitCode = 1; });
module.exports = { identities, fingerprint };
