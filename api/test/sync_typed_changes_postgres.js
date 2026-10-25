'use strict';

// Explicit loopback-only integration fixture for the typed sync RPC. This is
// intentionally opt-in and runs every synthetic write inside one outer
// transaction that is rolled back before exit.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('pg');

function fixtureUrl() {
  const raw = process.env.PANDAPAY_SYNC_TYPED_TEST_URL;
  if (!raw) throw Object.assign(new Error('fixture URL required'), { code: 'URL01' });
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) ||
      !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.pathname !== '/sync_transport_test' || !url.username || !url.password ||
      url.search || url.hash) {
    throw Object.assign(new Error('loopback fixture URL required'), { code: 'URL02' });
  }
  return url;
}

function safeCode(error) {
  return /^[0-9A-Z]{5}$/.test(error?.code || '') ? error.code : 'check_failed';
}

async function main() {
  let stage = 'validate_url';
  const url = fixtureUrl();
  const client = new Client({
    connectionString: url.toString(), ssl: false, connectionTimeoutMillis: 3000,
    application_name: 'pandapay-sync-typed-fixture',
  });
  try {
    stage = 'connect';
    await client.connect();
    stage = 'preflight_identity';
    const identity = (await client.query(`
      SELECT current_database() AS db, current_user AS role,
             host(inet_server_addr()) AS server, host(inet_client_addr()) AS client
    `)).rows[0];
    assert.equal(identity.db, 'sync_transport_test');
    assert.notEqual(identity.role, 'app_user');
    const loopbacks = ['127.0.0.1', '::1', '::ffff:127.0.0.1'];
    assert.ok(loopbacks.includes(identity.server));
    assert.ok(loopbacks.includes(identity.client));
    for (const table of [
      'profiles', 'transactions', 'user_devices', 'user_cards', 'card_overrides',
      'change_log', 'sync_cursors', 'sync_conflicts', 'user_categories',
      'user_merchant_category_rules',
    ]) {
      stage = `preflight_${table}`;
      const rows = await client.query(`SELECT count(*)::integer AS n FROM public.${table}`);
      assert.equal(rows.rows[0].n, 0);
    }

    stage = 'legacy_function_hash_before';
    const legacyBefore = await client.query(`
      SELECT pg_get_functiondef(
        'pandapay.sync_apply_change(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)'::regprocedure
      ) AS definition
    `);
    const legacyHashBefore = crypto.createHash('sha256').update(legacyBefore.rows[0].definition).digest('hex');
    const legacyPublicBefore = (await client.query(`SELECT has_function_privilege('public',
      'pandapay.sync_apply_change(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)', 'EXECUTE') AS allowed`)).rows[0].allowed;
    stage = 'begin_fixture';
    await client.query('BEGIN');

    const alice = crypto.randomUUID();
    const bob = crypto.randomUUID();
    const deviceA = crypto.randomUUID();
    const deviceB = crypto.randomUUID();
    const cardA = crypto.randomUUID();
    const cardB = crypto.randomUUID();
    const txnA = crypto.randomUUID();
    const overrideA = crypto.randomUUID();
    const category = crypto.randomUUID();
    const issuer = crypto.randomUUID();
    const product = crypto.randomUUID();
    stage = 'seed_fixture';
    await client.query('INSERT INTO profiles(id) VALUES($1),($2)', [alice, bob]);
    await client.query('INSERT INTO issuers(id,slug,name) VALUES($1,$2,$3)', [issuer, `fixture-${issuer}`, 'Fixture issuer']);
    await client.query(`
      INSERT INTO card_products(id,issuer_id,slug,name,network)
      VALUES($1,$2,$3,'Fixture card','visa')
    `, [product, issuer, `fixture-${product}`]);
    await client.query('INSERT INTO spend_categories(id,slug,name) VALUES($1,$2,$3)', [category, `fixture-${category}`, 'Fixture category']);
    for (const [id, profile] of [[deviceA, alice], [deviceB, bob]]) {
      await client.query("INSERT INTO user_devices(id,profile_id,platform) VALUES($1,$2,'web')", [id, profile]);
    }
    for (const [id, profile] of [[cardA, alice], [cardB, bob]]) {
      await client.query('INSERT INTO user_cards(id,profile_id,card_product_id) VALUES($1,$2,$3)', [id, profile, product]);
    }
    await client.query(`
      INSERT INTO transactions
        (id,profile_id,user_card_id,amount_inr,occurred_at,instrument,entry_kind,source,note)
      VALUES($1,$2,$3,1000,now(),'credit_card','spend','manual','before')
    `, [txnA, alice, cardA]);
    await client.query(`
      INSERT INTO card_overrides(id,profile_id,user_card_id,scope,merchant_name)
      VALUES($1,$2,$3,'merchant_name','Fixture merchant')
    `, [overrideA, alice, cardA]);

    const signature = 'pandapay.sync_apply_change_v2(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)';
    const rpc = 'pandapay.sync_apply_change_v2';
    const call = async ({ user = alice, profile = alice, device = deviceA, entity = 'transactions',
      entityId = txnA, op = 'update', payload = {}, clocks = {}, seq = 1 } = {}) => {
      await client.query('SAVEPOINT typed_call');
      try {
        await client.query('SET LOCAL ROLE app_user');
        await client.query("SELECT set_config('app.user_id',$1,true)", [user]);
        const result = await client.query(
          `SELECT * FROM ${rpc}($1,$2,$3,$4,$5::public.sync_op,$6::jsonb,$7::jsonb,$8)`,
          [profile, device, entity, entityId, op, JSON.stringify(payload), JSON.stringify(clocks), seq],
        );
        await client.query('RESET ROLE');
        await client.query('RELEASE SAVEPOINT typed_call');
        return { row: result.rows[0] };
      } catch (error) {
        await client.query('ROLLBACK TO SAVEPOINT typed_call');
        await client.query('RESET ROLE');
        await client.query('RELEASE SAVEPOINT typed_call');
        return { error };
      }
    };
    const expectCode = async (label, input, code) => {
      stage = label;
      const result = await call(input);
      if (!result.error) {
        throw Object.assign(new Error('expected SQL error was not raised'), { code: 'EXPECTED_ERROR_MISSING' });
      }
      assert.equal(safeCode(result.error), code);
    };
    const successfulCall = async (input) => {
      const result = await call(input);
      if (result.error) throw result.error;
      return result.row;
    };
    const get = async (sql, values = []) => (await client.query(sql, values)).rows[0];

    stage = 'default_deny_anon';
    const anonResult = await client.query("SELECT to_regrole('anon') AS role");
    let deniedRole = 'anon';
    if (!anonResult.rows[0].role) {
      deniedRole = `typed_anon_${crypto.randomUUID().replaceAll('-', '')}`;
      await client.query(`CREATE ROLE "${deniedRole}" NOLOGIN`);
    }
    // Let the low-privilege caller resolve the function; it must still fail
    // specifically at EXECUTE because the RPC has no PUBLIC grant.
    await client.query(`GRANT USAGE ON SCHEMA public, pandapay TO "${deniedRole}"`);
    const acl = await client.query(`
      SELECT coalesce(bool_or(x.grantee = 0 AND x.privilege_type = 'EXECUTE'), false) AS allowed
        FROM pg_proc p,
             LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
       WHERE p.oid = $1::regprocedure
    `, [signature]);
    assert.equal(acl.rows[0].allowed, false);
    await client.query('SAVEPOINT anon_call');
    await client.query(`SET LOCAL ROLE "${deniedRole}"`);
    const anonError = await callAsAnon(client, {
      profile: alice, device: deviceA, entityId: txnA,
    });
    await client.query('ROLLBACK TO SAVEPOINT anon_call');
    await client.query('RESET ROLE');
    await client.query('RELEASE SAVEPOINT anon_call');
    assert.equal(safeCode(anonError), '42501');

    stage = 'unknown_entity';
    const unknown = await successfulCall({ entity: 'profiles', payload: { display_name: 'ignored' } });
    assert.equal(unknown.out_reason, 'unknown_entity');
    assert.equal(unknown.out_applied, false);
    stage = 'profile_mismatch';
    const mismatch = await successfulCall({ profile: bob });
    assert.equal(mismatch.out_reason, 'not_found');
    stage = 'device_mismatch';
    const wrongDevice = await successfulCall({ device: deviceB });
    assert.equal(wrongDevice.out_reason, 'not_found');

    await expectCode('reject_status_write', { payload: { status: 'reversed' }, clocks: { status: 10 } }, '42501');
    await expectCode('reject_transaction_delete', { op: 'delete', payload: {}, clocks: {} }, '42501');

    stage = 'valid_typed_transaction_patch';
    const valid = await successfulCall({ payload: {
      amount_inr: 1100.25, occurred_at: '2025-01-02T03:04:05Z', user_card_id: cardA,
      merchant_name: "'); DROP TABLE public.profiles;--", merchant_vpa: null, mcc: '5411',
      category_id: category, rail: 'atm', instrument: 'credit_card', entry_kind: 'spend',
      note: 'safe synthetic value', profile_id: bob, id: bob, ignored: 'ignored',
    }, clocks: {
      amount_inr: 10, occurred_at: 10, user_card_id: 10, merchant_name: 10,
      merchant_vpa: 10, mcc: 10, category_id: 10, rail: 10, instrument: 10,
      entry_kind: 10, note: 10,
    } });
    assert.equal(valid.out_applied, true);
    const tx = await get('SELECT profile_id,user_card_id,amount_inr::text AS amount,merchant_name,merchant_vpa,note FROM transactions WHERE id=$1', [txnA]);
    assert.equal(tx.profile_id, alice);
    assert.equal(tx.user_card_id, cardA);
    assert.equal(tx.amount, '1100.25');
    assert.equal(tx.merchant_name, "'); DROP TABLE public.profiles;--");
    assert.equal(tx.merchant_vpa, null);
    assert.equal(tx.note, 'safe synthetic value');
    assert.equal((await get("SELECT to_regclass('public.profiles') AS exists")).exists, 'profiles');

    await expectCode('reject_fractional_paise', { payload: { amount_inr: 1100.255 }, clocks: { amount_inr: 20 } }, '22003');
    await expectCode('reject_nonpositive_amount', { payload: { amount_inr: 0 }, clocks: { amount_inr: 20 } }, '23514');
    await expectCode('reject_bad_uuid', { payload: { user_card_id: 'not-a-uuid' }, clocks: { user_card_id: 20 } }, '22P02');
    await expectCode('reject_bad_enum', { payload: { rail: 'unknown-rail' }, clocks: { rail: 20 } }, '22P02');
    await expectCode('reject_bad_timestamp', { payload: { occurred_at: 'not-a-timestamp' }, clocks: { occurred_at: 20 } }, '22007');

    stage = 'valid_user_card_boolean_date';
    const cardUpdate = await successfulCall({ entity: 'user_cards', entityId: cardA, payload: {
      is_default: true, opened_on: '2020-02-29', credit_limit_inr: 50000,
    }, clocks: { is_default: 10, opened_on: 10, credit_limit_inr: 10 } });
    assert.equal(cardUpdate.out_applied, true);
    const cardRow = await get('SELECT is_default,opened_on::text,credit_limit_inr::text AS limit FROM user_cards WHERE id=$1', [cardA]);
    assert.equal(cardRow.is_default, true);
    assert.equal(cardRow.opened_on, '2020-02-29');
    assert.equal(cardRow.limit, '50000.00');
    await expectCode('reject_credit_limit_subpaise', { entity: 'user_cards', entityId: cardA, payload: { credit_limit_inr: 12.345 }, clocks: { credit_limit_inr: 20 } }, '22003');
    await expectCode('reject_nonpositive_credit_limit', { entity: 'user_cards', entityId: cardA, payload: { credit_limit_inr: -1 }, clocks: { credit_limit_inr: 20 } }, '23514');
    stage = 'allow_null_credit_limit';
    const clearLimit = await successfulCall({ entity: 'user_cards', entityId: cardA, payload: { credit_limit_inr: null }, clocks: { credit_limit_inr: 21 } });
    assert.equal(clearLimit.out_applied, true);
    assert.equal((await get('SELECT credit_limit_inr FROM user_cards WHERE id=$1', [cardA])).credit_limit_inr, null);

    stage = 'override_owned_card_update';
    const overrideGood = await successfulCall({ entity: 'card_overrides', entityId: overrideA, payload: { user_card_id: cardA, is_enabled: false }, clocks: { user_card_id: 10, is_enabled: 10 } });
    assert.equal(overrideGood.out_applied, true);
    await expectCode('override_foreign_card_rejected', { entity: 'card_overrides', entityId: overrideA, payload: { user_card_id: cardB }, clocks: { user_card_id: 20 } }, '23503');

    stage = 'clock_stale_and_equal';
    const newer = await successfulCall({ payload: { note: 'clock-newer' }, clocks: { note: 100 } });
    assert.equal(newer.out_applied, true);
    const stale = await successfulCall({ payload: { note: 'clock-stale' }, clocks: { note: 99 } });
    assert.equal(stale.out_conflicts, 1);
    assert.equal((await get('SELECT note FROM transactions WHERE id=$1', [txnA])).note, 'clock-newer');
    const equal = await successfulCall({ payload: { note: 'clock-equal' }, clocks: { note: 100 } });
    assert.equal(equal.out_conflicts, 1);
    assert.equal((await get('SELECT note FROM transactions WHERE id=$1', [txnA])).note, 'clock-equal');
    assert.equal(Number((await get('SELECT count(*)::integer AS n FROM sync_conflicts WHERE profile_id=$1', [alice])).n), 2);

    stage = 'legacy_function_hash_after';
    const legacyAfter = await client.query(`
      SELECT pg_get_functiondef(
        'pandapay.sync_apply_change(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)'::regprocedure
      ) AS definition
    `);
    assert.equal(crypto.createHash('sha256').update(legacyAfter.rows[0].definition).digest('hex'), legacyHashBefore);
    stage = 'verify_old_function_grants_untouched';
    const oldPublicExec = await client.query(`
      SELECT has_function_privilege('public',
        'pandapay.sync_apply_change(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)', 'EXECUTE') AS allowed
    `);
    // Typed-write tests must preserve the installed legacy ACL. The later
    // isolation migration deliberately removes its historical PUBLIC grant.
    assert.equal(oldPublicExec.rows[0].allowed, legacyPublicBefore);

    stage = 'rollback_fixture';
    await client.query('ROLLBACK');
    stage = 'complete';
    process.stdout.write('PASS typed sync RPC PostgreSQL fixture; legacy_function_unchanged=true; fixture_rolled_back=true\n');
  } catch (error) {
    const failure = new Error('typed sync PostgreSQL fixture failed');
    failure.syncFixtureStage = stage;
    failure.syncFixtureCode = safeCode(error);
    throw failure;
  } finally {
    if (client._connected) {
      try { await client.query('ROLLBACK'); } catch (_) { /* already rolled back */ }
      await client.end();
    }
  }
}

async function callAsAnon(client, { profile, device, entityId }) {
  try {
    await client.query(`SELECT * FROM pandapay.sync_apply_change_v2($1,$2,'transactions',$3,'update','{}'::jsonb,'{}'::jsonb,1)`, [profile, device, entityId]);
    return null;
  } catch (error) {
    return error;
  }
}

if (require.main === module) {
  main().catch((error) => {
    const stage = /^[a-z0-9_]+$/.test(error?.syncFixtureStage || '') ? error.syncFixtureStage : 'startup';
    const code = /^[0-9A-Z_]{2,48}$/.test(error?.syncFixtureCode || '') ? error.syncFixtureCode : 'check_failed';
    process.stderr.write(`FAIL typed sync PostgreSQL fixture stage=${stage} code=${code}\n`);
    process.exitCode = 1;
  });
}

module.exports = { main, fixtureUrl };
