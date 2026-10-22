/**
 * Independent evaluator for SMS candidate rules against positive & hard-negative examples.
 *
 * Enforces zero-tolerance regression checks against hard negatives (OTPs, promotional spam,
 * non-financial alerts, cross-family collisions) and verifies exact paise amount extraction.
 */

const STANDARD_HARD_NEGATIVES = [
  // OTP / security messages
  { text: 'Your OTP is 482910 for login to PandaPay. Do not share this with anyone.', category: 'otp_security' },
  { text: '492811 is your secret OTP for transaction at Merchant. Never share OTP with bank staff.', category: 'otp_security' },
  { text: 'Do not share your OTP with anyone. Your one-time password is 882190.', category: 'otp_security' },
  // Pure promotional offers
  { text: 'Get 50% discount up to Rs. 200 on your next order at Swiggy using code FEAST!', category: 'promotional' },
  { text: 'Exclusive offer! Pre-approved personal loan of Rs. 5,00,000 available at 10.5% interest. Apply now!', category: 'promotional' },
  { text: 'Flat Rs. 100 cashback on recharge above Rs. 199. Tap here to claim.', category: 'promotional' },
  // Non-financial alerts
  { text: 'Alert: SIM swap request received for your mobile number. If not requested, call care immediately.', category: 'non_financial_alert' },
  { text: 'Dear customer, your periodic KYC is due. Please visit nearest branch with original documents.', category: 'non_financial_alert' },
  { text: 'Courier out for delivery: Your package from Amazon will arrive today between 2 PM and 6 PM.', category: 'non_financial_alert' },
  // Cross-family messages
  { text: 'AutoPay mandate registered for Rs. 1500 monthly towards Netflix.', family: 'mandate_lifecycle', category: 'cross_family' },
  { text: 'Your electricity bill of Rs. 1250 is due on 25-10-2026. Pay now to avoid late fee.', family: 'bill_obligation', category: 'cross_family' },
  { text: 'Available balance in A/c 1234 is Rs. 45000 as of 22-10-2026.', family: 'balance_snapshot', category: 'cross_family' },
  { text: 'debited by Rs. 500 on card 1234 at Amazon', family: 'posted_movement', category: 'cross_family' },
];

const AMOUNT_FIELDS = new Set([
  'amount', 'amountDue', 'availableBalance', 'currentBalance', 'minimumDue',
]);

/**
 * Parses raw currency string (e.g. "1,500.50", "Rs. 250") into integer paise.
 *
 * @param {string|number} rawAmount
 * @returns {number|null}
 */
function parseAmountToPaise(rawAmount) {
  if (rawAmount === undefined || rawAmount === null || rawAmount === '') return null;
  const cleaned = String(rawAmount).replace(/,/g, '').trim();
  const num = parseFloat(cleaned);
  return Number.isFinite(num) ? Math.round(num * 100) : null;
}

/**
 * Calculates Wilson score interval upper bound for error rate.
 *
 * @param {number} k - number of errors / failures
 * @param {number} n - total sample size
 * @param {number} [z=1.96] - normal quantile (1.96 for 95% confidence)
 * @returns {number}
 */
function computeWilsonScoreUpperBound(k, n, z = 1.96) {
  if (!n || n <= 0) return 1.0;
  const p = Math.max(0, Math.min(1, k / n));
  const z2 = z * z;
  const den = 1 + z2 / n;
  const center = p + z2 / (2 * n);
  const spread = z * Math.sqrt((p * (1 - p) / n) + (z2 / (4 * n * n)));
  return Math.min(1.0, Math.max(0, Number(((center + spread) / den).toFixed(4))));
}

/**
 * Calculates Laplace error bound ((errors + 1) / (total + 2)).
 *
 * @param {number} k - errors
 * @param {number} n - total
 * @returns {number}
 */
function computeLaplaceErrorBound(k, n) {
  if (!n || n < 0) return 1.0;
  return Number(((k + 1) / (n + 2)).toFixed(4));
}

/**
 * Evaluates candidate rule against positive examples and hard-negative examples.
 *
 * @param {object} candidate - { family, senderPattern, regex, fieldMap, defaultFields }
 * @param {object|Array} dataset - Array of examples or { positives: [], negatives: [] }
 * @param {object} [options] - Configuration options
 * @returns {{ pass: boolean, positiveCount: number, negativeCollisions: number, errorBound: number, failureReason: string|null }}
 */
function evaluateCandidate(candidate, dataset, options = {}) {
  if (!candidate || typeof candidate !== 'object') {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'invalid_candidate_object',
    };
  }

  const regexStr = candidate.regex || candidate.compiled_regex || candidate.compiledRegex;
  if (typeof regexStr !== 'string' || regexStr.trim().length === 0) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'missing_or_empty_regex',
    };
  }

  let re;
  try {
    re = new RegExp(regexStr, 'i');
  } catch (err) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: `invalid_regex: ${err.message}`,
    };
  }

  const fieldMap = candidate.fieldMap || candidate.field_map || {};
  const family = candidate.family || 'posted_movement';

  // Normalize dataset into positives and negatives
  let rawPositives = [];
  let rawNegatives = [];

  if (Array.isArray(dataset)) {
    for (const item of dataset) {
      if (item.is_negative === true || item.isNegative === true || item.expectedMatch === false) {
        rawNegatives.push(item);
      } else {
        rawPositives.push(item);
      }
    }
  } else if (dataset && typeof dataset === 'object') {
    rawPositives = Array.isArray(dataset.positives) ? dataset.positives : [];
    rawNegatives = Array.isArray(dataset.negatives)
      ? dataset.negatives
      : (Array.isArray(dataset.hardNegatives) ? dataset.hardNegatives : []);
  }

  // Merge built-in standard hard negatives unless explicitly disabled
  const negatives = [...rawNegatives];
  if (options.includeStandardNegatives !== false) {
    for (const sn of STANDARD_HARD_NEGATIVES) {
      // Include non-financial/OTP/promo, and only cross-family if candidate family differs
      if (!sn.family || sn.family !== family) {
        negatives.push(sn);
      }
    }
  }

  // 1. Hard negative collision check (zero tolerance)
  let negativeCollisions = 0;
  for (const neg of negatives) {
    const text = neg.sample_body || neg.sampleBody || neg.text || neg.body || '';
    if (re.test(text)) {
      negativeCollisions += 1;
    }
  }

  if (negativeCollisions > 0) {
    const totalSamples = rawPositives.length + negatives.length;
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions,
      errorBound: options.useLaplace
        ? computeLaplaceErrorBound(negativeCollisions, totalSamples)
        : computeWilsonScoreUpperBound(negativeCollisions, Math.max(totalSamples, 1)),
      failureReason: 'regression_on_hard_negative',
    };
  }

  // 2. Positive examples evaluation
  if (rawPositives.length === 0) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'no_positive_examples',
    };
  }

  let matchedPositives = 0;
  let errors = 0;
  let extractionMismatchCount = 0;

  for (const pos of rawPositives) {
    const text = pos.sample_body || pos.sampleBody || pos.text || pos.body || '';
    const match = text.match(re);
    if (!match) {
      errors += 1;
      continue;
    }

    // Extraction test: check amount extraction against expected amounts in paise
    const expected = pos.extracted_fields || pos.extractedFields || pos.expectedFields || pos.expected || {};
    let exampleExtractionPassed = true;

    for (const [fieldName, groupIdx] of Object.entries(fieldMap)) {
      if (AMOUNT_FIELDS.has(fieldName)) {
        const extractedRaw = match[groupIdx];
        const extractedPaise = parseAmountToPaise(extractedRaw);

        // Determine expected paise if provided
        let expectedPaise = null;
        if (expected[fieldName + 'Paise'] !== undefined) {
          expectedPaise = Number(expected[fieldName + 'Paise']);
        } else if (expected[fieldName + 'Inr'] !== undefined) {
          expectedPaise = Math.round(Number(expected[fieldName + 'Inr']) * 100);
        } else if (expected[fieldName] !== undefined) {
          expectedPaise = parseAmountToPaise(expected[fieldName]);
        }

        if (expectedPaise !== null && extractedPaise !== expectedPaise) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      }
    }

    if (exampleExtractionPassed) {
      matchedPositives += 1;
    } else {
      errors += 1;
    }
  }

  const totalPositives = rawPositives.length;
  const errorBound = options.useLaplace
    ? computeLaplaceErrorBound(errors, totalPositives)
    : computeWilsonScoreUpperBound(errors, totalPositives);

  if (matchedPositives === 0) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound,
      failureReason: extractionMismatchCount > 0 ? 'extraction_mismatch' : 'no_positive_matches',
    };
  }

  if (extractionMismatchCount > 0) {
    return {
      pass: false,
      positiveCount: matchedPositives,
      negativeCollisions: 0,
      errorBound,
      failureReason: 'extraction_mismatch',
    };
  }

  if (options.maxErrorBound !== undefined && errorBound > options.maxErrorBound) {
    return {
      pass: false,
      positiveCount: matchedPositives,
      negativeCollisions: 0,
      errorBound,
      failureReason: 'error_bound_exceeded',
    };
  }

  return {
    pass: true,
    positiveCount: matchedPositives,
    negativeCollisions: 0,
    errorBound,
    failureReason: null,
  };
}

module.exports = {
  STANDARD_HARD_NEGATIVES,
  AMOUNT_FIELDS,
  parseAmountToPaise,
  computeWilsonScoreUpperBound,
  computeLaplaceErrorBound,
  evaluateCandidate,
  evaluateRule: evaluateCandidate,
};
