'use strict';

// Explicit local integration harness for the actual /sync route fragments.
// It uses a complete migrated product schema but refuses any existing user
// data, seeds only synthetic rows, runs API work with app_user/RLS context,
// and rolls the fixture transaction back.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Client } = require('pg');
const helpers = require('../src/sync_request_validation');

function fixtureUrl() {
  const raw = process.env.PANDAPAY_SYNC_TRANSPORT_TEST_URL;
  if (!raw) throw new Error('fixture URL required');
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) ||
      !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.pathname !== '/sync_transport_test' || !url.username || !url.password ||
      url.search || url.hash) {
    throw new Error('loopback sync_transport_test URL required');
  }
  return url;
}

function isLoopbackAddress(value) {
  return ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(value);
}

function routeFixture(client, { typed = false, transactionApplier } = {}) {
  const source = fs.readFileSync(require.resolve('../src/index'), 'utf8');
  const routes = new Map();
  let inspectBeforeRollback;
  let preserveRequestWrites = false;
  let lastRouteSqlState;
  const itemSqlStates = [];
  const sections = [
    ["app.post('/sync/register-device'", "/**\n * POST /notification-devices"],
    ["app.post('/sync/push'", "/**\n * GET /sync/pull?"],
    ["app.get('/sync/pull'", '/** POST /sync/ack'],
    ["app.post('/sync/ack'", '/** POST /sync/conflicts'],
  ];
  const context = {
    ...helpers,
    config: { syncTypedWritesEnabled: typed },
    applyTransactionSync: transactionApplier,
    console: { error() {} },
    safeErrorCode: (error) => {
      lastRouteSqlState = /^[0-9A-Z]{5}$/.test(error?.code || '') ? error.code : 'check_failed';
      return 'safe_code';
    },
    syncRejectionDetail: (error) => {
      itemSqlStates.push(/^[0-9A-Z]{5}$/.test(error?.code || '') ? error.code : 'check_failed');
      return helpers.syncRejectionDetail(error);
    },
    requireAuth() {},
    app: Object.fromEntries(['post', 'get'].map((method) => [
      method,
      (url, _auth, handler) => routes.set(`${method} ${url}`, handler),
    ])),
    withUserClient: async (userId, callback) => {
      await client.query('SAVEPOINT sync_transport_request');
      try {
        await client.query('SET LOCAL ROLE app_user');
        await client.query("SELECT set_config('app.user_id', $1, true)", [userId]);
        const value = await callback(client);
        // The inspection runs as the explicitly supplied local operator, after
        // the route work is complete but before its enclosing savepoint rolls
        // back. Route SQL itself always ran as app_user.
        await client.query('RESET ROLE');
        await inspectBeforeRollback?.();
        if (!preserveRequestWrites) {
          await client.query('ROLLBACK TO SAVEPOINT sync_transport_request');
        }
        await client.query('RELEASE SAVEPOINT sync_transport_request');
        return value;
      } catch (error) {
        await client.query('ROLLBACK TO SAVEPOINT sync_transport_request');
        await client.query('RELEASE SAVEPOINT sync_transport_request');
        throw error;
      }
    },
  };

  for (const [startToken, endToken] of sections) {
    const start = source.indexOf(startToken);
    const end = source.indexOf(endToken, start);
    assert.ok(start >= 0 && end > start);
    vm.runInNewContext(source.slice(start, end), context);
  }

  return {
    takeRouteSqlState() { const code = lastRouteSqlState; lastRouteSqlState = undefined; return code; },
    takeItemSqlStates() { return itemSqlStates.splice(0); },
    async invoke(method, url, request = {}, inspect, { retainWrites = false } = {}) {
      inspectBeforeRollback = inspect;
      preserveRequestWrites = retainWrites;
      const response = {
        code: 200,
        status(code) { this.code = code; return this; },
        json(body) { this.body = JSON.parse(JSON.stringify(body)); return this; },
      };
      try {
        await routes.get(`${method} ${url}`)(
          { userId: request.userId, body: {}, query: {}, params: {}, ...request },
          response,
        );
      } finally {
        inspectBeforeRollback = undefined;
        preserveRequestWrites = false;
      }
      return response;
    },
  };
}

async function requireCleanFixture(client, setStage) {
  setStage('preflight_identity_query');
  const identity = (await client.query(`
    SELECT current_database() AS database_name,
           current_user AS operator,
           host(inet_server_addr()) AS server_address,
           host(inet_client_addr()) AS client_address
  `)).rows[0];
  setStage('preflight_database_name');
  assert.equal(identity.database_name, 'sync_transport_test');
  setStage('preflight_operator_role');
  assert.notEqual(identity.operator, 'app_user');
  setStage('preflight_server_address');
  if (!isLoopbackAddress(identity.server_address)) {
    setStage(identity.server_address == null ? 'preflight_server_address_null' : 'preflight_server_address_unrecognized');
    throw Object.assign(new Error('non-loopback database server'), { code: 'ADDR01' });
  }
  setStage('preflight_client_address');
  if (!isLoopbackAddress(identity.client_address)) {
    setStage(identity.client_address == null ? 'preflight_client_address_null' : 'preflight_client_address_unrecognized');
    throw Object.assign(new Error('non-loopback database client'), { code: 'ADDR02' });
  }
  const tables = [
    'profiles', 'transactions', 'user_devices', 'change_log',
    'sync_cursors', 'sync_conflicts',
  ];
  for (const table of tables) {
    setStage(`preflight_${table}`);
    const result = await client.query(`SELECT count(*)::integer AS count FROM public.${table}`);
    assert.equal(result.rows[0].count, 0, `fixture database contains rows in ${table}`);
  }
  // Prove this operator can enter the exact request role used by the API.
  setStage('preflight_app_role');
  await client.query('BEGIN');
  await client.query('SET LOCAL ROLE app_user');
  await client.query('ROLLBACK');
}

async function main() {
  let stage = 'validate_url';
  const url = fixtureUrl();
  const client = new Client({
    connectionString: url.toString(),
    ssl: false,
    connectionTimeoutMillis: 3000,
    application_name: 'pandapay-sync-transport-fixture',
  });
  try {
    stage = 'connect';
    await client.connect();
    stage = 'preflight';
    await requireCleanFixture(client, (value) => { stage = value; });
    await client.query('BEGIN');

    stage = 'seed_profiles';
    const userId = crypto.randomUUID();
    const otherUserId = crypto.randomUUID();
    const transactionId = crypto.randomUUID();
    const otherTransactionId = crypto.randomUUID();
    const firstDevice = crypto.randomUUID();
    const secondDevice = crypto.randomUUID();
    const otherDevice = crypto.randomUUID();
    const staleDevice = crypto.randomUUID();
    await client.query('INSERT INTO profiles(id) VALUES($1),($2)', [userId, otherUserId]);
    stage = 'seed_devices';
    for (const [id, profileId] of [
      [firstDevice, userId], [secondDevice, userId], [otherDevice, otherUserId],
    ]) {
      await client.query(
        "INSERT INTO user_devices(id,profile_id,platform) VALUES($1,$2,'web')",
        [id, profileId],
      );
      await client.query(
        'INSERT INTO sync_cursors(device_id,profile_id) VALUES($1,$2)',
        [id, profileId],
      );
    }
    stage = 'seed_transactions';
    for (const [id, profileId, amount, note] of [
      [transactionId, userId, 1000, 'initial note'],
      [otherTransactionId, otherUserId, 2000, 'other account note'],
    ]) {
      await client.query(`
        INSERT INTO transactions
          (id,profile_id,amount_inr,occurred_at,instrument,entry_kind,source,status,note)
        VALUES($1,$2,$3,now(),'cash','spend','manual','active',$4)
      `, [id, profileId, amount, note]);
    }

    const routes = routeFixture(client);
    const registrationObservations = [];
    stage = 'registration_default';
    const register = async (body) => routes.invoke(
      'post', '/sync/register-device', { userId, body }, async () => {
        registrationObservations.push((await client.query(
          `SELECT id,profile_id,platform,device_label,app_version
             FROM user_devices WHERE profile_id=$1 ORDER BY created_at,id`, [userId],
        )).rows);
      },
    );

    const defaultRegistration = await register(null);
    assert.equal(defaultRegistration.code, 201);
    const defaultId = defaultRegistration.body.deviceId;
    assert.match(defaultId, /^[0-9a-f-]{36}$/i);
    assert.ok(registrationObservations[0].some((row) => row.id === defaultId && row.platform === 'web'));

    stage = 'registration_platform_fallback';
    const fallbackRegistration = await register({ platform: 'legacy-platform' });
    const fallbackId = fallbackRegistration.body.deviceId;
    assert.equal(fallbackRegistration.code, 201);
    assert.ok(registrationObservations[1].some((row) => row.id === fallbackId && row.platform === 'web'));

    stage = 'registration_known_device';
    const knownRegistration = await register({
      platform: 'ios', deviceId: firstDevice, label: 'fixture-known', appVersion: 'fixture-v1',
    });
    assert.equal(knownRegistration.body.deviceId, firstDevice);
    assert.ok(registrationObservations[2].some((row) => row.id === firstDevice && row.device_label === 'fixture-known'));

    stage = 'registration_stale_device';
    const staleRegistration = await register({ platform: 'ios', deviceId: staleDevice });
    assert.equal(staleRegistration.code, 201);
    assert.notEqual(staleRegistration.body.deviceId, staleDevice);
    assert.ok(registrationObservations[3].some((row) => row.id === staleRegistration.body.deviceId && row.platform === 'ios'));

    const rawRejectedValue = 'SYNC_FIXTURE_RAW_REJECTION_7d839ab4';
    stage = 'push_item_outcomes';
    let pushObservation;
    const push = await routes.invoke('post', '/sync/push', {
      userId,
      body: {
        deviceId: firstDevice,
        changes: [
          {
            entity: 'transactions', entityId: transactionId, op: 'update',
            payload: { note: 'fixture-successful-first-note' },
            fieldClocks: { note: 1000 }, clientSeq: 1,
          },
          null,
          {
            entity: 'transactions', entityId: transactionId, op: 'update',
            payload: { amount_inr: -17.25, note: rawRejectedValue },
            fieldClocks: { amount_inr: 2000, note: 2000 }, clientSeq: 2,
          },
          {
            entity: 'transactions', entityId: transactionId, op: 'update',
            payload: { note: 'fixture-successful-final-note' },
            fieldClocks: { note: 3000 }, clientSeq: 3,
          },
        ],
      },
    }, async () => {
      stage = 'push_state_query';
      const row = (await client.query(
        'SELECT amount_inr::text AS amount,note FROM transactions WHERE id=$1',
        [transactionId],
      )).rows[0];
      const changes = (await client.query(
        'SELECT count(*)::integer AS count FROM change_log WHERE profile_id=$1', [userId],
      )).rows[0].count;
      pushObservation = {
        amount: Number(row.amount),
        noteMatches: row.note === 'fixture-successful-final-note',
        changeLogCount: changes,
      };
    });
    const pushCallbackStage = stage;
    stage = 'push_http_status';
    if (push.code !== 200) {
      throw Object.assign(new Error('sync push route failed'), {
        code: routes.takeRouteSqlState() || 'HTTP5',
        syncFixtureStage: 'push_callback_' + pushCallbackStage,
      });
    }
    stage = 'push_applied_count';
    assert.equal(push.code, 200);
    const itemSqlStates = routes.takeItemSqlStates();
    if (push.body.appliedCount !== 2) {
      const compactOutcomes = (push.body.results || []).map((row) =>
        `${row.applied ? '1' : '0'}${row.reason == null ? 'N' : row.reason === 'malformed' ? 'M' : row.reason === 'rejected' ? 'R' : 'O'}`,
      ).join('_');
      const codes = itemSqlStates.length ? itemSqlStates.join('_') : 'NONE';
      throw Object.assign(new Error('synthetic push apply count mismatch'), {
        code: `APPLIED_${push.body.appliedCount}_SQL_${codes}_OUT_${compactOutcomes}`,
      });
    }
    assert.equal(push.body.appliedCount, 2);
    stage = 'push_ordered_outcomes';
    const outcomeShape = push.body.results.map((row) => [row.clientSeq, row.applied, row.reason]);
    if (pushObservation?.amount !== 1000) {
      throw Object.assign(new Error('synthetic rejected amount changed'), { code: `AMOUNT_${Number.isFinite(pushObservation?.amount) ? pushObservation.amount : 'MISSING'}` });
    }
    if (!pushObservation.noteMatches) {
      throw Object.assign(new Error('synthetic note mismatch'), { code: 'NOTE_MISMATCH' });
    }
    if (pushObservation.changeLogCount !== 2) {
      throw Object.assign(new Error('synthetic log count mismatch'), { code: `LOG_COUNT_${pushObservation.changeLogCount}` });
    }
    if (JSON.stringify(outcomeShape) !== JSON.stringify([
      [1, true, null], [null, false, 'malformed'], [2, false, 'rejected'], [3, true, null],
    ])) {
      const compact = outcomeShape.map((row) => `${row[1] ? '1' : '0'}${row[2] == null ? 'N' : row[2] === 'malformed' ? 'M' : row[2] === 'rejected' ? 'R' : 'O'}`).join('_');
      throw Object.assign(new Error('synthetic item outcome mismatch'), { code: `OUTCOMES_${compact}` });
    }
    if (itemSqlStates.length !== 1 || itemSqlStates[0] !== '42804') {
      throw Object.assign(new Error('synthetic rejection count mismatch'), { code: `ITEM_ERRORS_${itemSqlStates.length}` });
    }
    assert.equal(JSON.stringify(push.body).includes(rawRejectedValue), false);
    assert.equal(JSON.stringify(push.body).includes('-17.25'), false);

    stage = 'positive_numeric_update_known_rejection';
    let positiveNumericAmount;
    const positiveNumericAttempt = await routes.invoke('post', '/sync/push', {
      userId,
      body: {
        deviceId: firstDevice,
        changes: [{
          entity: 'transactions', entityId: transactionId, op: 'update',
          payload: { amount_inr: 1350 },
          fieldClocks: { amount_inr: 4000 }, clientSeq: 5,
        }],
      },
    }, async () => {
      positiveNumericAmount = Number((await client.query(
        'SELECT amount_inr::text AS amount FROM transactions WHERE id=$1', [transactionId],
      )).rows[0].amount);
    });
    const positiveNumericSqlStates = routes.takeItemSqlStates();
    assert.equal(positiveNumericAttempt.code, 200);
    assert.equal(positiveNumericAttempt.body.appliedCount, 0);
    assert.equal(positiveNumericAttempt.body.results[0].applied, false);
    assert.equal(positiveNumericAttempt.body.results[0].reason, 'rejected');
    assert.deepEqual(positiveNumericSqlStates, ['42804']);
    assert.equal(positiveNumericAmount, 1000);
    assert.equal(JSON.stringify(positiveNumericAttempt.body).includes('1350'), false);

    stage = 'cross_account_refusal';
    const crossAccount = await routes.invoke('post', '/sync/push', {
      userId,
      body: {
        deviceId: firstDevice,
        changes: [{
          entity: 'transactions', entityId: otherTransactionId, op: 'update',
          payload: { note: 'fixture-cross-account-attempt' },
          fieldClocks: { note: 4000 }, clientSeq: 4,
        }],
      },
    }, async () => {
      const row = (await client.query(
        'SELECT note FROM transactions WHERE id=$1', [otherTransactionId],
      )).rows[0];
      assert.equal(row.note, 'other account note');
    });
    assert.equal(crossAccount.body.results[0].applied, false);
    assert.equal(crossAccount.body.results[0].reason, 'not_found');

    stage = 'seed_pull_changes';
    const seedChange = async (deviceId, entityId, clientSeq, note) => client.query(`
      INSERT INTO change_log(profile_id,device_id,entity,entity_id,op,payload,field_clocks,client_seq)
      VALUES($1,$2,'transactions',$3,'update',jsonb_build_object('note',$4::text),jsonb_build_object('note',$5::bigint),$6::bigint)
      RETURNING server_seq
    `, [userId, deviceId, transactionId, note, clientSeq * 1000, clientSeq]);
    const ownChange = await seedChange(secondDevice, transactionId, 10, 'own-device-change');
    const remoteOne = await seedChange(firstDevice, transactionId, 11, 'remote-one');
    const remoteTwo = await seedChange(firstDevice, transactionId, 12, 'remote-two');
    const ownSeq = Number(ownChange.rows[0].server_seq);
    const remoteSeqOne = Number(remoteOne.rows[0].server_seq);
    const remoteSeqTwo = Number(remoteTwo.rows[0].server_seq);

    stage = 'pull_other_device_changes';
    let cursorAfterPull;
    const pull = await routes.invoke('get', '/sync/pull', {
      userId, query: { deviceId: secondDevice, since: '0', limit: '10' },
    }, async () => {
      cursorAfterPull = (await client.query(
        'SELECT last_server_seq FROM sync_cursors WHERE device_id=$1', [secondDevice],
      )).rows[0].last_server_seq;
    });
    assert.equal(pull.code, 200);
    assert.deepEqual(pull.body.changes.map((row) => Number(row.server_seq)), [remoteSeqOne, remoteSeqTwo]);
    assert.equal(pull.body.changes.some((row) => Number(row.server_seq) === ownSeq), false);
    assert.equal(pull.body.latestServerSeq, remoteSeqTwo);
    assert.equal(pull.body.hasMore, false);
    assert.equal(Number(cursorAfterPull), 0);

    stage = 'ack_cursor_monotonicity';
    const ack = async (serverSeq) => {
      let observedCursor;
      const response = await routes.invoke('post', '/sync/ack', {
        userId, body: { deviceId: secondDevice, serverSeq },
      }, async () => {
        const row = (await client.query(
          'SELECT last_server_seq FROM sync_cursors WHERE device_id=$1', [secondDevice],
        )).rows[0];
        observedCursor = row.last_server_seq;
      }, { retainWrites: true });
      return { response, observedCursor };
    };
    const ackForward = await ack(remoteSeqTwo);
    assert.deepEqual(ackForward.response.body, { ok: true });
    assert.equal(Number(ackForward.observedCursor), remoteSeqTwo);
    const ackBackward = await ack(remoteSeqOne);
    assert.deepEqual(ackBackward.response.body, { ok: true });
    assert.equal(Number(ackBackward.observedCursor), remoteSeqTwo);
    assert.equal(ackForward.response.code, 200);
    assert.equal(ackBackward.response.code, 200);
    assert.equal(Number((await client.query(
      'SELECT last_server_seq FROM sync_cursors WHERE device_id=$1', [secondDevice],
    )).rows[0].last_server_seq), remoteSeqTwo);

    await client.query('ROLLBACK');
    stage = 'complete';
    console.log('PASS sync transport PostgreSQL route and RLS fixture; known_numeric_update_rejection=42804; numeric_write_remediation=pending');
  } catch (error) {
    const failure = new Error('sync transport fixture failed');
    failure.syncFixtureStage = error?.syncFixtureStage || stage;
    failure.syncFixtureCode = /^[A-Z0-9_]{2,48}$/.test(error?.code || '') ? error.code : 'check_failed';
    throw failure;
  } finally {
    if (client._connected) {
      try { await client.query('ROLLBACK'); } catch (_) { /* already rolled back */ }
      await client.end();
    }
  }
}

if (require.main === module) {
  main().catch((error) => {
    const stage = /^[a-z_]+$/.test(error?.syncFixtureStage || '') ? error.syncFixtureStage : 'startup';
    const code = /^[A-Z0-9_]{2,48}$/.test(error?.syncFixtureCode || '') ? error.syncFixtureCode : 'check_failed';
    process.stderr.write(`FAIL sync transport PostgreSQL fixture stage=${stage} code=${code}\n`);
    process.exitCode = 1;
  });
}

module.exports = { main, fixtureUrl, routeFixture, requireCleanFixture };
