const test = require('node:test');
const assert = require('node:assert/strict');
const {
  evaluateCandidate,
  evaluateHoldout,
  splitHoldoutDataset,
  evaluateCanaryMetrics,
  parseAmountToPaise,
  computeWilsonScoreUpperBound,
  computeLaplaceErrorBound,
  STANDARD_HARD_NEGATIVES,
  ACTION_THRESHOLDS,
  senderMatches,
} = require('../src/sms_evaluator');

test('sms_evaluator: parseAmountToPaise parses various currency formats', () => {
  assert.equal(parseAmountToPaise('1,500.50'), 150050);
  assert.equal(parseAmountToPaise('250'), 25000);
  assert.equal(parseAmountToPaise('99.99'), 9999);
  assert.equal(parseAmountToPaise('0.50'), 50);
  assert.equal(parseAmountToPaise('10,00,000'), 100000000);
  assert.equal(parseAmountToPaise(''), null);
  assert.equal(parseAmountToPaise(null), null);
});

test('sms_evaluator: computeWilsonScoreUpperBound and computeLaplaceErrorBound bounds calculations', () => {
  const wilson0 = computeWilsonScoreUpperBound(0, 10);
  assert.ok(wilson0 < 0.35 && wilson0 > 0.25);

  const wilsonAll = computeWilsonScoreUpperBound(10, 10);
  assert.equal(wilsonAll, 1.0);

  const laplace0 = computeLaplaceErrorBound(0, 10);
  assert.equal(laplace0, Number((1 / 12).toFixed(4)));

  const laplaceAll = computeLaplaceErrorBound(10, 10);
  assert.equal(laplaceAll, Number((11 / 12).toFixed(4)));
});

test('sms_evaluator: passes valid positive examples with exact paise extraction', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?)) on card ([0-9]{4})',
    fieldMap: { amount: 1, last4: 2 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'debited by Rs. 500.00 on card 1234',
        extracted_fields: { amountPaise: 50000, last4: '1234' },
      },
      {
        sample_body: 'debited by INR 1,250 on card 9876',
        extracted_fields: { amountPaise: 125000, last4: '9876' },
      },
      {
        sample_body: 'debited by ₹75.50 on card 4321',
        extracted_fields: { amountPaise: 7550, last4: '4321' },
      },
    ],
    negatives: [],
  };

  const result = evaluateCandidate(candidate, dataset, { includeStandardNegatives: true });
  assert.equal(result.pass, true);
  assert.equal(result.positiveCount, 3);
  assert.equal(result.negativeCollisions, 0);
  assert.equal(result.failureReason, null);
  assert.ok(result.errorBound >= 0 && result.errorBound <= 1.0);
});

test('sms_evaluator: fails when amount extraction does not match expected paise', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
    fieldMap: { amount: 1 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'debited by Rs. 500',
        extracted_fields: { amountPaise: 99999 }, // Expected 99999 paise != 50000 paise
      },
    ],
    negatives: [],
  };

  const result = evaluateCandidate(candidate, dataset, { includeStandardNegatives: false });
  assert.equal(result.pass, false);
  assert.equal(result.failureReason, 'extraction_mismatch');
});

test('sms_evaluator: zero tolerance on hard negative collisions (OTP / promotional / non-financial)', () => {
  const leakyCandidate = {
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: '.*([0-9]{6}).*',
    fieldMap: { reference: 1 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'Transaction reference 123456 completed',
        extracted_fields: {},
      },
    ],
    negatives: [
      {
        sample_body: 'Your OTP is 482910 for login to PandaPay. Do not share.',
        is_negative: true,
        negative_reason: 'otp_security',
      },
    ],
  };

  const result = evaluateCandidate(leakyCandidate, dataset);
  assert.equal(result.pass, false);
  assert.ok(result.negativeCollisions >= 1);
  assert.equal(result.failureReason, 'regression_on_hard_negative');
});

test('sms_evaluator: standard hard negatives prevent cross-family collisions', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'AutoPay mandate registered for Rs\\.?\\s*([0-9.]+)',
    fieldMap: { amount: 1 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'AutoPay mandate registered for Rs. 1500 monthly towards Netflix.',
      },
    ],
    negatives: [],
  };

  const result = evaluateCandidate(candidate, dataset, { includeStandardNegatives: true });
  assert.equal(result.pass, false);
  assert.ok(result.negativeCollisions >= 1);
  assert.equal(result.failureReason, 'regression_on_hard_negative');
});

test('sms_evaluator: standard hard negatives prevent EMI offer and refund/reversal regressions', () => {
  // Regex that matches generic Rs. amount without checking movement direction
  const looseCandidate = {
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'Rs\\.?\\s*([0-9,]+(?:\\.[0-9]{2})?)',
    fieldMap: { amount: 1 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'debited by Rs. 1,000.00',
        extracted_fields: { amountPaise: 100000 },
      },
    ],
    negatives: [],
  };

  // Standard hard negatives include EMI offers and refund/reversals
  const result = evaluateCandidate(looseCandidate, dataset, { includeStandardNegatives: true });
  assert.equal(result.pass, false);
  assert.ok(result.negativeCollisions >= 1);
  assert.equal(result.failureReason, 'regression_on_hard_negative');
});

test('sms_evaluator: fails when no positive examples match', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'spent Rs\\.?\\s*([0-9.]+) at Store',
    fieldMap: { amount: 1 },
  };

  const dataset = {
    positives: [
      {
        sample_body: 'Completely different SMS without spent keyword',
      },
    ],
    negatives: [],
  };

  const result = evaluateCandidate(candidate, dataset, { includeStandardNegatives: false });
  assert.equal(result.pass, false);
  assert.equal(result.failureReason, 'no_positive_matches');
});

// --- Exact field extraction tests ---

test('sms_evaluator: exact field checks for last4, merchant, reference, and dueDate', () => {
  const candidate = {
    family: 'bill_obligation',
    senderPattern: 'HDFCBK',
    regex: 'Bill of (?:Rs\\.?|INR)\\s*([0-9]+) on card ([0-9]{4}) for ([A-Za-z]+) ref ([A-Za-z0-9]+) due on (\\d{2}-\\d{2}-\\d{4})',
    fieldMap: {
      amountDue: 1,
      last4: 2,
      merchant: 3,
      reference: 4,
      dueDate: 5,
    },
  };

  const sampleBody = 'Bill of Rs. 1500 on card 4321 for Airtel ref TXN9988 due on 28-10-2026';

  // 1. All matching fields pass
  const validDataset = {
    positives: [
      {
        sample_body: sampleBody,
        extracted_fields: {
          amountPaise: 150000,
          last4: '4321',
          merchant: 'Airtel',
          reference: 'TXN9988',
          dueDate: '28-10-2026',
        },
      },
    ],
    negatives: [],
  };
  const validRes = evaluateCandidate(candidate, validDataset, { includeStandardNegatives: false });
  assert.equal(validRes.pass, true);

  // 2. last4 mismatch fails
  const badLast4Dataset = {
    positives: [{ sample_body: sampleBody, extracted_fields: { last4: '9999' } }],
  };
  assert.equal(evaluateCandidate(candidate, badLast4Dataset, { includeStandardNegatives: false }).failureReason, 'extraction_mismatch');

  // 3. merchant mismatch fails
  const badMerchantDataset = {
    positives: [{ sample_body: sampleBody, extracted_fields: { merchant: 'Vodafone' } }],
  };
  assert.equal(evaluateCandidate(candidate, badMerchantDataset, { includeStandardNegatives: false }).failureReason, 'extraction_mismatch');

  // 4. reference mismatch fails
  const badRefDataset = {
    positives: [{ sample_body: sampleBody, extracted_fields: { reference: 'WRONGREF' } }],
  };
  assert.equal(evaluateCandidate(candidate, badRefDataset, { includeStandardNegatives: false }).failureReason, 'extraction_mismatch');

  // 5. dueDate mismatch fails
  const badDueDateDataset = {
    positives: [{ sample_body: sampleBody, extracted_fields: { dueDate: '01-01-2027' } }],
  };
  assert.equal(evaluateCandidate(candidate, badDueDateDataset, { includeStandardNegatives: false }).failureReason, 'extraction_mismatch');
});

// --- Canary Metrics Evaluation tests ---

test('sms_evaluator: evaluateCanaryMetrics - insufficient observation time stays in current stage without advancing', () => {
  const candidate = { state: 'shadow', stage_metrics: {} };
  const now = Date.now();
  // Only 12 hours elapsed (default requirement is 24 hours)
  const windowStart = new Date(now - 12 * 60 * 60 * 1000).toISOString();
  const metrics = {
    exposures: 20,
    corrections: 0,
    false_discards: 0,
    window_start: windowStart,
  };

  const result = evaluateCanaryMetrics(candidate, metrics, { now });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, false);
  assert.equal(result.reason, 'insufficient_observation');
});

test('sms_evaluator: evaluateCanaryMetrics - insufficient sample exposures stays in current stage', () => {
  const candidate = { state: 'shadow', stage_metrics: {} };
  const now = Date.now();
  // 30 hours elapsed (sufficient time > 24 hours), but exposures = 5 (shadow requires min 10)
  const windowStart = new Date(now - 30 * 60 * 60 * 1000).toISOString();
  const metrics = {
    exposures: 5,
    corrections: 0,
    false_discards: 0,
    window_start: windowStart,
  };

  const result = evaluateCanaryMetrics(candidate, metrics, { now });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, false);
  assert.equal(result.reason, 'insufficient_observation');
});

test('sms_evaluator: evaluateCanaryMetrics - high correction rate triggers rollback', () => {
  const candidate = { state: 'shadow', stage_metrics: {} };
  const now = Date.now();
  const windowStart = new Date(now - 30 * 60 * 60 * 1000).toISOString();
  // 100 exposures, 3 corrections -> correctionRate 0.03 > maxCorrectionRate 0.01
  const metrics = {
    exposures: 100,
    corrections: 3,
    false_discards: 0,
    window_start: windowStart,
  };

  const result = evaluateCanaryMetrics(candidate, metrics, { now });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, true);
  assert.equal(result.reason, 'high_error_rate');
  assert.equal(result.correctionRate, 0.03);
});

test('sms_evaluator: evaluateCanaryMetrics - high false discard rate triggers rollback', () => {
  const candidate = { state: 'limited', stage_metrics: {} };
  const now = Date.now();
  const windowStart = new Date(now - 30 * 60 * 60 * 1000).toISOString();
  // 200 exposures, 2 false discards -> falseDiscardRate 0.01 > maxFalseDiscardRate 0.005
  const metrics = {
    exposures: 200,
    corrections: 0,
    false_discards: 2,
    window_start: windowStart,
  };

  const result = evaluateCanaryMetrics(candidate, metrics, { now });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, true);
  assert.equal(result.reason, 'high_error_rate');
  assert.equal(result.falseDiscardRate, 0.01);
});

test('sms_evaluator: evaluateCanaryMetrics - passing canary metrics allows progression', () => {
  const candidate = { state: 'shadow', stage_metrics: {} };
  const now = Date.now();
  const windowStart = new Date(now - 25 * 60 * 60 * 1000).toISOString();
  // 50 exposures, 0 corrections, 0 false discards, elapsed > 24 hours
  const metrics = {
    exposures: 50,
    corrections: 0,
    false_discards: 0,
    window_start: windowStart,
  };

  const result = evaluateCanaryMetrics(candidate, metrics, { now });
  assert.equal(result.passed, true);
  assert.equal(result.shouldRollback, false);
  assert.equal(result.reason, null);
  assert.equal(result.exposures, 50);
});

test('sms_evaluator: evaluateCanaryMetrics - respects custom options overrides', () => {
  const candidate = { state: 'expanded' };
  const now = Date.now();
  // 1 hour elapsed, custom minObservationMs of 30 minutes
  const windowStart = new Date(now - 60 * 60 * 1000).toISOString();
  const metrics = {
    exposures: 15,
    corrections: 0,
    false_discards: 0,
    window_start: windowStart,
  };

  // Custom minExposures = 10, minObservationMs = 30m
  const result = evaluateCanaryMetrics(candidate, metrics, {
    now,
    minExposures: 10,
    minObservationMs: 30 * 60 * 1000,
  });
  assert.equal(result.passed, true);
  assert.equal(result.shouldRollback, false);
});

test('sms_evaluator: production promotion waits for candidate versus baseline comparisons', () => {
  const candidate = { state: 'shadow' };
  const now = Date.now();
  const windowStart = new Date(now - 30 * 60 * 60 * 1000).toISOString();
  const result = evaluateCanaryMetrics(candidate, {
    exposures: 20,
    comparisons: 2,
    comparison_errors: 0,
    window_start: windowStart,
  }, {
    now,
    minExposures: 10,
    minObservationMs: 0,
    requireComparableEvidence: true,
  });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, false);
  assert.equal(result.reason, 'insufficient_comparison_evidence');
});

test('sms_evaluator: production promotion rolls back on baseline regression comparisons', () => {
  const candidate = { state: 'limited' };
  const now = Date.now();
  const result = evaluateCanaryMetrics(candidate, {
    exposures: 20,
    comparisons: 20,
    comparison_errors: 1,
    window_start: new Date(now - 30 * 60 * 60 * 1000).toISOString(),
  }, {
    now,
    minExposures: 10,
    minObservationMs: 0,
    requireComparableEvidence: true,
  });
  assert.equal(result.passed, false);
  assert.equal(result.shouldRollback, true);
  assert.equal(result.reason, 'high_error_rate');
  assert.equal(result.comparisonErrorRate, 0.05);
});

// --- Holdout dataset splitting & holdout evaluation tests ---

test('sms_evaluator: splitHoldoutDataset partitions examples by distinct user_hash', () => {
  const examples = [
    { sample_body: 'debited by Rs. 100 on card 1111', user_hash: 'u1' },
    { sample_body: 'debited by Rs. 200 on card 1111', user_hash: 'u1' },
    { sample_body: 'debited by Rs. 300 on card 2222', user_hash: 'u2' },
    { sample_body: 'debited by Rs. 400 on card 3333', user_hash: 'u3' },
  ];

  const split = splitHoldoutDataset(examples, { holdoutRatio: 0.3 });
  assert.ok(split.generationSet.length >= 1);
  assert.ok(split.holdoutSet.length >= 1);
  assert.equal(split.generationSet.length + split.holdoutSet.length, 4);

  // Users in holdout must not overlap with users in generation
  const genUsers = new Set(split.generationSet.map((e) => e.user_hash));
  const holdoutUsers = new Set(split.holdoutSet.map((e) => e.user_hash));
  for (const u of holdoutUsers) {
    assert.equal(genUsers.has(u), false);
  }
});

test('sms_evaluator: splitHoldoutDataset partitions examples by timestamp', () => {
  const examples = [
    { sample_body: 'debited 1', created_at: '2026-10-01T10:00:00Z' },
    { sample_body: 'debited 2', created_at: '2026-10-02T10:00:00Z' },
    { sample_body: 'debited 3', created_at: '2026-10-03T10:00:00Z' },
    { sample_body: 'debited 4', created_at: '2026-10-04T10:00:00Z' },
  ];

  const split = splitHoldoutDataset(examples, { holdoutRatio: 0.25 });
  assert.equal(split.generationSet.length, 3);
  assert.equal(split.holdoutSet.length, 1);
  assert.equal(split.holdoutSet[0].sample_body, 'debited 4');
});

test('sms_evaluator: splitHoldoutDataset partitions examples by distinct message wording', () => {
  const examples = [
    { sample_body: 'debited by Rs. 100 on card 1111' },
    { sample_body: 'debited by Rs. 100 on card 1111' },
    { sample_body: 'spent INR 500 at Store' },
  ];

  const split = splitHoldoutDataset(examples);
  assert.ok(split.generationSet.length >= 1);
  assert.ok(split.holdoutSet.length >= 1);
  assert.equal(split.generationSet.length + split.holdoutSet.length, 3);
});

test('sms_evaluator: evaluateHoldout evaluates candidate against frozen holdout set', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?)) on card ([0-9]{4})',
    fieldMap: { amount: 1, last4: 2 },
  };

  // Generate 25 frozen holdout positive examples
  const holdoutSet = [];
  for (let i = 1; i <= 25; i++) {
    const last4 = String(1000 + i);
    const amountInr = 100 * i;
    holdoutSet.push({
      sample_body: `debited by Rs. ${amountInr}.00 on card ${last4}`,
      sender: 'AD-HDFCBK',
      extracted_fields: { amountPaise: amountInr * 100, last4 },
    });
  }

  // With 25 samples and useLaplace, Laplace upper bound is 1/27 = 0.0370 <= 0.05
  const result = evaluateHoldout(candidate, { positives: holdoutSet, negatives: [] }, { useLaplace: true });
  assert.equal(result.pass, true);
  assert.equal(result.isHoldout, true);
  assert.equal(result.positiveCount, 25);
  assert.equal(result.negativeCollisions, 0);
  assert.ok(result.errorBound <= ACTION_THRESHOLDS.posted_movement.maxErrorBound);
});

test('sms_evaluator: evaluateHoldout rejects wildcard sender pattern .* or *', () => {
  const wildcardCandidate = {
    family: 'posted_movement',
    senderPattern: '.*',
    regex: 'debited by Rs\\.?\\s*([0-9]+)',
    fieldMap: { amount: 1 },
  };

  const holdoutSet = [
    {
      sample_body: 'debited by Rs. 100',
      extracted_fields: { amountPaise: 10000 },
    },
  ];

  const result = evaluateHoldout(wildcardCandidate, { positives: holdoutSet });
  assert.equal(result.pass, false);
  assert.equal(result.failureReason, 'wildcard_sender_forbidden');
});

test('sms_evaluator: mandatory family-specific evidence gates in production', () => {
  const candidate = {
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?)) on card ([0-9]{4})',
    fieldMap: { amount: 1, last4: 2 },
  };

  // Only 2 positives (posted_movement requires min 5 positives in production)
  const smallDataset = {
    positives: [
      {
        sample_body: 'debited by Rs. 500 on card 1234',
        extracted_fields: { amountPaise: 50000, last4: '1234' },
      },
      {
        sample_body: 'debited by Rs. 600 on card 5678',
        extracted_fields: { amountPaise: 60000, last4: '5678' },
      },
    ],
    negatives: [],
  };

  // 1. Outside production without explicit gate enforcement, 2 positives can pass
  const devResult = evaluateCandidate(candidate, smallDataset, { isProduction: false });
  assert.equal(devResult.pass, true);

  // 2. In production, mandatory gates require min 5 positives and bounded error rate
  const prodResult = evaluateCandidate(candidate, smallDataset, { isProduction: true });
  assert.equal(prodResult.pass, false);
  assert.equal(prodResult.failureReason, 'insufficient_positive_samples');

  // 3. In production, 5 matching positives pass
  const fullDataset = {
    positives: [
      { sample_body: 'debited by Rs. 100 on card 1111', extracted_fields: { amountPaise: 10000, last4: '1111' } },
      { sample_body: 'debited by Rs. 200 on card 2222', extracted_fields: { amountPaise: 20000, last4: '2222' } },
      { sample_body: 'debited by Rs. 300 on card 3333', extracted_fields: { amountPaise: 30000, last4: '3333' } },
      { sample_body: 'debited by Rs. 400 on card 4444', extracted_fields: { amountPaise: 40000, last4: '4444' } },
      { sample_body: 'debited by Rs. 500 on card 5555', extracted_fields: { amountPaise: 50000, last4: '5555' } },
    ],
    negatives: [],
  };
  const prodFullResult = evaluateCandidate(candidate, fullDataset, { isProduction: true, maxErrorBound: 0.5 });
  assert.equal(prodFullResult.pass, true);
  assert.equal(prodFullResult.positiveCount, 5);
});
