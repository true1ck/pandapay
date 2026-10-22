/**
 * Independent evaluator for SMS candidate rules against positive & hard-negative examples.
 *
 * Enforces zero-tolerance regression checks against hard negatives (OTPs, promotional spam,
 * EMI offers, refund/reversals, non-financial alerts, cross-family collisions) and verifies
 * exact paise amount and entity extraction. Enforces holdout evaluation and canary metrics.
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
  // EMI offers
  { text: 'Convert your transaction of Rs. 15,000 into easy EMI starting at Rs. 1,400/month. No paper work. SMS EMI to 56767.', category: 'emi_offer' },
  { text: 'Congratulations! You are eligible for instant EMI of Rs. 50,000 on your Credit Card ending 1234. Click to avail.', category: 'emi_offer' },
  // Refund / reversals
  { text: 'Refund of Rs. 450.00 for your order at Swiggy has been initiated to your account 1234.', category: 'refund_reversal' },
  { text: 'Reversal of Rs. 1,200.00 credited back to your card ending 5678 due to failed txn.', category: 'refund_reversal' },
  // Cross-family messages
  { text: 'AutoPay mandate registered for Rs. 1500 monthly towards Netflix.', family: 'mandate_lifecycle', category: 'cross_family' },
  { text: 'Your electricity bill of Rs. 1250 is due on 25-10-2026. Pay now to avoid late fee.', family: 'bill_obligation', category: 'cross_family' },
  { text: 'Available balance in A/c 1234 is Rs. 45000 as of 22-10-2026.', family: 'balance_snapshot', category: 'cross_family' },
  { text: 'debited by Rs. 500 on card 1234 at Amazon', family: 'posted_movement', category: 'cross_family' },
];

const ACTION_THRESHOLDS = {
  ignore_noise: {
    minDistinctUsers: 10,
    minPositives: 10,
    maxErrorBound: 0.02,
    maxNegativeCollisions: 0,
    requireZeroFinancialTerms: true,
  },
  posted_movement: {
    minDistinctUsers: 5,
    minDistinctUsersForActive: 10,
    minPositives: 5,
    maxErrorBound: 0.05,
    maxNegativeCollisions: 0,
    requireExactPaise: true,
  },
  balance_snapshot: {
    minDistinctUsers: 5,
    minDistinctUsersForActive: 8,
    minPositives: 5,
    maxErrorBound: 0.05,
    maxNegativeCollisions: 0,
  },
  bill_obligation: {
    minDistinctUsers: 5,
    minDistinctUsersForActive: 8,
    minPositives: 5,
    maxErrorBound: 0.05,
    maxNegativeCollisions: 0,
  },
  mandate_lifecycle: {
    minDistinctUsers: 5,
    minDistinctUsersForActive: 8,
    minPositives: 5,
    maxErrorBound: 0.05,
    maxNegativeCollisions: 0,
  },
};

const FINANCIAL_KEYWORDS = /\b(?:debited|credited|paid|spent|transferred|withdrawn|received|due date|amount due|available bal|avail bal)\b/i;

/**
 * Checks whether a sender pattern represents an unsafe wildcard.
 *
 * @param {string} pattern
 * @returns {boolean}
 */
function isWildcardSenderPattern(pattern) {
  if (!pattern || typeof pattern !== 'string') return true;
  const p = pattern.trim();
  return (
    p === '*' ||
    p === '.*' ||
    p === '.+' ||
    p === '.*?' ||
    p === '.+?' ||
    p === '^.*$' ||
    p === '^.*' ||
    p.includes('*') ||
    p.includes('.*')
  );
}

/**
 * Matches a sender against a concrete issuer pattern.
 * Wildcard patterns ('.*' or '*') are strictly rejected and return false.
 *
 * @param {string} senderPattern
 * @param {string} sender
 * @returns {boolean}
 */
function senderMatches(senderPattern, sender) {
  if (!senderPattern || isWildcardSenderPattern(senderPattern)) return false;
  if (!sender) return false;
  const upperSender = String(sender).toUpperCase();
  const upperPattern = String(senderPattern).toUpperCase();
  if (upperSender.includes(upperPattern)) return true;
  try {
    return new RegExp(senderPattern, 'i').test(sender);
  } catch {
    return false;
  }
}

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
 * Splits provided examples into a candidate-generation set and a frozen holdout set.
 * Partitions by distinct user_hash (if present), timestamp (if present), or distinct message wording.
 *
 * @param {Array|object} dataset - Array of examples or { positives: [], negatives: [] }
 * @param {object} [options]
 * @param {number} [options.holdoutRatio=0.3] - Fraction of distinct keys to allocate to holdout
 * @returns {{ generationSet: Array, holdoutSet: Array, generationDataset: object, holdoutDataset: object }}
 */
function splitHoldoutDataset(dataset, options = {}) {
  let positives = [];
  let negatives = [];

  if (Array.isArray(dataset)) {
    for (const item of dataset) {
      if (item.is_negative || item.isNegative || item.expectedMatch === false) {
        negatives.push(item);
      } else {
        positives.push(item);
      }
    }
  } else if (dataset && typeof dataset === 'object') {
    positives = Array.isArray(dataset.positives) ? [...dataset.positives] : [];
    negatives = Array.isArray(dataset.negatives)
      ? [...dataset.negatives]
      : (Array.isArray(dataset.hardNegatives) ? [...dataset.hardNegatives] : []);
  }

  const holdoutRatio = typeof options.holdoutRatio === 'number' && options.holdoutRatio > 0 && options.holdoutRatio < 1
    ? options.holdoutRatio
    : 0.3;

  function partitionList(items) {
    if (items.length <= 1) {
      return { generation: items, holdout: [] };
    }

    // 1. Check if user_hash is available across items
    const userHashes = new Set();
    for (const item of items) {
      const u = item.user_hash || item.userHash || item.userId;
      if (u) userHashes.add(u);
    }

    if (userHashes.size >= 2) {
      const sortedUsers = Array.from(userHashes).sort();
      const holdoutCount = Math.max(1, Math.round(sortedUsers.length * holdoutRatio));
      const holdoutUsers = new Set(sortedUsers.slice(sortedUsers.length - holdoutCount));

      const generation = [];
      const holdout = [];
      for (const item of items) {
        const u = item.user_hash || item.userHash || item.userId;
        if (u && holdoutUsers.has(u)) {
          holdout.push(item);
        } else {
          generation.push(item);
        }
      }
      if (generation.length > 0 && holdout.length > 0) {
        return { generation, holdout };
      }
    }

    // 2. Check if timestamp is available across items
    const hasTimestamps = items.every((item) => {
      const ts = item.created_at || item.createdAt || item.timestamp || item.time;
      return ts !== undefined && !Number.isNaN(new Date(ts).getTime());
    });

    if (hasTimestamps) {
      const sortedByTime = [...items].sort((a, b) => {
        const tA = new Date(a.created_at || a.createdAt || a.timestamp || a.time).getTime();
        const tB = new Date(b.created_at || b.createdAt || b.timestamp || b.time).getTime();
        return tA - tB;
      });
      const holdoutCount = Math.max(1, Math.round(sortedByTime.length * holdoutRatio));
      const splitIdx = Math.max(1, sortedByTime.length - holdoutCount);
      return {
        generation: sortedByTime.slice(0, splitIdx),
        holdout: sortedByTime.slice(splitIdx),
      };
    }

    // 3. Partition by distinct message wording
    const textGroups = new Map();
    for (const item of items) {
      const text = (item.sample_body || item.sampleBody || item.text || item.body || '').trim();
      if (!textGroups.has(text)) {
        textGroups.set(text, []);
      }
      textGroups.get(text).push(item);
    }

    if (textGroups.size >= 2) {
      const distinctTexts = Array.from(textGroups.keys()).sort();
      const holdoutTextCount = Math.max(1, Math.round(distinctTexts.length * holdoutRatio));
      const holdoutTexts = new Set(distinctTexts.slice(distinctTexts.length - holdoutTextCount));

      const generation = [];
      const holdout = [];
      for (const [text, groupItems] of textGroups.entries()) {
        if (holdoutTexts.has(text)) {
          holdout.push(...groupItems);
        } else {
          generation.push(...groupItems);
        }
      }
      if (generation.length > 0 && holdout.length > 0) {
        return { generation, holdout };
      }
    }

    // 4. Fallback: split deterministically by index
    const holdoutCount = Math.max(1, Math.round(items.length * holdoutRatio));
    const splitIdx = Math.max(1, items.length - holdoutCount);
    return {
      generation: items.slice(0, splitIdx),
      holdout: items.slice(splitIdx),
    };
  }

  const posPartition = partitionList(positives);

  return {
    generationSet: posPartition.generation,
    holdoutSet: posPartition.holdout,
    generationDataset: { positives: posPartition.generation, negatives },
    holdoutDataset: { positives: posPartition.holdout, negatives },
  };
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
  const candidateSenderPattern = candidate.senderPattern || candidate.sender_pattern;
  const isProduction = options.isProduction ?? (process.env.NODE_ENV === 'production');

  // Verify sender pattern: wildcards ('.*' or '*') are never permitted
  if (candidateSenderPattern !== undefined && candidateSenderPattern !== null) {
    if (isWildcardSenderPattern(candidateSenderPattern)) {
      return {
        pass: false,
        positiveCount: 0,
        negativeCollisions: 0,
        errorBound: 1.0,
        failureReason: 'wildcard_sender_forbidden',
      };
    }
  } else if (isProduction || options.requireConcreteSender) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'missing_sender_pattern',
    };
  }

  // Disallow ignore_noise rules that match any financial keywords
  if (family === 'ignore_noise' && FINANCIAL_KEYWORDS.test(regexStr)) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'ignore_noise_cannot_match_financial_keywords',
    };
  }

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
      // Include non-financial/OTP/promo/EMI/refund, and only cross-family if candidate family differs
      if (!sn.family || sn.family !== family) {
        negatives.push(sn);
      }
    }
  }

  // 1. Hard negative collision check (zero tolerance)
  let negativeCollisions = 0;
  for (const neg of negatives) {
    const text = neg.sample_body || neg.sampleBody || neg.text || neg.body || '';
    const negSender = neg.sender;
    // Check sender condition if negative sample specifies sender
    if (negSender && candidateSenderPattern && !senderMatches(candidateSenderPattern, negSender)) {
      continue;
    }
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
    const posSender = pos.sender;

    // Sender evaluation: device only runs rule if sender matches
    if (posSender && candidateSenderPattern && !senderMatches(candidateSenderPattern, posSender)) {
      errors += 1;
      continue;
    }

    const match = text.match(re);
    if (!match) {
      errors += 1;
      continue;
    }

    // Extraction test: check exact field extraction for amountPaise, last4, merchant, reference, dueDate
    const expected = pos.extracted_fields || pos.extractedFields || pos.expectedFields || pos.expected || {};
    let exampleExtractionPassed = true;

    for (const [fieldName, groupIdx] of Object.entries(fieldMap)) {
      const extractedRaw = match[groupIdx];

      if (AMOUNT_FIELDS.has(fieldName)) {
        const extractedPaise = parseAmountToPaise(extractedRaw);

        if (extractedPaise === null || !Number.isInteger(extractedPaise)) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }

        // Determine expected paise if provided
        let expectedPaise = null;
        if (expected[fieldName + 'Paise'] !== undefined) {
          expectedPaise = Number(expected[fieldName + 'Paise']);
        } else if (expected.amountPaise !== undefined) {
          expectedPaise = Number(expected.amountPaise);
        } else if (expected[fieldName + 'Inr'] !== undefined) {
          expectedPaise = Math.round(Number(expected[fieldName + 'Inr']) * 100);
        } else if (expected.amountInr !== undefined) {
          expectedPaise = Math.round(Number(expected.amountInr) * 100);
        } else if (expected[fieldName] !== undefined) {
          expectedPaise = parseAmountToPaise(expected[fieldName]);
        } else if (expected.amount !== undefined) {
          expectedPaise = parseAmountToPaise(expected.amount);
        }

        if (expectedPaise !== null && extractedPaise !== expectedPaise) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      } else if (fieldName === 'last4' || fieldName === 'accountLast4') {
        const expLast4 = expected[fieldName] ?? expected.last4 ?? expected.accountLast4;
        if (expLast4 !== undefined && String(extractedRaw).trim() !== String(expLast4).trim()) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      } else if (fieldName === 'merchant') {
        const expMerchant = expected.merchant ?? expected[fieldName];
        if (expMerchant !== undefined && String(extractedRaw).trim().toLowerCase() !== String(expMerchant).trim().toLowerCase()) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      } else if (fieldName === 'reference' || fieldName === 'ref') {
        const expRef = expected.reference ?? expected.ref ?? expected[fieldName];
        if (expRef !== undefined && String(extractedRaw).trim() !== String(expRef).trim()) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      } else if (fieldName === 'dueDate' || fieldName === 'date' || fieldName === 'asOf') {
        const expDueDate = expected.dueDate ?? (fieldName === 'dueDate' ? expected.date : expected[fieldName]);
        if (expDueDate !== undefined && String(extractedRaw).trim().toLowerCase() !== String(expDueDate).trim().toLowerCase()) {
          exampleExtractionPassed = false;
          extractionMismatchCount += 1;
          break;
        }
      }
    }

    if (exampleExtractionPassed && expected.amountPaise !== undefined) {
      const hasAmountField = Object.keys(fieldMap).some((k) => AMOUNT_FIELDS.has(k));
      if (!hasAmountField) {
        exampleExtractionPassed = false;
        extractionMismatchCount += 1;
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

  // 1. Min positive count check if requested or in production
  const familyThreshold = ACTION_THRESHOLDS[family];
  if (options.minPositives !== undefined && matchedPositives < options.minPositives) {
    return {
      pass: false,
      positiveCount: matchedPositives,
      negativeCollisions: 0,
      errorBound,
      failureReason: 'insufficient_positive_samples',
    };
  }
  if (options.enforceMinPositives === true || isProduction) {
    const minRequiredPositives = familyThreshold ? (familyThreshold.minPositives || 5) : 5;
    if (matchedPositives < minRequiredPositives) {
      return {
        pass: false,
        positiveCount: matchedPositives,
        negativeCollisions: 0,
        errorBound,
        failureReason: 'insufficient_positive_samples',
      };
    }
  }

  // 2. Determine allowed error bound based on action-specific threshold
  const maxAllowedError = options.maxErrorBound !== undefined
    ? options.maxErrorBound
    : ((options.enforceErrorBound || isProduction) ? (familyThreshold ? familyThreshold.maxErrorBound : 0.05) : undefined);

  if (maxAllowedError !== undefined && errorBound > maxAllowedError) {
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

/**
 * Evaluates candidate rule against a frozen holdout set.
 * Enforces:
 * - Concrete issuer prefix sender pattern (never wildcard '.*' or '*')
 * - Exact field extraction for amountPaise (exact integer paise), last4, merchant, reference, dueDate
 * - Zero regressions on hard negatives (OTP, promotions, EMI offers, refund/reversals)
 * - Statistical error bound compared against ACTION_THRESHOLDS[family]
 *
 * @param {object} candidate
 * @param {Array|object} holdoutDataset - Array of holdout examples or { positives, negatives }
 * @param {object} [options]
 * @returns {object}
 */
function evaluateHoldout(candidate, holdoutDataset, options = {}) {
  let holdoutPositives = [];
  let negatives = [];

  if (Array.isArray(holdoutDataset)) {
    holdoutPositives = holdoutDataset.filter((i) => !i.is_negative && !i.isNegative && i.expectedMatch !== false);
    negatives = holdoutDataset.filter((i) => i.is_negative || i.isNegative || i.expectedMatch === false);
  } else if (holdoutDataset && typeof holdoutDataset === 'object') {
    if (Array.isArray(holdoutDataset.holdoutSet)) {
      holdoutPositives = holdoutDataset.holdoutSet;
      negatives = Array.isArray(holdoutDataset.negatives) ? holdoutDataset.negatives : [];
    } else if (Array.isArray(holdoutDataset.holdout)) {
      holdoutPositives = holdoutDataset.holdout;
      negatives = Array.isArray(holdoutDataset.negatives) ? holdoutDataset.negatives : [];
    } else if (Array.isArray(holdoutDataset.positives)) {
      holdoutPositives = holdoutDataset.positives;
      negatives = Array.isArray(holdoutDataset.negatives) ? holdoutDataset.negatives : [];
    }
  }

  const candidateSenderPattern = candidate?.senderPattern || candidate?.sender_pattern;
  if (!candidateSenderPattern || isWildcardSenderPattern(candidateSenderPattern)) {
    return {
      pass: false,
      positiveCount: 0,
      negativeCollisions: 0,
      errorBound: 1.0,
      failureReason: 'wildcard_sender_forbidden',
      holdoutSize: holdoutPositives.length,
      isHoldout: true,
    };
  }

  const family = candidate?.family || 'posted_movement';
  const familyThreshold = ACTION_THRESHOLDS[family] || { maxErrorBound: 0.05, minPositives: 1 };

  const evalOptions = {
    ...options,
    enforceErrorBound: true,
    maxErrorBound: options.maxErrorBound ?? familyThreshold.maxErrorBound,
    enforceMinPositives: options.enforceMinPositives ?? false,
    minPositives: options.minPositives ?? 1,
    requireConcreteSender: true,
    includeStandardNegatives: options.includeStandardNegatives !== false,
  };

  const evalResult = evaluateCandidate(candidate, { positives: holdoutPositives, negatives }, evalOptions);

  return {
    ...evalResult,
    isHoldout: true,
    holdoutSize: holdoutPositives.length,
  };
}

/**
 * Evaluates candidate metrics during shadow/canary stages (shadow, limited, expanded).
 * Checks elapsed window time, minimum exposure count, correction rate, and false discard rate.
 *
 * @param {object} candidate - { state, stage_metrics }
 * @param {object} metrics - { exposures, corrections, false_discards, window_start, window_end }
 * @param {object} [options] - { minObservationMs, minExposures, maxCorrectionRate, maxFalseDiscardRate, now }
 * @returns {{ passed: boolean, shouldRollback: boolean, reason?: string, correctionRate?: number, falseDiscardRate?: number }}
 */
function evaluateCanaryMetrics(candidate, metrics, options = {}) {
  const DEFAULT_MIN_OBSERVATION_MS = 24 * 60 * 60 * 1000; // 24 hours (86,400,000 ms)
  const DEFAULT_STAGE_MIN_EXPOSURES = {
    shadow: 10,
    limited: 25,
    expanded: 50,
  };

  const state = candidate?.state;
  const defaultExposures = (state && DEFAULT_STAGE_MIN_EXPOSURES[state]) ? DEFAULT_STAGE_MIN_EXPOSURES[state] : 10;
  const minExposures = options.minExposures !== undefined ? options.minExposures : defaultExposures;
  const minObservationMs = options.minObservationMs !== undefined ? options.minObservationMs : DEFAULT_MIN_OBSERVATION_MS;
  const maxCorrectionRate = options.maxCorrectionRate !== undefined ? options.maxCorrectionRate : 0.01;
  const maxFalseDiscardRate = options.maxFalseDiscardRate !== undefined ? options.maxFalseDiscardRate : 0.005;

  const m = metrics || {};
  const exposures = Number(m.exposures) || 0;
  const corrections = Number(m.corrections) || 0;
  const falseDiscards = Number(m.false_discards ?? m.falseDiscards) || 0;

  const now = options.now !== undefined ? new Date(options.now).getTime() : Date.now();
  const rawStart = m.window_start ?? m.windowStart;
  const windowStart = rawStart ? new Date(rawStart).getTime() : NaN;
  const elapsedMs = Number.isFinite(windowStart) ? Math.max(0, now - windowStart) : 0;

  const correctionRate = exposures > 0 ? (corrections / exposures) : 0;
  const falseDiscardRate = exposures > 0 ? (falseDiscards / exposures) : 0;

  // 1. High error rate triggers rollback
  if ((exposures > 0 && (correctionRate > maxCorrectionRate || falseDiscardRate > maxFalseDiscardRate)) ||
      (exposures === 0 && (corrections > 0 || falseDiscards > 0))) {
    return {
      passed: false,
      shouldRollback: true,
      reason: 'high_error_rate',
      correctionRate,
      falseDiscardRate,
      exposures,
      elapsedMs,
    };
  }

  // 2. Insufficient observation or exposures prevents progression without rollback
  const isWindowSufficient = Number.isFinite(windowStart) && elapsedMs >= minObservationMs;
  const isExposuresSufficient = exposures >= minExposures;

  if (!isWindowSufficient || !isExposuresSufficient) {
    return {
      passed: false,
      shouldRollback: false,
      reason: 'insufficient_observation',
      correctionRate,
      falseDiscardRate,
      exposures,
      minExposures,
      elapsedMs,
      minObservationMs,
    };
  }

  // 3. All criteria met
  return {
    passed: true,
    shouldRollback: false,
    reason: null,
    correctionRate,
    falseDiscardRate,
    exposures,
    elapsedMs,
  };
}

module.exports = {
  STANDARD_HARD_NEGATIVES,
  ACTION_THRESHOLDS,
  senderMatches,
  isWildcardSenderPattern,
  AMOUNT_FIELDS,
  parseAmountToPaise,
  computeWilsonScoreUpperBound,
  computeLaplaceErrorBound,
  splitHoldoutDataset,
  evaluateHoldout,
  evaluateCanaryMetrics,
  evaluateCandidate,
  evaluateRule: evaluateCandidate,
};
