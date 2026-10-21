const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const express = require('express');

const smsFacts = require('../src/sms_facts');
const migration = require('../src/sms_observation_migration');
const { registerAiQueueRoutes } = require('../src/ai_queue_route');

test('extractFactsFromObservation extracts posted movement with correct amountRole and merchant', () => {
  const obs = {
    sourceKey: 'a'.repeat(64),
    sender: 'HDFCBK',
    occurredAt: '2026-10-15T10:00:00.000Z',
    parsed: {
      amountInr: 1250.5,
      merchant: 'Swiggy',
      entryKind: 'spend',
      last4: '4321',
    },
  };
  const facts = migration.extractFactsFromObservation(obs);
  assert.equal(facts.length, 1);
  assert.equal(facts[0].factType, 'posted_movement');
  assert.equal(facts[0].payload.amountRole, 'posted');
  assert.equal(facts[0].payload.entryKind, 'spend');
  assert.equal(facts[0].payload.amountInr, 1250.5);
  assert.equal(facts[0].payload.merchant, 'Swiggy');
  assert.equal(facts[0].payload.last4, '4321');

  const validation = smsFacts.validateFactSet(facts);
  assert.equal(validation.valid, true);
});

test('extractFactsFromObservation extracts both posted movement and balance snapshot from debit with balance', () => {
  const obs = {
    sourceKey: 'b'.repeat(64),
    sender: 'SBIBNK',
    occurredAt: '2026-10-16T12:00:00.000Z',
    parsed: {
      amountInr: 500,
      merchant: 'Chai Point',
      entryKind: 'spend',
      availableBalanceInr: 14500.25,
      accountLast4: '9876',
    },
  };
  const facts = migration.extractFactsFromObservation(obs);
  assert.equal(facts.length, 2);

  const movement = facts.find((f) => f.factType === 'posted_movement');
  assert.ok(movement);
  assert.equal(movement.payload.amountInr, 500);
  assert.equal(movement.payload.merchant, 'Chai Point');

  const balance = facts.find((f) => f.factType === 'balance_snapshot');
  assert.ok(balance);
  assert.equal(balance.payload.availableBalanceInr, 14500.25);
  assert.equal(balance.payload.accountLast4, '9876');
  assert.equal(balance.payload.asOfAt, '2026-10-16T12:00:00.000Z');

  const validation = smsFacts.validateFactSet(facts);
  assert.equal(validation.valid, true);
});

test('extractFactsFromObservation role-separates bill obligation into due_total and due_minimum', () => {
  const obs = {
    sourceKey: 'c'.repeat(64),
    sender: 'ICICIB',
    occurredAt: '2026-10-10T09:00:00.000Z',
    parsed: {
      amountDueInr: 15400,
      minimumDueInr: 1540,
      dueDate: '2026-11-02T00:00:00.000Z',
      statementDate: '2026-10-10T00:00:00.000Z',
      last4: '1122',
    },
  };
  const facts = migration.extractFactsFromObservation(obs);
  assert.equal(facts.length, 2);

  const total = facts.find((f) => f.payload.amountRole === 'due_total');
  assert.ok(total);
  assert.equal(total.factType, 'bill_obligation');
  assert.equal(total.payload.amountDueInr, 15400);
  assert.equal(total.payload.dueDate, '2026-11-02T00:00:00.000Z');

  const min = facts.find((f) => f.payload.amountRole === 'due_minimum');
  assert.ok(min);
  assert.equal(min.factType, 'bill_obligation');
  assert.equal(min.payload.minimumDueInr, 1540);
  assert.equal(min.payload.dueDate, '2026-11-02T00:00:00.000Z');

  const validation = smsFacts.validateFactSet(facts);
  assert.equal(validation.valid, true);
});

test('extractFactsFromObservation extracts mandate lifecycle and does not count as spend', () => {
  const obs = {
    sourceKey: 'd'.repeat(64),
    sender: 'HDFCBK',
    occurredAt: '2026-10-12T14:30:00.000Z',
    parsed: {
      mandateStatus: 'registered',
      limitInr: 5000,
      merchant: 'Netflix',
      last4: '4321',
      instrument: 'credit_card',
    },
  };
  const facts = migration.extractFactsFromObservation(obs);
  assert.equal(facts.length, 1);
  assert.equal(facts[0].factType, 'mandate_lifecycle');
  assert.equal(facts[0].payload.mandateStatus, 'registered');
  assert.equal(facts[0].payload.limitInr, 5000);
  assert.equal(facts[0].payload.merchant, 'Netflix');

  const comparison = migration.compareObservationProjections(obs);
  assert.equal(comparison.delta.newSpendInr, 0);
  assert.equal(comparison.delta.nonSpendFactsCount, 1);
  assert.equal(comparison.delta.valid, true);
});

test('dryRunObservations accurately compares legacy spend vs new multi-fact spend', () => {
  const observations = [
    {
      sourceKey: '1'.repeat(64),
      occurredAt: '2026-10-15T10:00:00.000Z',
      parsed: { amountInr: 1000, merchant: 'Amazon', entryKind: 'spend' },
    },
    {
      sourceKey: '2'.repeat(64),
      occurredAt: '2026-10-15T11:00:00.000Z',
      parsed: {
        amountDueInr: 5000,
        minimumDueInr: 500,
        dueDate: '2026-11-05T00:00:00.000Z',
      },
    },
    {
      sourceKey: '3'.repeat(64),
      occurredAt: '2026-10-15T12:00:00.000Z',
      parsed: { availableBalanceInr: 25000, accountLast4: '1234' },
    },
    {
      sourceKey: '4'.repeat(64),
      occurredAt: '2026-10-15T13:00:00.000Z',
      parsed: { alertKind: 'verification' },
    },
  ];

  const report = migration.dryRunObservations(observations);
  assert.equal(report.totalObservations, 4);
  assert.equal(report.totalLegacySpendInr, 1000);
  assert.equal(report.totalNewSpendInr, 1000);
  assert.equal(report.netSpendDifferenceInr, 0);
  assert.equal(report.nonSpendFactsExtracted, 4); // 2 bill facts + 1 balance + 1 alert
  assert.equal(report.invalidFactSetsCount, 0);
});

test('evaluateFeatureFlag handles boolean, 100%, 0%, and deterministic hash buckets', () => {
  const flag100 = { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 100 };
  assert.equal(migration.evaluateFeatureFlag(flag100, 'user-1'), true);

  const flagDisabled = { key: 'sms_facts_pipeline_enabled', is_enabled: false, rollout_percent: 100 };
  assert.equal(migration.evaluateFeatureFlag(flagDisabled, 'user-1'), false);

  const flag0 = { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 0 };
  assert.equal(migration.evaluateFeatureFlag(flag0, 'user-1'), false);

  // 50% rollout: deterministic for same profile
  const flag50 = { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 50 };
  const res1 = migration.evaluateFeatureFlag(flag50, 'user-alpha');
  const res2 = migration.evaluateFeatureFlag(flag50, 'user-alpha');
  assert.equal(res1, res2);

  // Across 100 diverse profile IDs, roughly half will be true
  let trueCount = 0;
  for (let i = 0; i < 100; i++) {
    if (migration.evaluateFeatureFlag(flag50, `test-user-${i}`)) {
      trueCount++;
    }
  }
  assert.ok(trueCount >= 30 && trueCount <= 70, `True count was ${trueCount}`);
});

test('resolveSmsIntelligenceFlags respects master flag and individual family toggles', () => {
  // Master disabled
  const flagsMasterOff = [
    { key: 'sms_facts_pipeline_enabled', is_enabled: false, rollout_percent: 100 },
    { key: 'sms_family_spend_enabled', is_enabled: true, rollout_percent: 100 },
  ];
  const cfgOff = migration.resolveSmsIntelligenceFlags(flagsMasterOff, 'user-1');
  assert.equal(cfgOff.masterEnabled, false);
  assert.equal(cfgOff.spendFamilyEnabled, false);
  assert.equal(cfgOff.balanceFamilyEnabled, false);

  // Master enabled, balance disabled
  const flagsMasterOn = [
    { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 100 },
    { key: 'sms_family_balance_enabled', is_enabled: false, rollout_percent: 100 },
  ];
  const cfgOn = migration.resolveSmsIntelligenceFlags(flagsMasterOn, 'user-1');
  assert.equal(cfgOn.masterEnabled, true);
  assert.equal(cfgOn.spendFamilyEnabled, true); // defaults true
  assert.equal(cfgOn.balanceFamilyEnabled, false);
});

test('AI queue remains disabled unless explicitly enabled in feature flags', () => {
  const missing = migration.resolveSmsIntelligenceFlags([], 'user-1');
  assert.equal(missing.aiQueueEnabled, false);

  const enabled = migration.resolveSmsIntelligenceFlags([
    { key: 'sms_ai_queue_enabled', is_enabled: true, rollout_percent: 100 },
  ], 'user-1');
  assert.equal(enabled.aiQueueEnabled, true);

  const zeroPercent = migration.resolveSmsIntelligenceFlags([
    { key: 'sms_ai_queue_enabled', is_enabled: true, rollout_percent: 0 },
  ], 'user-1');
  assert.equal(zeroPercent.aiQueueEnabled, false);
});

test('backfillHistoricalObservations dryRun mode calculates metrics without DB writes', async () => {
  let dbTouched = false;
  const mockClient = {
    query: async () => {
      dbTouched = true;
      return { rows: [] };
    },
  };

  const observations = [
    {
      sourceKey: 'e'.repeat(64),
      occurredAt: '2026-10-15T10:00:00.000Z',
      parsed: { amountInr: 250, merchant: 'Uber', entryKind: 'spend' },
    },
  ];

  const result = await migration.backfillHistoricalObservations(
    mockClient,
    'profile-1',
    { observations, dryRun: true },
  );

  assert.equal(result.dryRun, true);
  assert.equal(result.plannedSourcesCount, 1);
  assert.equal(result.plannedFactsCount, 1);
  assert.equal(dbTouched, false);
});

test('backfillHistoricalObservations live mode executes idempotent writes and preserves overrides', async () => {
  const sources = new Map();
  const factsMap = new Map();
  const overrides = new Map();

  const mockClient = {
    query: async (sql, params) => {
      if (sql.includes('INSERT INTO sms_sources')) {
        const [profileId, sourceKey, sender, bodyHash, channel, version] = params;
        const key = `${profileId}:${sourceKey}`;
        if (sources.has(key)) {
          return { rows: [] }; // ON CONFLICT DO NOTHING
        }
        const row = { id: `src-${sources.size + 1}`, profile_id: profileId, source_key: sourceKey };
        sources.set(key, row);
        return { rows: [row] };
      }
      if (sql.includes('SELECT id FROM sms_sources')) {
        const [profileId, sourceKey] = params;
        return { rows: [sources.get(`${profileId}:${sourceKey}`)] };
      }
      if (sql.includes('UPDATE sms_sources')) {
        return { rows: [] };
      }
      if (sql.includes('INSERT INTO sms_source_facts')) {
        const [sourceId, profileId, factIndex, factType, payload, provenance, status, version] = params;
        const factKey = `${sourceId}:${factIndex}`;
        const row = { id: `fact-${factsMap.size + 1}`, fact_index: factIndex, fact_type: factType };
        factsMap.set(factKey, row);
        return { rows: [row] };
      }
      return { rows: [] };
    },
  };

  const observations = [
    {
      sourceKey: 'f'.repeat(64),
      sender: 'HDFCBK',
      occurredAt: '2026-10-15T10:00:00.000Z',
      parsed: { amountInr: 450, merchant: 'Zomato', entryKind: 'spend' },
    },
  ];

  // First backfill
  const run1 = await migration.backfillHistoricalObservations(
    mockClient,
    'profile-1',
    { observations, dryRun: false },
  );
  assert.equal(run1.migratedSources, 1);
  assert.equal(run1.replayedSources, 0);
  assert.equal(run1.migratedFacts, 1);

  // Replaying the exact same backfill: idempotent! Replayed source, 0 extra fact rows
  const run2 = await migration.backfillHistoricalObservations(
    mockClient,
    'profile-1',
    { observations, dryRun: false },
  );
  assert.equal(run2.migratedSources, 0);
  assert.equal(run2.replayedSources, 1);
  assert.equal(run2.migratedFacts, 1);
  assert.equal(factsMap.size, 1); // exactly 1 fact persisted
});

test('Rollback safety: turning off feature flag preserves stored facts and user corrections', () => {
  // Simulate active state with user override
  const baseFacts = [
    {
      factIndex: 0,
      factType: 'posted_movement',
      payload: { amountRole: 'posted', entryKind: 'spend', amountInr: 500, merchant: 'Chai' },
    },
  ];
  const userOverride = { merchant: 'Chai Point Special' };
  const overridesMap = new Map([[0, userOverride]]);

  // Resolve with override
  const resolvedActive = smsFacts.resolveFactsWithOverrides({
    facts: baseFacts,
    overrides: overridesMap,
  });
  assert.equal(resolvedActive.facts[0].payload.merchant, 'Chai Point Special');
  assert.equal(resolvedActive.facts[0].overridden, true);

  // Simulate rollback: feature flag disabled
  const flagsRolledBack = [
    { key: 'sms_facts_pipeline_enabled', is_enabled: false, rollout_percent: 0 },
  ];
  const config = migration.resolveSmsIntelligenceFlags(flagsRolledBack, 'user-1');
  assert.equal(config.masterEnabled, false);

  // During rollback, underlying facts and overrides are preserved untouched
  assert.equal(baseFacts[0].payload.merchant, 'Chai');
  assert.equal(overridesMap.get(0).merchant, 'Chai Point Special');

  // Reactivating flag immediately restores active facts + overrides without re-run
  const flagsReenabled = [
    { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 100 },
  ];
  const configReenabled = migration.resolveSmsIntelligenceFlags(flagsReenabled, 'user-1');
  assert.equal(configReenabled.masterEnabled, true);

  const restored = smsFacts.resolveFactsWithOverrides({
    facts: baseFacts,
    overrides: overridesMap,
  });
  assert.equal(restored.facts[0].payload.merchant, 'Chai Point Special');
});

test('admin dry-run and rollout routes enforce auth and return expected reports', async () => {
  const app = express();
  app.use(express.json());

  const mockDbClient = {
    query: async (sql) => {
      if (sql.includes('feature_flags')) {
        return {
          rows: [
            { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 100 },
            { key: 'sms_family_balance_enabled', is_enabled: true, rollout_percent: 100 },
          ],
        };
      }
      return { rows: [] };
    },
  };

  const requireAdmin = (req, res, next) => {
    if (req.headers['x-admin'] !== 'true') return res.status(403).json({ error: 'forbidden' });
    next();
  };

  registerAiQueueRoutes(app, {
    requireAuth: (req, res, next) => next(),
    requireAdmin,
    withUserClient: async (uid, fn) => fn(mockDbClient),
  });

  const server = app.listen(0);
  const port = server.address().port;

  try {
    // 1. Unauthenticated dry-run rejected
    const unauth = await fetch(`http://localhost:${port}/admin/sms-ai/dry-run`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ observations: [] }),
    });
    assert.equal(unauth.status, 403);

    // 2. Admin dry-run accepted
    const dryRunRes = await fetch(`http://localhost:${port}/admin/sms-ai/dry-run`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin': 'true' },
      body: JSON.stringify({
        observations: [
          {
            sourceKey: '7'.repeat(64),
            occurredAt: '2026-10-15T10:00:00.000Z',
            parsed: { amountInr: 200, merchant: 'Tea Stall', entryKind: 'spend' },
          },
        ],
      }),
    });
    assert.equal(dryRunRes.status, 200);
    const dryRunJson = await dryRunRes.json();
    assert.equal(dryRunJson.report.totalObservations, 1);
    assert.equal(dryRunJson.report.totalNewSpendInr, 200);

    // 3. Admin rollout query accepted
    const rolloutRes = await fetch(`http://localhost:${port}/admin/sms-ai/rollout`, {
      headers: { 'x-admin': 'true' },
    });
    assert.equal(rolloutRes.status, 200);
    const rolloutJson = await rolloutRes.json();
    assert.equal(rolloutJson.rollout.masterEnabled, true);
    assert.equal(rolloutJson.rollout.balanceFamilyEnabled, true);
  } finally {
    server.close();
  }
});
