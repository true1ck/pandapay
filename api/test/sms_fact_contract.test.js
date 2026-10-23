const test = require('node:test');
const assert = require('node:assert/strict');
const smsFacts = require('../src/sms_facts');

const spend = (amount = 250, merchant = 'SWIGGY') => ({
  factType: 'posted_movement',
  payload: {
    amountRole: 'posted',
    amountInr: amount,
    entryKind: 'spend',
    merchant,
    occurredAt: '2026-10-16T10:00:00.000Z',
    instrument: 'upi_bank',
  },
});

const balance = (amount = 8750.25) => ({
  factType: 'balance_snapshot',
  payload: {
    availableBalanceInr: amount,
    asOfAt: '2026-10-16T10:00:00.000Z',
  },
});

const billTotal = {
  factType: 'bill_obligation',
  payload: {
    amountRole: 'due_total',
    amountDueInr: 3000,
    dueDate: '2026-11-05T00:00:00.000Z',
    statementDate: '2026-10-12T00:00:00.000Z',
  },
};

const mandate = {
  factType: 'mandate_lifecycle',
  payload: {
    mandateStatus: 'registered',
    limitInr: 2000,
    merchant: 'NETFLIX',
    asOfAt: '2026-10-16T10:00:00.000Z',
  },
};

test('valid multi-fact set passes validation', () => {
  const result = smsFacts.validateFactSet([
    spend(1250.5, 'UPI-P2M to GROCERY_M'),
    balance(),
    billTotal,
    mandate,
  ]);
  assert.deepEqual(result, { valid: true, errors: [] });
});

test('amount/date role consistency is enforced per fact type', () => {
  const noDueDate = smsFacts.validateFact({
    ...billTotal,
    payload: { ...billTotal.payload, dueDate: undefined },
  });
  assert.equal(noDueDate.valid, false);
  assert.ok(noDueDate.errors.some((e) => e.includes("requires dueDate")));

  const nonePostedAmount = smsFacts.validateFact({
    ...billTotal,
    payload: { ...billTotal.payload, amountRole: 'due_total', amountDueInr: undefined, amountInr: 3000 },
  });
  assert.equal(nonePostedAmount.valid, false);
  assert.ok(nonePostedAmount.errors.some((e) => e.includes('requires a positive amountDueInr')));

  const ceilingOmitted = smsFacts.validateFact({
    ...mandate,
    payload: { ...mandate.payload, limitInr: undefined, amountInr: 2000 },
  });
  assert.equal(ceilingOmitted.valid, true);
});

test('a mandate ceiling can never be booked as posted money', () => {
  const result = smsFacts.validateFact({
    ...mandate,
    payload: { ...mandate.payload, amountRole: 'posted', amountInr: 2000 },
  });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('amountRole') || e.includes('carry')));
});

test('a verification alert carries no posted amount', () => {
  const clean = smsFacts.validateFact({
    factType: 'security_or_service_alert',
    payload: {
      alertKind: 'verification',
      occurredAt: '2026-10-16T10:00:00.000Z',
    },
  });
  assert.equal(clean.valid, true);
  const withAmount = smsFacts.validateFact({
    factType: 'security_or_service_alert',
    payload: {
      alertKind: 'verification',
      occurredAt: '2026-10-16T10:00:00.000Z',
      amountRole: 'posted',
      amountInr: 2000,
    },
  });
  assert.equal(withAmount.valid, false);
  assert.ok(withAmount.errors.some((e) => e.includes('OTP alert') || e.includes('due/posted')));
});

test('posted spend requires a merchant', () => {
  const result = smsFacts.validateFact({
    factType: 'posted_movement',
    payload: {
      amountRole: 'posted',
      amountInr: 500,
      entryKind: 'spend',
      occurredAt: '2026-10-16T10:00:00.000Z',
      instrument: 'credit_card',
    },
  });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('merchant')));
});

test('4-digit identity fields are shape-checked', () => {
  const result = smsFacts.validateFact({
    factType: 'card_identity_hint',
    payload: { last4: '432', asOfAt: '2026-10-16T10:00:00.000Z' },
  });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('last4 must be exactly 4 digits')));
});

test('fact indices are deterministic and order-independent', () => {
  const a = [spend(1250.5), balance(), billTotal, mandate];
  const b = [mandate, billTotal, balance(), spend(1250.5)];
  const ia = smsFacts.assignDeterministicIndices(a);
  const ib = smsFacts.assignDeterministicIndices(b);
  const keyOf = (facts) =>
    facts.map((f) => [f.factIndex, f.factType]).sort((x, y) => x[1].localeCompare(y[1], 'en'));
  assert.deepEqual(keyOf(ia), keyOf(ib));
  assert.deepEqual(
    ia.map((f) => f.factIndex),
    [...ia].sort((x, y) => x.factIndex - y.factIndex).map((f) => f.factIndex),
  );
});

/** Minimal pg-client double: tracks rows like the real tables do. */
function fakeClient() {
  const sources = new Map(); // key const profile|sourceKey -> id
  const sourceRows = new Map(); // sourceId -> {sender, body_hash, ...}
  const facts = new Map(); // const sourceId|factIndex -> row
  const overrides = new Map(); // const sourceId|factIndex -> patch
  let nextId = 1;
  const id = () => `id-${nextId++}`;
  let lastSql = '';
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
    get overrides() {
      return overrides;
    },
    get lastSql() {
      return lastSql;
    },
    async query(sql, params) {
      lastSql = sql;
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
      throw new Error(`fakeClient: unhandled SQL ${sql.split('\n')[0].slice(0, 60)}`);
    },
    async upsertOverride(sourceId, factIndex, patch) {
      overrides.set(`${sourceId}|${factIndex}`, { fact_index: factIndex, patch: JSON.stringify(patch) });
    },
  };
}

test('replaying one source recreates the same fact rows and ids', async () => {
  const client = fakeClient();
  const base = {
    sender: 'HDFCBK',
    bodyHash: smsFacts.bodyHashOf('HDFCBK', 'INR 1,250.50 debited...'),
    sourceKey: 'source-key-1',
    facts: [spend(1250.5), balance()],
  };
  const first = await smsFacts.upsertSmsSourceFacts(client, 'user-1', base);
  assert.equal(first.replayed, false);

  await new Promise((resolve) => setTimeout(resolve, 5));
  const secondRun = await smsFacts.upsertSmsSourceFacts(client, 'user-1', base);
  assert.equal(secondRun.replayed, true);
  assert.equal(secondRun.sourceId, first.sourceId);
  assert.deepEqual(
    secondRun.factIds.map((f) => [f.factIndex, f.id]),
    first.factIds.map((f) => [f.factIndex, f.id]),
  );
  // A different profile using the same sender/body gets fresh rows.
  const otherUser = await smsFacts.upsertSmsSourceFacts(client, 'user-2', base);
  assert.notEqual(otherUser.sourceId, first.sourceId);
});

test('user override wins on read and survives a replay', async () => {
  const client = fakeClient();
  const base = {
    sender: 'HDFCBK',
    bodyHash: smsFacts.bodyHashOf('HDFCBK', 'Rs.250 debited ...'),
    sourceKey: 'source-key-2',
    facts: [spend(250, 'GROCERY_M'), balance()],
  };
  const first = await smsFacts.upsertSmsSourceFacts(client, 'user-1', base);
  const spendFactId = first.factIds.find((f) => f.factIndex === 0)?.id; // deterministic slots
  // User says the swipe was actually 350: patch the posted amount.
  await client.upsertOverride(first.sourceId, 0, { amountInr: 350 });

  // A later replay of the same message does NOT restore the parser amount.
  await smsFacts.upsertSmsSourceFacts(client, 'user-1', base);

  const loaded = await smsFacts.loadSmsSourceFacts(client, 'user-1', 'source-key-2');
  assert.equal(loaded.errors.length, 0);
  const postedFact = loaded.facts.find((f) => f.factIndex === 0);
  assert.equal(postedFact.payload.amountInr, 350);
  assert.ok(!!spendFactId);
});

test('an invalid override is refused, never silently fallen back', async () => {
  const client = fakeClient();
  const base = {
    sender: 'X',
    bodyHash: smsFacts.bodyHashOf('X', 'y'),
    sourceKey: 'source-key-3',
    facts: [spend(250)],
  };
  const first = await smsFacts.upsertSmsSourceFacts(client, 'user-1', base);
  await client.upsertOverride(first.sourceId, 0, { amountInr: -5 });
  const loaded = await smsFacts.loadSmsSourceFacts(client, 'user-1', 'source-key-3');
  assert.ok(loaded.errors.length > 0);
});

test('body hash mirrors legacy normalization (sender case-insensitive) and pins the Dart parity value', () => {
  const h1 = smsFacts.bodyHashOf('HDFCBK', 'INR 1,250.50 debited from your A/c XX1234 on 16-10-26 for UPI-P2M to GROCERY_M. Avl bal Rs.8,750.25.');
  const h2 = smsFacts.bodyHashOf('hdfcbk', 'INR 1,250.50 debited from your A/c XX1234 on 16-10-26 for UPI-P2M to GROCERY_M. Avl bal Rs.8,750.25.');
  assert.equal(h1, h2);
  // Pinned so the Dart mirror must produce the identical hash for parity.
  assert.equal(
    h1,
    '28dd854f5c943a06f19a390121698bbf9e62f563585fcb3c0382b166f44558d5',
  );
});
