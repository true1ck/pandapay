const test = require('node:test');
const assert = require('node:assert/strict');
const projection = require('../src/central_financial_projection');
const smsFacts = require('../src/sms_facts');

const mandate = (overrides = {}) => ({
  id: 'fact-mandate',
  factIndex: 0,
  factType: 'mandate_lifecycle',
  status: 'active',
  payload: {
    mandateStatus: 'registered',
    activationAmountInr: 0,
    limitInr: 1999,
    merchant: 'OPENAILLC',
    instrument: 'credit_card',
    last4: '7105',
    asOfAt: '2026-10-16T10:00:00.000Z',
    ...overrides,
  },
});

test('named service mandate projects unpriced setup presence without spend', () => {
  const decisions = projection.buildProjectionDecisions({
    sourceId: 'source-1', sourceKey: 'a'.repeat(64), facts: [mandate()],
  });
  const mandateDecision = decisions.find((item) => item.projectionKind === 'mandate');
  const service = decisions.find((item) => item.projectionKind === 'subscription');
  assert.ok(mandateDecision);
  assert.ok(service);
  assert.equal(mandateDecision.status, 'active');
  assert.equal(mandateDecision.data.authorizationLimitInr, 1999);
  assert.equal(mandateDecision.data.activationAmountInr, 0);
  assert.equal(service.status, 'candidate');
  assert.equal(service.data.lifecycleReason, 'mandate_authorization_setup');
  assert.equal(service.data.subscriptionEvidence, 'mandate_authorization');
  assert.equal(service.data.setupConfirmed, true);
  assert.equal(service.data.statedNextPaymentAmountInr, null);
  assert.equal(service.data.statedNextPaymentDate, null);
  assert.equal(service.data.lastPostedPayment, null);
  assert.equal(decisions.some((item) => item.projectionKind === 'subscription'), true);
  assert.equal(decisions.some((item) => item.projectionKind === 'movement'), false);
});

test('named service mandate remains a setup presence when no ceiling is supplied', () => {
  const decisions = projection.buildProjectionDecisions({
    facts: [mandate({ limitInr: undefined, targetKind: 'service_merchant' })],
  });
  const service = decisions.find((item) => item.projectionKind === 'subscription');
  const mandateDecision = decisions.find((item) => item.projectionKind === 'mandate');
  assert.ok(service);
  assert.equal(service.data.setupConfirmed, true);
  assert.equal(mandateDecision.data.authorizationLimitInr, null);
  assert.equal(service.data.statedNextPaymentAmountInr, null);
  assert.equal(service.data.cadenceDays, null);
  assert.equal(decisions.some((item) => item.projectionKind === 'movement'), false);
});

test('merchant spelling variants share one service identity', () => {
  const llc = projection.buildProjectionDecisions({ facts: [mandate()] })
    .find((item) => item.projectionKind === 'subscription');
  const plain = projection.buildProjectionDecisions({ facts: [mandate({ merchant: 'OpenAI' })] })
    .find((item) => item.projectionKind === 'subscription');
  assert.equal(llc.projectionKey, plain.projectionKey);
});

test('explicit service evidence can create a subscription while keeping mandate fields separate', () => {
  const decisions = projection.buildProjectionDecisions({
    facts: [mandate({ explicitSubscription: true, serviceName: 'ChatGPT', planName: 'Plus', renewalMode: 'automatic', nextPaymentDate: '2026-11-16T00:00:00.000Z', nextPaymentAmountInr: 499 })],
  });
  const service = decisions.find((item) => item.projectionKind === 'subscription');
  assert.ok(service);
  assert.equal(service.status, 'active');
  assert.equal(service.data.statedNextPaymentAmountInr, 499);
  assert.equal(service.data.lastPostedPayment, null);
  assert.equal(decisions.find((item) => item.projectionKind === 'mandate').data.authorizationLimitInr, 1999);
});

test('bill and posted movement facts remain separate from subscriptions', () => {
  const bill = {
    id: 'fact-bill', factIndex: 1, factType: 'bill_obligation', status: 'active',
    payload: { amountRole: 'due_total', amountDueInr: 3000, dueDate: '2026-11-05T00:00:00.000Z', billerName: 'AXIS CARD', last4: '7105' },
  };
  const movement = {
    id: 'fact-spend', factIndex: 2, factType: 'posted_movement', status: 'active',
    payload: { amountRole: 'posted', amountInr: 1999, entryKind: 'spend', merchant: 'OPENAILLC', occurredAt: '2026-10-16T10:00:00.000Z' },
  };
  const decisions = projection.buildProjectionDecisions({ facts: [bill, movement] });
  assert.equal(decisions.filter((item) => item.projectionKind === 'bill_obligation').length, 1);
  assert.equal(decisions.filter((item) => item.projectionKind === 'movement').length, 1);
  assert.equal(decisions.filter((item) => item.projectionKind === 'subscription').length, 0);
});

test('new projection fields remain valid under the typed fact contract', () => {
  const result = smsFacts.validateFact(mandate({
    targetKind: 'service_merchant', explicitSubscription: true,
    renewalMode: 'automatic', cadenceDays: 30, cadenceExplicit: true,
  }));
  assert.deepEqual(result, { valid: true, errors: [] });
});

test('AI suggestions cannot become projections until explicitly corrected', () => {
  const fact = { ...mandate(), provenance: { channel: 'ai' } };
  assert.deepEqual(projection.buildProjectionDecisions({ facts: [fact] }), []);
  const confirmed = smsFacts.resolveFactsWithOverrides({
    facts: [fact], overrides: new Map([[0, { merchant: 'NETFLIX' }]]),
  });
  assert.deepEqual(confirmed.errors, []);
  assert.deepEqual(projection.buildProjectionDecisions(confirmed)
    .map((item) => item.projectionKind), ['mandate', 'subscription']);
});

test('cancelled service mandates retain lifecycle without manufacturing a payment', () => {
  const decisions = projection.buildProjectionDecisions({ facts: [mandate({ mandateStatus: 'cancelled' })] });
  const mandateDecision = decisions.find((item) => item.projectionKind === 'mandate');
  const service = decisions.find((item) => item.projectionKind === 'subscription');
  assert.ok(mandateDecision);
  assert.ok(service);
  assert.equal(mandateDecision.status, 'cancelled');
  assert.equal(service.status, 'cancelled');
  assert.equal(decisions.some((item) => item.projectionKind === 'movement'), false);
});

test('actual Axis OpenAI setup fixture keeps the zero activation and ceiling out of spend', () => {
  // This is the typed representation of the production-shaped setup alert:
  // "AutoPay registered for OPENAILLC ... Rs.1,999 ... card ending 7105".
  // It deliberately has no posted amount or future payment claim.
  const fact = {
    id: 'f5e2b7a9-26fb-43f6-86c9-9fbc2c1a9b11',
    factIndex: 0,
    factType: 'mandate_lifecycle',
    status: 'active',
    payload: {
      mandateStatus: 'registered',
      amountRole: 'ceiling',
      limitInr: 1999,
      activationAmountInr: 0,
      merchant: 'OPENAILLC',
      targetKind: 'service_merchant',
      instrument: 'credit_card',
      last4: '7105',
      asOfAt: '2026-10-16T10:00:00.000Z',
    },
  };
  const decisions = projection.buildProjectionDecisions({ facts: [fact] });
  assert.deepEqual(decisions.map((item) => item.projectionKind), ['mandate', 'subscription']);
  assert.equal(decisions[0].data.authorizationLimitInr, 1999);
  assert.equal(decisions[0].data.activationAmountInr, 0);
  assert.equal(decisions[0].data.merchant, 'OPENAILLC');
  assert.equal(decisions[1].status, 'candidate');
  assert.equal(decisions[1].data.statedNextPaymentAmountInr, null);
  assert.equal(decisions[1].data.lastPostedPayment, null);
});

test('card and utility autopay mandates stay mandate-only', () => {
  const card = mandate({ targetKind: 'card_bill', merchant: undefined, explicitSubscription: true });
  const utility = mandate({ targetKind: 'utility_or_other_bill', merchant: undefined, billerName: 'BESCOM', explicitSubscription: true });
  for (const fact of [card, utility]) {
    const decisions = projection.buildProjectionDecisions({ facts: [fact] });
    assert.equal(decisions.filter((item) => item.projectionKind === 'mandate').length, 1);
    assert.equal(decisions.some((item) => item.projectionKind === 'subscription'), false);
  }
});

test('service semantics, rather than a ceiling amount, control setup presence', () => {
  const utility = mandate({
    targetKind: 'utility_or_other_bill',
    merchant: undefined,
    billerName: 'BESCOM',
    limitInr: undefined,
  });
  const service = mandate({
    targetKind: 'service_merchant',
    merchant: 'OPENAILLC',
    limitInr: undefined,
  });
  const utilityDecisions = projection.buildProjectionDecisions({ facts: [utility] });
  const serviceDecisions = projection.buildProjectionDecisions({ facts: [service] });
  assert.equal(utilityDecisions.some((item) => item.projectionKind === 'subscription'), false);
  assert.equal(serviceDecisions.some((item) => item.projectionKind === 'subscription'), true);
});

test('generic merchant mandate does not imply a subscription', () => {
  const decisions = projection.buildProjectionDecisions({
    facts: [mandate({ merchant: 'LOCAL GROCERY SHOP', targetKind: 'service_merchant' })],
  });
  assert.equal(decisions.filter((item) => item.projectionKind === 'mandate').length, 1);
  assert.equal(decisions.some((item) => item.projectionKind === 'subscription'), false);
});

test('legacy known service mandate row gets an unpriced setup fallback', () => {
  const fallback = projection.legacyMandateSetupRow({
    id: 'legacy-openai', display_name: 'OPENAILLC', detection_source: 'mandate',
    typical_amount_inr: 1999, cadence_days: 30, next_expected_on: '2026-11-15',
  });
  assert.ok(fallback);
  assert.equal(fallback.display_name, 'OpenAI');
  assert.equal(fallback.typical_amount_inr, null);
  assert.equal(fallback.cadence_days, null);
  assert.equal(fallback.next_expected_on, null);
  assert.equal(projection.legacyMandateSetupRow({
    display_name: 'AXIS Credit Card Bill', detection_source: 'mandate',
  }), null);
  assert.equal(projection.legacyMandateSetupRow({
    display_name: 'Local Grocery Shop', detection_source: 'mandate',
  }), null);
});

test('same source facts coalesce into one subscription with complete evidence lineage', () => {
  const facts = [
    mandate({
      id: 'f5e2b7a9-26fb-43f6-86c9-9fbc2c1a9b11',
      explicitSubscription: true,
      serviceName: 'ChatGPT',
      planName: 'Plus',
      renewalMode: 'automatic',
      nextPaymentDate: '2026-11-16T00:00:00.000Z',
      nextPaymentAmountInr: 499,
    }),
    {
      id: 'bf9ddf51-12c5-4802-becf-2d58c8432b1d',
      factIndex: 1,
      factType: 'security_or_service_alert',
      status: 'active',
      payload: {
        alertKind: 'service',
        occurredAt: '2026-10-16T10:00:00.000Z',
        explicitSubscription: true,
        serviceName: 'ChatGPT',
        planName: 'Plus',
        renewalMode: 'automatic',
      },
    },
  ];
  const decisions = projection.coalesceDecisions(
    projection.buildProjectionDecisions({ sourceId: 'source-1', facts }),
  );
  const subscriptions = decisions.filter((item) => item.projectionKind === 'subscription');
  assert.equal(subscriptions.length, 1);
  assert.deepEqual(subscriptions[0].factIds.sort(), [facts[0].id, facts[1].id].sort());
  assert.equal(subscriptions[0].data.statedNextPaymentAmountInr, 499);
  assert.equal(subscriptions[0].data.evidenceSources.length, 2);
});

test('replaying one source does not delete a shared subscription projection', async () => {
  const rows = [];
  const sourceA = 'f5e2b7a9-26fb-43f6-86c9-9fbc2c1a9b11';
  const sourceB = 'bf9ddf51-12c5-4802-becf-2d58c8432b1d';
  const sourceC = 'a1a1a1a1-4444-4444-8444-444444444444';
  const factA = 'c4c4c4c4-1111-4111-8111-111111111111';
  const factB = 'd5d5d5d5-2222-4222-8222-222222222222';
  const factC = 'b2b2b2b2-5555-4555-8555-555555555555';
  const profileId = 'e6e6e6e6-3333-4333-8333-333333333333';
  const client = {
    async query(sql, params = []) {
      if (sql.includes('SELECT projection_kind, projection_key, source_fact_ids')) {
        return { rows: rows
          .filter((row) => row.profile_id === params[0] && row.source_id === params[1])
          .map((row) => ({ projection_kind: row.projection_kind, projection_key: row.projection_key, source_fact_ids: row.source_fact_ids })) };
      }
      if (sql.includes('SELECT id, source_id') && sql.includes('sms_source_facts')) {
        const owners = new Map([[factA, sourceA], [factB, sourceB], [factC, sourceC]]);
        return { rows: params[1].filter((id) => owners.has(id)).map((id) => ({ id, source_id: owners.get(id) })) };
      }
      if (sql.includes('DELETE FROM financial_projections')) {
        for (let index = rows.length - 1; index >= 0; index -= 1) {
          if (rows[index].profile_id === params[0] && rows[index].source_id === params[1] &&
              rows[index].projection_kind === params[2] && rows[index].projection_key === params[3]) rows.splice(index, 1);
        }
        return { rows: [] };
      }
      if (sql.includes('INSERT INTO financial_projections')) {
        const [profile, kind, key, status, json, sourceId, sourceKey, ids, version] = params;
        const existing = rows.find((row) => row.profile_id === profile && row.projection_kind === kind && row.projection_key === key);
        if (existing) {
          const incoming = JSON.parse(json);
          const existingStrong = existing.projection.setupConfirmed === true
            || existing.projection.explicitSubscription === true
            || existing.projection.lastPostedPayment !== null && existing.projection.lastPostedPayment !== undefined
            || ['explicit', 'user_asserted', 'posted', 'historical', 'brand_prior'].includes(existing.projection.subscriptionEvidence);
          const weakCandidate = kind === 'subscription' && status === 'candidate' && incoming.setupConfirmed === true;
          if (!(weakCandidate && existingStrong)) {
            existing.status = status;
          }
          if (!(kind === 'subscription' && incoming.setupConfirmed === true && existingStrong)) {
            existing.projection = incoming;
          }
          existing.source_id = existing.source_id === sourceId ? sourceId : existing.source_id;
          existing.source_key = existing.source_id === sourceId ? sourceKey : existing.source_key;
          existing.source_fact_ids = [...new Set([...(existing.source_fact_ids || []), ...ids])];
          existing.projection_version = version;
        } else {
          rows.push({ profile_id: profile, projection_kind: kind, projection_key: key, status,
            projection: JSON.parse(json), source_id: sourceId, source_key: sourceKey,
            source_fact_ids: ids, projection_version: version });
        }
        return { rows: [] };
      }
      if (sql.includes('UPDATE sms_sources')) return { rows: [] };
      throw new Error(`unexpected SQL: ${sql}`);
    },
  };
  const serviceFact = {
    id: factB, factType: 'security_or_service_alert', status: 'active',
    payload: {
      explicitSubscription: true,
      serviceName: 'OPENAILLC',
      renewalMode: 'automatic',
      nextPaymentDate: '2026-11-16T00:00:00.000Z',
      nextPaymentAmountInr: 499,
    },
  };
  await projection.persistFinancialProjections(client, profileId, {
    sourceId: sourceA, sourceKey: 'a'.repeat(64), facts: [mandate({ id: factA })],
  });
  await projection.persistFinancialProjections(client, profileId, {
    sourceId: sourceB, sourceKey: 'b'.repeat(64), facts: [serviceFact],
  });
  assert.equal(rows.filter((row) => row.projection_kind === 'subscription').length, 1);
  const shared = rows.find((row) => row.projection_kind === 'subscription');
  assert.equal(shared.status, 'active');
  assert.equal(shared.projection.explicitSubscription, true);
  assert.equal(shared.projection.statedNextPaymentAmountInr, 499);
  // A later setup-only mandate cannot erase explicit service evidence.
  await projection.persistFinancialProjections(client, profileId, {
    sourceId: sourceA, sourceKey: 'a'.repeat(64), facts: [mandate({ id: factA })],
  });
  assert.equal(shared.status, 'active');
  assert.equal(shared.projection.explicitSubscription, true);
  await projection.persistFinancialProjections(client, profileId, {
    sourceId: sourceC, sourceKey: 'c'.repeat(64),
    facts: [mandate({ id: factC, mandateStatus: 'cancelled' })],
  });
  assert.equal(shared.status, 'cancelled');
  assert.equal(shared.projection.statedNextPaymentAmountInr, 499);
  await projection.persistFinancialProjections(client, profileId, {
    sourceId: sourceA, sourceKey: 'a'.repeat(64), facts: [],
  });
  assert.equal(rows.filter((row) => row.projection_kind === 'mandate').length, 0);
  assert.equal(rows.filter((row) => row.projection_kind === 'subscription').length, 1);
});

test('explicit service status follows a cancelled mandate lifecycle safely', () => {
  const decisions = projection.buildProjectionDecisions({
    facts: [mandate({
      explicitSubscription: true,
      serviceName: 'ChatGPT',
      mandateStatus: 'cancelled',
    })],
  });
  const service = decisions.find((item) => item.projectionKind === 'subscription');
  assert.ok(service);
  assert.equal(service.status, 'cancelled');
});

test('unrecognized subscription status is read as unknown', () => {
  const [service] = projection.buildProjectionDecisions({
    facts: [{
      id: 'bf9ddf51-12c5-4802-becf-2d58c8432b1d',
      factType: 'security_or_service_alert',
      status: 'active',
      payload: {
        alertKind: 'service',
        occurredAt: '2026-10-16T10:00:00.000Z',
        explicitSubscription: true,
        serviceName: 'ChatGPT',
        subscriptionStatus: 'not-a-status',
      },
    }],
  });
  assert.equal(service.status, 'unknown');
});

test('source replay removes projections that a correction no longer supports', async () => {
  const rows = [];
  const client = {
    async query(sql, params = []) {
      if (sql.includes('SELECT projection_kind, projection_key, source_fact_ids')) {
        return { rows: rows
          .filter((row) => row.profile_id === params[0] && row.source_id === params[1])
          .map((row) => ({ projection_kind: row.projection_kind, projection_key: row.projection_key, source_fact_ids: row.source_fact_ids || [] })) };
      }
      if (sql.includes('SELECT id, source_id') && sql.includes('sms_source_facts')) return { rows: [] };
      if (sql.includes('DELETE FROM financial_projections')) {
        for (let index = rows.length - 1; index >= 0; index -= 1) {
          if (rows[index].profile_id === params[0] && rows[index].source_id === params[1] &&
              rows[index].projection_kind === params[2] && rows[index].projection_key === params[3]) {
            rows.splice(index, 1);
          }
        }
        return { rows: [] };
      }
      if (sql.includes('INSERT INTO financial_projections')) {
        const [profileId, kind, key, status, projection, sourceId, sourceKey, factIds, version] = params;
        const existing = rows.find((row) => row.profile_id === profileId && row.projection_kind === kind && row.projection_key === key);
        const value = { profile_id: profileId, projection_kind: kind, projection_key: key, status,
          projection: JSON.parse(projection), source_id: sourceId, source_key: sourceKey, source_fact_ids: factIds, projection_version: version };
        if (existing) Object.assign(existing, value);
        else rows.push(value);
        return { rows: [] };
      }
      if (sql.includes('UPDATE sms_sources')) return { rows: [] };
      throw new Error(`unexpected SQL: ${sql}`);
    },
  };
  const sourceId = 'f5e2b7a9-26fb-43f6-86c9-9fbc2c1a9b11';
  const profileId = 'c4c4c4c4-1111-4111-8111-111111111111';
  await projection.persistFinancialProjections(client, profileId, {
    sourceId,
    sourceKey: 'a'.repeat(64),
    facts: [mandate({ id: 'bf9ddf51-12c5-4802-becf-2d58c8432b1d' })],
  });
  assert.equal(rows.length, 2);
  await projection.persistFinancialProjections(client, profileId, {
    sourceId,
    sourceKey: 'a'.repeat(64),
    facts: [],
  });
  assert.equal(rows.length, 0);
});

test('historical source with no projectable fact gets a durable checkpoint', async () => {
  const calls = [];
  const profileId = 'c4c4c4c4-1111-4111-8111-111111111111';
  const sourceId = 'f5e2b7a9-26fb-43f6-86c9-9fbc2c1a9b11';
  const sourceKey = 'a'.repeat(64);
  const client = {
    async query(sql, params = []) {
      calls.push({ sql, params });
      if (sql.includes('FROM sms_sources') && sql.includes('projection_version <')) {
        return { rows: [{ id: sourceId, source_key: sourceKey }] };
      }
      if (sql.includes('FROM sms_sources WHERE profile_id')) {
        return { rows: [{ id: sourceId, sender: 'BANK', body_hash: 'b'.repeat(64), contract_version: 1 }] };
      }
      if (sql.includes('FROM sms_source_facts')) return { rows: [] };
      if (sql.includes('FROM fact_overrides')) return { rows: [] };
      if (sql.includes('SELECT projection_kind, projection_key, source_fact_ids')) return { rows: [] };
      if (sql.includes('UPDATE sms_sources')) return { rows: [] };
      throw new Error(`unexpected SQL: ${sql}`);
    },
  };
  assert.equal(await projection.backfillFinancialProjections(client, profileId), 1);
  const checkpoint = calls.find((call) => call.sql.includes('UPDATE sms_sources'));
  assert.deepEqual(checkpoint.params, [profileId, sourceId, projection.PROJECTION_VERSION]);
  assert.equal(calls.some((call) => call.sql.includes('INSERT INTO financial_projections')), false);
});
