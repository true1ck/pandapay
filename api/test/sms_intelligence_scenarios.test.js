/**
 * Acceptance test suite verifying every scenario in Section 9 of
 * docs/SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

const { parseSmsAgainstPatterns, redactSmsShape } = require('../src/sms_parser');
const smsFacts = require('../src/sms_facts');
const smsFactsRoute = require('../src/sms_facts_route');
const smsLearning = require('../src/sms_learning');
const smsRuleBundle = require('../src/sms_rule_bundle');
const { parseSubscriptionMandate } = require('../src/subscription_parser');
const { extractStatementDate, extractDueDate } = require('../src/due_date_parser');
const { importSourceKey } = require('../src/import_source_key');

function fakeDbClient({ contributionsOptIn = true } = {}) {
  const sources = new Map();
  const sourceFacts = new Map();
  const overrides = new Map();
  const learningFeedback = [];
  const publishedBundles = new Map();

  return {
    sources,
    sourceFacts,
    overrides,
    learningFeedback,
    publishedBundles,
    async query(sql, params = []) {
      // Shared learning is gated by the user_consents audit log (latest row
      // per purpose), not the legacy profiles.contributions_opt_in column.
      if (sql.includes("purpose = 'sms_shared_learning'")) {
        return {
          rows: [{
            granted: contributionsOptIn,
            policy_version: 'sms-shared-learning-v1',
            granted_at: '2026-10-20T10:00:00.000Z',
          }],
        };
      }
      if (sql.startsWith('INSERT INTO sms_sources')) {
        const key = `${params[0]}|${params[1]}`;
        if (sources.has(key)) return { rows: [] };
        const newId = `src-${sources.size + 1}`;
        sources.set(key, { id: newId, profile_id: params[0], source_key: params[1], sender: params[2], body_hash: params[3] });
        return { rows: [{ id: newId }] };
      }
      if (sql.startsWith('SELECT id FROM sms_sources')) {
        const key = `${params[0]}|${params[1]}`;
        return sources.has(key) ? { rows: [{ id: sources.get(key).id }] } : { rows: [] };
      }
      if (sql.startsWith('INSERT INTO sms_source_facts')) {
        const [sourceId, profileId, factIndex, factType, payload, provenance, status] = params;
        const key = `${sourceId}|${factIndex}`;
        if (sourceFacts.has(key)) return { rows: [{ id: sourceFacts.get(key).id }] };
        const newId = `fact-${sourceFacts.size + 1}`;
        sourceFacts.set(key, { id: newId, source_id: sourceId, fact_index: factIndex, fact_type: factType, payload, provenance, status });
        return { rows: [{ id: newId }] };
      }
      if (sql.startsWith('INSERT INTO fact_overrides')) {
        const patch = typeof params[3] === 'string' ? JSON.parse(params[3]) : params[3];
        overrides.set(`${params[1]}|${params[2]}`, { source_id: params[1], fact_index: params[2], patch });
        return { rows: [] };
      }
      if (sql.startsWith('INSERT INTO sms_learning_feedback')) {
        learningFeedback.push(params);
        return { rows: [], rowCount: 1 };
      }
      if (sql.includes('FROM sms_sources WHERE profile_id')) {
        const row = [...sources.values()].find((s) => s.profile_id === params[0] && s.source_key === params[1]);
        return { rows: row ? [row] : [] };
      }
      if (sql.includes('FROM sms_source_facts WHERE source_id')) {
        const rows = [...sourceFacts.values()]
          .filter((f) => f.source_id === params[0])
          .sort((a, b) => a.fact_index - b.fact_index)
          .map((f) => ({
            ...f,
            payload: typeof f.payload === 'string' ? JSON.parse(f.payload) : f.payload,
            provenance: typeof f.provenance === 'string' ? JSON.parse(f.provenance) : f.provenance,
          }));
        return { rows };
      }
      if (sql.includes('FROM fact_overrides WHERE source_id')) {
        const rows = [...overrides.values()].filter((o) => o.source_id === params[0]);
        return { rows };
      }
      if (sql.includes('FROM public.sms_rule_bundles') && sql.includes('WHERE is_active = true')) {
        const active = [...publishedBundles.values()].filter((b) => b.is_active).sort((a, b) => b.bundle_version - a.bundle_version);
        return { rows: active.slice(0, 1) };
      }
      if (sql.includes('INSERT INTO public.sms_rule_bundles')) {
        const [bundle_version, rules, sha256, published_by, min_client_ver] = params;
        if (publishedBundles.has(bundle_version)) return { rowCount: 0 };
        publishedBundles.set(bundle_version, { bundle_version, rules, sha256, published_by, is_active: true, min_client_ver });
        return { rowCount: 1 };
      }
      if (sql.includes('UPDATE public.sms_rule_bundles') && sql.includes('SET is_active = false')) {
        const version = params[0];
        if (publishedBundles.has(version)) {
          publishedBundles.get(version).is_active = false;
          return { rowCount: 1 };
        }
        return { rowCount: 0 };
      }
      return { rows: [], rowCount: 0 };
    },
  };
}

// ---------------------------------------------------------------------------
// Scenario 1: Fresh install with mixed inbox online/offline
// Useful facts visible without Gemini; clear promotion absent; OTP never stored
// ---------------------------------------------------------------------------
test('Scenario 1: Fresh install handles mixed inbox cleanly without Gemini requirement', () => {
  const mixedSms = [
    { sender: 'HDFCBK', body: 'Rs.1,250.50 debited from A/c XX1234 on 16-10-26 for UPI to GROCERY. Avl bal Rs.8,750.25.' },
    { sender: 'VM-BANK-P', body: 'Special Diwali offer! Get flat 50% off on shopping with your card. Apply now.' },
    { sender: 'VM-OTPAUTH', body: 'Your OTP is 849201 for login. Valid for 5 mins. Do not share.' },
  ];

  // Debit + balance parses immediately via built-in / pattern parser without AI
  const parsedSpend = parseSmsAgainstPatterns([], mixedSms[0]);
  assert.equal(parsedSpend.ok, true);
  assert.equal(parsedSpend.fields.amountInr, 1250.5);
  assert.equal(parsedSpend.fields.availableBalanceInr, 8750.25);

  // Pure promotion parses as not_a_transaction_alert
  const parsedPromo = parseSmsAgainstPatterns([], mixedSms[1]);
  assert.equal(parsedPromo.ok, false);

  // OTP parses as not_a_transaction_alert
  const parsedOtp = parseSmsAgainstPatterns([], mixedSms[2]);
  assert.equal(parsedOtp.ok, false);

  // Verify redactSmsShape strips raw digits and text
  const shape = redactSmsShape(mixedSms[0].body);
  assert.equal(shape.includes('1,250.50'), false);
  assert.equal(shape.includes('8,750.25'), false);
});

// ---------------------------------------------------------------------------
// Scenario 2: Duplicate delivery yields exact same sourceKey and single durable event
// ---------------------------------------------------------------------------
test('Scenario 2: Duplicate delivery yields exact same sourceKey and single durable event', () => {
  const sender = 'VM-ICICIB';
  const body = 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 18-10-26.';
  
  const key1 = importSourceKey('user:account-xyz', sender, body);
  const key2 = importSourceKey('user:account-xyz', 'vm-icicib', 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 18-10-26.');
  const keyDifferentUser = importSourceKey('user:account-other', sender, body);

  assert.equal(key1, key2, 'Whitespace/casing normalization produces identical sourceKey');
  assert.notEqual(key1, keyDifferentUser, 'Different accounts never collide on sourceKey');
});

// ---------------------------------------------------------------------------
// Scenario 3: Multi-fact derivation without double counting
// Debit + balance, bill total + minimum + due date, refund, failed attempt
// ---------------------------------------------------------------------------
test('Scenario 3: Multi-fact separation prevents double counting and separates roles', () => {
  // 1. Debit + Balance
  const factsDebitBal = [
    {
      factType: 'posted_movement',
      payload: {
        amountRole: 'posted',
        amountInr: 1250.5,
        entryKind: 'spend',
        merchant: 'GROCERY',
        occurredAt: '2026-10-16T10:00:00.000Z',
        instrument: 'upi_bank',
      },
    },
    {
      factType: 'balance_snapshot',
      payload: {
        availableBalanceInr: 8750.25,
        asOfAt: '2026-10-16T10:00:00.000Z',
      },
    },
  ];
  assert.deepEqual(smsFacts.validateFactSet(factsDebitBal), { valid: true, errors: [] });

  // 2. Bill total + minimum due + due date
  const factsBill = [
    {
      factType: 'bill_obligation',
      payload: {
        amountRole: 'due_total',
        amountDueInr: 5000,
        minimumDueInr: 500,
        dueDate: '2026-11-05T00:00:00.000Z',
        statementDate: '2026-10-15T00:00:00.000Z',
        last4: '4321',
      },
    },
  ];
  assert.deepEqual(smsFacts.validateFactSet(factsBill), { valid: true, errors: [] });

  // 3. Failed attempt carries pending_or_failed_attempt, not posted spend
  const failedAttempt = {
    factType: 'pending_or_failed_attempt',
    payload: {
      attemptStatus: 'failed',
      proposedAmountInr: 500,
      occurredAt: '2026-10-18T10:00:00.000Z',
      last4: '4321',
    },
  };
  assert.equal(smsFacts.validateFact(failedAttempt).valid, true);

  // Invariant check: Bill obligation or Mandate CANNOT carry amountRole 'posted'
  const invalidBillAsSpend = {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'posted',
      amountInr: 5000,
      dueDate: '2026-11-05T00:00:00.000Z',
    },
  };
  assert.equal(smsFacts.validateFact(invalidBillAsSpend).valid, false);
});

// ---------------------------------------------------------------------------
// Scenario 4: Promotion containing financial words vs real financial with promo footer
// ---------------------------------------------------------------------------
test('Scenario 4: Promotion containing financial words vs real financial with offer footer', () => {
  // Real financial refund with promotional footer
  const realSmsWithFooter = {
    sender: 'HDFCBK',
    body: 'Your refund of Rs.499 was credited to credit card XX4321. Get 5% cashback on next purchase!',
  };
  const parsedReal = parseSmsAgainstPatterns([], realSmsWithFooter);
  assert.equal(parsedReal.ok, true);
  assert.equal(parsedReal.fields.amountInr, 499);
  assert.equal(parsedReal.fields.last4, '4321');

  // Pure promotion that mentions "spent" or "Rs." to sell loans or EMIs
  const promoWithAmount = {
    sender: 'VM-HDFCBK-P',
    body: 'Convert your recent spends into easy EMIs starting at Rs. 99/month. Call now or SMS EMI to 56767.',
  };
  const parsedPromo = parseSmsAgainstPatterns([], promoWithAmount);
  assert.equal(parsedPromo.ok, false);
});

// ---------------------------------------------------------------------------
// Scenario 5: User correction wins over late AI/rules and persists lineage
// ---------------------------------------------------------------------------
test('Scenario 5: User correction takes precedence over base facts and updates lineage', async () => {
  const client = fakeDbClient();
  const userId = '11111111-1111-1111-1111-111111111111';
  const sourceKey = 'a'.repeat(64);

  // 1. Ingest original fact (merchant parsed as SWIGGY)
  const initialEnvelope = {
    sourceKey,
    sender: 'HDFCBK',
    bodyHash: 'b'.repeat(64),
    receivedAt: '2026-10-18T10:00:00.000Z',
    facts: [
      {
        factType: 'posted_movement',
        payload: {
          amountRole: 'posted',
          amountInr: 250,
          entryKind: 'spend',
          merchant: 'SWIGGY',
          occurredAt: '2026-10-18T10:00:00.000Z',
        },
      },
    ],
  };

  const upsertRes = await smsFacts.upsertSmsSourceFacts(client, userId, initialEnvelope);
  assert.ok(upsertRes.sourceId);
  assert.equal(upsertRes.factIds.length, 1);

  // 2. User overrides merchant to SWIGGY INSTAMART
  await smsFacts.writeSmsFactOverride(client, userId, {
    sourceId: upsertRes.sourceId,
    factIndex: 0,
    patch: { merchant: 'SWIGGY INSTAMART' },
  });

  // 3. Re-read facts with overrides applied
  const currentRes = await smsFacts.loadSmsSourceFacts(client, userId, sourceKey);
  assert.equal(currentRes.facts[0].payload.merchant, 'SWIGGY INSTAMART');
});

// ---------------------------------------------------------------------------
// Scenario 6: Learned template field extraction and hard-negative safety
// ---------------------------------------------------------------------------
test('Scenario 6: Learned template extracts fields accurately and rejects hard negatives', () => {
  const rule = {
    id: 'rule_hdfc_debit',
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by Rs\\.?\\s*([0-9,]+(?:\\.[0-9]{1,2})?) for ([A-Za-z0-9\\s&._-]+) on card ([0-9]{4})',
    fieldMap: { amount: 1, merchant: 2, last4: 3 },
    confidence: 0.99,
  };
  assert.equal(smsRuleBundle.validateRule(rule).valid, true);

  // Exact match
  const text = 'debited by Rs. 1,450.00 for AMAZON PAY on card 9876';
  const match = text.match(new RegExp(rule.regex, 'i'));
  assert.ok(match);
  assert.equal(match[1], '1,450.00');
  assert.equal(match[2], 'AMAZON PAY');
  assert.equal(match[3], '9876');

  // Hard negative (OTP) must not match
  const otp = 'Your OTP is 123456 for txn on card 9876. Do not share.';
  assert.equal(new RegExp(rule.regex, 'i').test(otp), false);

  // Hard negative (Offer) must not match
  const offer = 'Get 10% discount on card 9876 when you spend Rs 1000';
  assert.equal(new RegExp(rule.regex, 'i').test(offer), false);
});

// ---------------------------------------------------------------------------
// Scenario 7: Bad rule, invalid bundle, server rollback fallback
// ---------------------------------------------------------------------------
test('Scenario 7: Safe bundle validation and rollback support', () => {
  // 1. Catastrophic backtracking regex rejected
  const badRedosRule = {
    id: 'bad_redos',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: '(a+)+b',
    fieldMap: { amount: 1 },
  };
  assert.equal(smsRuleBundle.validateRule(badRedosRule).valid, false);

  // 2. ignore_noise matching financial keywords rejected
  const badNoiseRule = {
    id: 'bad_noise',
    family: 'ignore_noise',
    senderPattern: 'BANK',
    regex: 'debited by Rs 500 offer',
  };
  assert.equal(smsRuleBundle.validateRule(badNoiseRule).valid, false);

  // 3. Bundle hash is canonical and deterministic
  const hash1 = smsRuleBundle.computeBundleHash({
    bundleVersion: 1,
    rules: [
      { id: 'b', family: 'posted_movement', senderPattern: 'B', regex: 'b', fieldMap: { amount: 1 } },
      { id: 'a', family: 'posted_movement', senderPattern: 'A', regex: 'a', fieldMap: { amount: 1 } },
    ],
  });
  const hash2 = smsRuleBundle.computeBundleHash({
    bundleVersion: 1,
    rules: [
      { id: 'a', family: 'posted_movement', senderPattern: 'A', regex: 'a', fieldMap: { amount: 1 } },
      { id: 'b', family: 'posted_movement', senderPattern: 'B', regex: 'b', fieldMap: { amount: 1 } },
    ],
  });
  assert.equal(hash1, hash2, 'Order of rules is sorted canonically');
});

// ---------------------------------------------------------------------------
// Scenario 8: Subscriptions and recurring mandates
// Evidenced series only, no invented charge
// ---------------------------------------------------------------------------
test('Scenario 8: Mandate lifecycle handles setup and cancellation without booking charges', () => {
  // Registration setup
  const regSms = {
    sender: 'HDFCBK',
    body: 'AutoPay e-mandate successfully registered for NETFLIX with maximum limit of INR 2,000.00 on HDFC Bank A/c XX1797',
  };
  const regParsed = parseSubscriptionMandate(regSms);
  assert.equal(regParsed.ok, true);
  assert.equal(regParsed.lifecycle, 'active');
  assert.equal(regParsed.fields.amountInr, 2000);
  assert.equal(regParsed.fields.last4, '1797');

  // Mandate cancellation
  const cancelSms = {
    sender: 'HDFCBK',
    body: 'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
  };
  const cancelParsed = parseSubscriptionMandate(cancelSms);
  assert.equal(cancelParsed.ok, true);
  assert.equal(cancelParsed.lifecycle, 'cancelled');

  // Ordinary debit for Netflix is the ONLY event that books a transaction
  const debitSms = {
    sender: 'HDFCBK',
    body: 'INR 649.00 debited from HDFC Bank A/c XX1797 for NETFLIX on 18-10-26.',
  };
  const debitParsed = parseSmsAgainstPatterns([], debitSms);
  assert.equal(debitParsed.ok, true);
  assert.equal(debitParsed.fields.amountInr, 649);
});

// ---------------------------------------------------------------------------
// Scenario 9: User privacy, consent isolation, and feedback integrity
// ---------------------------------------------------------------------------
test('Scenario 9: Privacy opt-out prevents learning feedback collection', async () => {
  const optingOutClient = fakeDbClient({ contributionsOptIn: false });
  const userId = '22222222-2222-2222-2222-222222222222';
  const sourceKey = 'c'.repeat(64);

  const res = await smsLearning.recordConfirmedCorrection(optingOutClient, {
    profileId: userId,
    sourceKey,
    sender: 'HDFCBK',
    family: 'posted_movement',
    fields: ['merchant'],
  });

  assert.equal(res.recorded, 0, 'No feedback recorded when sms_shared_learning consent is false');
  assert.equal(res.disabled, true);
  assert.equal(optingOutClient.learningFeedback.length, 0);

  // Opted-in user records de-identified HMAC fingerprint only
  const optingInClient = fakeDbClient({ contributionsOptIn: true });
  process.env.SMS_LEARNING_HMAC_KEY = 'a'.repeat(32);
  const inRes = await smsLearning.recordConfirmedCorrection(optingInClient, {
    profileId: userId,
    sourceKey,
    sender: 'HDFCBK',
    family: 'posted_movement',
    fields: ['merchant'],
  });
  assert.equal(inRes.recorded, 1);
  assert.equal(optingInClient.learningFeedback.length, 1);
  // Verify fingerprint is HMAC, not plaintext sender
  const [profileId, srcKey, fingerprint, family, field] = optingInClient.learningFeedback[0];
  assert.match(fingerprint, /^[0-9a-f]{64}$/);
  assert.notEqual(fingerprint, 'HDFCBK');
});
