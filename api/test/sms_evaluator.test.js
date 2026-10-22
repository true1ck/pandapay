const test = require('node:test');
const assert = require('node:assert/strict');
const {
  evaluateCandidate,
  parseAmountToPaise,
  computeWilsonScoreUpperBound,
  computeLaplaceErrorBound,
  STANDARD_HARD_NEGATIVES,
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
  // An overly loose regex that accidentally matches OTP messages
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
  // Candidate that matches mandate notifications instead of movement
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

  // Standard hard negatives include 'AutoPay mandate registered...' as a cross-family negative for posted_movement
  const result = evaluateCandidate(candidate, dataset, { includeStandardNegatives: true });
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
