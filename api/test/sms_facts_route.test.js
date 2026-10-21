const test = require('node:test');
const assert = require('node:assert/strict');
const smsFactsRoute = require('../src/sms_facts_route');
const smsFacts = require('../src/sms_facts');
const importResolvers = require('../src/import_resolvers');

/**
 * Minimal pg-client double: mirrors the contract test's fake plus the
 * user_cards SQL the fact-based specialist resolvers touch.
 */
const lightlyParse = (value) => {
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch (_) {
    return value;
  }
};

function fakeClient({ contributionsOptIn = true } = {}) {
  const sources = new Map();
  const sourceRows = new Map();
  const facts = new Map();
  const overrides = new Map();
  const learningFeedback = [];
  const cardFitRows = { rows: [{ id: 'uc-1' }] };
  const cardUpdates = [];
  let nextId = 1;
  const id = () => `id-${nextId++}`;
  return {
    get sources() {
      return sources;
    },
    get facts() {
      return facts;
    },
    get sourceRows() {
      return sourceRows;
    },
    get cardUpdates() {
      return cardUpdates;
    },
    get overrides() {
      return overrides;
    },
    get learningFeedback() {
      return learningFeedback;
    },
    allowCardMatch(value) {
      cardFitRows.rows = value ? [{ id: 'uc-1' }] : [];
    },
    async query(sql, params) {
      if (sql.includes('SELECT contributions_opt_in FROM profiles')) {
        return { rows: [{ contributions_opt_in: contributionsOptIn }] };
      }
      if (sql.startsWith('INSERT INTO sms_sources')) {
        const key = `${params[0]}|${params[1]}`;
        if (sources.has(key)) return { rows: [] };
        const newId = id();
        sources.set(key, newId);
        sourceRows.set(newId, {
          id: newId,
          profile_id: params[0],
          source_key: params[1],
          sender: params[2],
          body_hash: params[3],
          contract_version: params[5],
        });
        return { rows: [{ id: newId }] };
      }
      if (sql.startsWith('SELECT id FROM sms_sources')) {
        const key = `${params[0]}|${params[1]}`;
        return sources.has(key) ? { rows: [{ id: sources.get(key) }] } : { rows: [] };
      }
      if (sql.startsWith('UPDATE sms_sources')) return { rows: [] };
      if (sql.startsWith('INSERT INTO sms_source_facts')) {
        const [sourceId, profileId, factIndex] = params;
        const key = `${sourceId}|${factIndex}`;
        if (facts.has(key)) {
          return { rows: [{ id: facts.get(key).id }] };
        }
        const newId = id();
        facts.set(key, {
          id: newId,
          source_id: sourceId,
          fact_index: factIndex,
          fact_type: params[3],
          payload: params[4],
          provenance: params[5],
          status: params[6],
        });
        return { rows: [{ id: newId }] };
      }
      if (sql.startsWith('INSERT INTO fact_overrides')) {
        overrides.set(`${params[1]}|${params[2]}`, {
          fact_index: params[2],
          patch: params[3],
        });
        return { rows: [] };
      }
      if (sql.startsWith('INSERT INTO sms_learning_feedback')) {
        learningFeedback.push(params);
        return { rows: [], rowCount: 1 };
      }
      // Learning needs the user's cross-user contribution opt-in. Without it
      // the route correctly records nothing, so the fake must grant consent.
      if (sql.includes('contributions_opt_in')) {
        return { rows: [{ contributions_opt_in: true }] };
      }
      if (sql.includes('FROM sms_sources WHERE profile_id')) {
        const source = [...sourceRows.values()].find(
          (s) => s.profile_id === params[0] && s.source_key === params[1],
        );
        return { rows: source ? [source] : [] };
      }
      if (sql.includes('FROM sms_source_facts WHERE source_id')) {
        const rows = [...facts.values()]
          .filter((f) => f.source_id === params[0])
          .sort((a, b) => a.fact_index - b.fact_index)
          .map((f) => ({
            id: f.id,
            fact_index: f.fact_index,
            fact_type: f.fact_type,
            payload: JSON.parse(f.payload),
            provenance: JSON.parse(f.provenance),
            status: f.status,
            contract_version: 1,
          }));
        return { rows };
      }
      if (sql.includes('FROM fact_overrides WHERE source_id')) {
        const rows = [...overrides.entries()]
          .filter(([key]) => key.startsWith(`${params[0]}|`))
          .map(([key, row]) => ({
            key,
            fact_index: row.fact_index,
            patch: JSON.parse(row.patch),
          }));
        return { rows };
      }
      // user_cards instrumentation match (import_resolvers)
      if (sql.includes('FROM user_cards uc')) return cardFitRows;
      if (sql.startsWith('UPDATE user_cards')) {
        cardUpdates.push({
          day: params[0],
          cardId: params[1],
          sql,
        });
        return { rows: [{ id: params[1] }], rowCount: 1 };
      }
      throw new Error(`fakeClient: unhandled SQL ${sql.split('\n')[0].slice(0, 60)}`);
    },
    async upsertOverride(sourceId, factIndex, patch) {
      overrides.set(`${sourceId}|${factIndex}`, {
        fact_index: factIndex,
        patch: JSON.stringify(patch),
      });
    },
  };
}

/** Captures the routes the same way index.js registers them (both paths). */
function harness() {
  const handlers = new Map();
  let requiredAuth = false;
  let currentClient = null;
  const fakeApp = {
    post: (path, requireAuth, hh) => {
      if (path.startsWith('/sms/facts')) {
        handlers.set(path.endsWith('/overrides') ? 'overrides' : 'facts', hh);
        requiredAuth = requiredAuth || !!requireAuth;
      }
    },
    get: () => {},
  };
  const mandateCalls = [];
  smsFactsRoute.registerSmsFactsRoutes(fakeApp, {
    requireAuth: () => true,
    withUserClient: (userId, fn) => fn(currentClient),
    persistSubscriptionMandate: async (client, userId, args) => {
      mandateCalls.push(args);
      return { id: 'series-1', detection_source: 'mandate' };
    },
  });
  assert.ok(handlers.get('facts'));
  assert.ok(handlers.get('overrides'));
  assert.ok(requiredAuth);
  const makeRes = (sink) => {
    let statusCode = null;
    return {
      get statusReceived() {
        return statusCode;
      },
      json: sink,
      status(code) {
        statusCode = code;
        return this;
      },
    };
  };
  const invoke = (name) => async (client, req) => {
    currentClient = client;
    let payload = null;
    const res = makeRes((body) => { payload = body; });
    await handlers.get(name)(req, res);
    return { body: payload, status: res.statusReceived };
  };
  return {
    mandateCalls,
    call: invoke('facts'),
    overrideCall: invoke('overrides'),
  };
}

const balanceFact = (amount = 9000) => ({
  factType: 'balance_snapshot',
  payload: {
    availableBalanceInr: amount,
    asOfAt: '2026-10-16T10:00:00.000Z',
    instrument: 'upi_bank',
    accountLast4: '9876',
  },
});

const billFact = {
  factType: 'bill_obligation',
  payload: {
    amountRole: 'due_total',
    amountDueInr: 3000,
    dueDate: '2026-11-05T00:00:00.000Z',
    statementDate: '2026-10-12T18:30:00.000Z',
    last4: '4321',
  },
};

const registeredMandateFact = {
  factType: 'mandate_lifecycle',
  payload: {
    mandateStatus: 'registered',
    limitInr: 2000,
    merchant: 'NETFLIX',
    last4: '1797',
    instrument: 'credit_card',
    asOfAt: '2026-10-16T10:00:00.000Z',
  },
};

const cancelledMandateFact = {
  factType: 'mandate_lifecycle',
  payload: {
    mandateStatus: 'cancelled',
    merchant: 'NETFLIX',
    asOfAt: '2026-10-16T10:00:00.000Z',
  },
};

test('POST /sms/facts accepts valid facts and runs the specialist resolvers', async () => {
  const client = fakeClient();
  const route = harness();
  const result = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'a'.repeat(64),
      sender: 'AXISBK',
      bodyHash: 'b'.repeat(64),
      occurredAt: '2026-10-16T10:00:00.000Z',
      facts: [billFact],
      userCardId: 'uc-1',
    },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.statementDayUpdated, true);
  assert.equal(result.body.dueDayUpdated, true);
  assert.ok(client.sourceRows.get(result.body.sourceId));
  // The printed statement date 2026-10-12T18:30Z is the 13th in IST.
  const statementUpdate = client.cardUpdates.find((u) => u.sql.includes('statement_day'));
  assert.equal(statementUpdate.day, 13);
  const dueUpdate = client.cardUpdates.find((u) => u.sql.includes('due_day'));
  assert.equal(dueUpdate.day, 5);
});

test('POST /sms/facts accepts statement bills with role-separated money', async () => {
  const client = fakeClient();
  const route = harness();
  const minimum = {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_minimum',
      minimumDueInr: 600,
      dueDate: '2026-11-04T18:30:00.000Z',
      statementDate: '2026-10-12T18:30:00.000Z',
      last4: '4321',
    },
  };
  const result = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: '9'.repeat(64),
      sender: 'AXISBK',
      bodyHash: '0'.repeat(64),
      occurredAt: '2026-10-16T10:00:00.000Z',
      facts: [billFact, minimum],
      userCardId: 'uc-1',
    },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.factIds.length, 2);
  const types = [...client.facts.values()]
    .filter((f) => f.source_id === result.body.sourceId)
    .map((f) => f.fact_type);
  assert.deepEqual(types.sort(), ['bill_obligation', 'bill_obligation']);
  // Days heal once even though two bill facts carry the same dates.
  assert.equal(client.cardUpdates.filter((u) => u.sql.includes('statement_day')).length, 1);
  assert.equal(client.cardUpdates.filter((u) => u.sql.includes('due_day')).length, 1);
});

test('POST /sms/facts persists a registered mandate through the injected writer', async () => {
  const client = fakeClient();
  const route = harness();
  const result = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'c'.repeat(64),
      sender: 'HDFCBK',
      bodyHash: 'd'.repeat(64),
      occurredAt: '2026-10-26T04:00:00.000Z',
      facts: [registeredMandateFact],
    },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.mandatePersisted, true);
  const call = route.mandateCalls[0];
  assert.equal(call.parsed.ok, true);
  assert.equal(call.parsed.lifecycle, 'active');
  assert.equal(call.parsed.fields.merchant, 'NETFLIX');
  assert.equal(call.parsed.fields.amountInr, 2000);
  assert.equal(call.parsed.fields.last4, '1797');
  assert.equal(call.parsed.fields.cadenceExplicit, false);
});

test('POST /sms/facts persists a cancelled mandate with its merchant', async () => {
  const client = fakeClient();
  const route = harness();
  const result = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'e'.repeat(64),
      sender: 'HDFCBK',
      bodyHash: 'f'.repeat(64),
      facts: [cancelledMandateFact],
    },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.mandatePersisted, true);
  assert.equal(route.mandateCalls[0].parsed.lifecycle, 'cancelled');
});

test('POST /sms/facts replays idempotently: same source and fact ids', async () => {
  const client = fakeClient();
  const route = harness();
  const base = {
    userId: 'user-1',
    body: {
      sourceKey: '1'.repeat(64),
      sender: 'HDFCBK',
      bodyHash: '2'.repeat(64),
      occurredAt: '2026-10-16T10:00:00.000Z',
      facts: [balanceFact()],
    },
  };
  const first = await route.call(client, base);
  const second = await route.call(client, base);
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(second.body.sourceId, first.body.sourceId);
  assert.equal(first.body.replayed, false);
  assert.equal(second.body.replayed, true);
  assert.deepEqual(
    second.body.factIds.map((f) => f.id),
    first.body.factIds.map((f) => f.id),
  );
});

test('POST /sms/facts refuses invalid facts, bad source keys and bad hashes', async () => {
  const client = fakeClient();
  const route = harness();
  const invalid = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: '1'.repeat(64),
      sender: 'HDFCBK',
      bodyHash: '2'.repeat(64),
      facts: [
        {
          factType: 'balance_snapshot',
          payload: { availableBalanceInr: 9000, asOfAt: undefined },
        },
      ],
    },
  });
  assert.equal(invalid.status, 400);
  assert.ok(invalid.body.details.some((e) => e.includes('asOfAt is required')));

  for (const body of [
    { sourceKey: 'not-hex', bodyHash: '3'.repeat(64), facts: [balanceFact()] },
    { sourceKey: '4'.repeat(64), bodyHash: 'also-not-hex', facts: [balanceFact()] },
    { sourceKey: '5'.repeat(64), bodyHash: '6'.repeat(64), facts: [] },
    { sourceKey: '7'.repeat(64), bodyHash: '8'.repeat(64), facts: [balanceFact(-5)] },
  ]) {
    const result = await route.call(client, { userId: 'user-1', body });
    assert.equal(result.status, 400);
  }
});

test('statement-day and due-day resolvers abstain when the card is ambiguous', async () => {
  const client = fakeClient();
  client.allowCardMatch(false);
  const statement = await importResolvers.syncStatementDayFromFact(client, 'user-1', {
    statementDate: '2026-10-12T18:30:00.000Z',
    last4: '4321',
    patternIssuerId: null,
    explicitUserCardId: 'uc-1',
  });
  assert.equal(statement.updated, false);
  assert.equal(statement.reason, 'card_not_unambiguous');
  assert.equal(client.cardUpdates.length, 0);
});

test('balance snapshot facts pass validation unchanged end to end', () => {
  const result = smsFacts.validateFactSet([balanceFact()]);
  assert.deepEqual(result, { valid: true, errors: [] });
});

// Phase 4: structured user corrections. Corrections live in fact_overrides
// and always win over a later replay of the parser-derived payload.

test('overriding a due date re-heals the bill cycle with the corrected value', async () => {
  const smsFactsRoute = require('../src/sms_facts_route');
  const client = fakeClient();
  const route = harness();
  const seeded = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'a'.repeat(64),
      sender: 'AXISBK',
      bodyHash: 'b'.repeat(64),
      occurredAt: '2026-10-16T10:00:00.000Z',
      facts: [billFact],
      userCardId: 'uc-1',
    },
  });
  assert.equal(seeded.status, 200);
  const before = client.cardUpdates.filter((u) => u.sql.includes('due_day')).length;
  const oldLearningKey = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'test-learning-secret-key-0123456789';

  const corrected = await route.overrideCall(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'a'.repeat(64),
      factIndex: 0,
      patch: { dueDate: '2026-11-08T00:00:00.000Z' },
      reason: 'user corrected in needs review',
    },
  });
  if (oldLearningKey === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
  else process.env.SMS_LEARNING_HMAC_KEY = oldLearningKey;
  assert.equal(corrected.status, 200);
  assert.equal(corrected.body.overridden, true);
  assert.equal(client.learningFeedback.length, 1);
  assert.equal(client.learningFeedback[0][3], 'bill_obligation');
  assert.equal(client.learningFeedback[0][4], 'dueDate');
  // The corrected due date heals again (distinct date value).
  assert.ok(client.cardUpdates.filter((u) => u.sql.includes('due_day')).length >= before);
  // And the correction survives a replay of the original payload.
  const replay = await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'a'.repeat(64),
      sender: 'AXISBK',
      bodyHash: 'b'.repeat(64),
      facts: [billFact],
    },
  });
  assert.equal(replay.status, 200);
  const loaded = await smsFacts.loadSmsSourceFacts(
    client,
    'user-1',
    'a'.repeat(64),
  );
  const oneBill = loaded.facts.find((f) => f.factIndex === 0);
  assert.equal(oneBill.payload.dueDate, '2026-11-08T00:00:00.000Z');
  assert.equal(oneBill.overridden, true);
});

test('user correction still applies locally when shared learning contribution is opted out', async () => {
  const client = fakeClient({ contributionsOptIn: false });
  const route = harness();
  await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'e'.repeat(64),
      sender: 'AXISBK',
      bodyHash: 'f'.repeat(64),
      facts: [billFact],
    },
  });

  const oldLearningKey = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'test-learning-secret-key-0123456789';
  try {
    const corrected = await route.overrideCall(client, {
      userId: 'user-1',
      body: {
        sourceKey: 'e'.repeat(64),
        factIndex: 0,
        patch: { dueDate: '2026-11-09T00:00:00.000Z' },
      },
    });
    assert.equal(corrected.status, 200);
    assert.equal(corrected.body.overridden, true);
    assert.equal(client.learningFeedback.length, 0);
    const loaded = await smsFacts.loadSmsSourceFacts(client, 'user-1', 'e'.repeat(64));
    assert.equal(loaded.facts[0].payload.dueDate, '2026-11-09T00:00:00.000Z');
  } finally {
    if (oldLearningKey === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = oldLearningKey;
  }
});

test('an override that breaks the contract is refused with nothing written', async () => {
  const smsFactsRoute = require('../src/sms_facts_route');
  const client = fakeClient();
  const route = harness();
  await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'c'.repeat(64),
      sender: 'AXISBK',
      bodyHash: 'd'.repeat(64),
      facts: [billFact],
    },
  });
  client.cardUpdates.length = 0;
  const refused = await route.overrideCall(client, {
    userId: 'user-1',
    body: { sourceKey: 'c'.repeat(64), factIndex: 0, patch: { amountDueInr: -1 } },
  });
  assert.equal(refused.status, 400);
  assert.equal(Object.keys(client.overrides).length, 0, 'the refused patch must not be stored');
});

test('overriding an unknown source or fact slot fails explicitly', async () => {
  const smsFactsRoute = require('../src/sms_facts_route');
  const client = fakeClient();
  const route = harness();
  const unknown = await route.overrideCall(client, {
    userId: 'user-1',
    body: { sourceKey: 'e'.repeat(64), factIndex: 0, patch: { dueDate: '2026-11-05T00:00:00.000Z' } },
  });
  assert.equal(unknown.status, 404);
  await route.call(client, {
    userId: 'user-1',
    body: {
      sourceKey: 'f'.repeat(64),
      sender: 'AXISBK',
      bodyHash: '0'.repeat(64),
      facts: [balanceFact()],
    },
  });
  const missing = await route.overrideCall(client, {
    userId: 'user-1',
    body: { sourceKey: 'f'.repeat(64), factIndex: 7, patch: { dueDate: '2026-11-05T00:00:00.000Z' } },
  });
  assert.equal(missing.status, 400);
});



