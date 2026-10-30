/**
 * Restricted typed template compiler for autonomous SMS rule learning.
 *
 * Compiles human-readable/synthesized SMS templates containing typed slots
 * into strict, ReDoS-safe regular expressions with deterministic field mappings.
 */

const { isSafeRegex, countCaptureGroups, ALLOWED_FIELDS } = require('./sms_rule_bundle');

const FINANCIAL_KEYWORDS = /\b(?:debited|credited|paid|spent|transferred|withdrawn|received|due date|amount due|available bal|avail bal)\b/i;

const ISSUER_MAP = {
  HDFC: 'HDFC',
  HDFCBK: 'HDFC',
  ICICI: 'ICICI',
  ICICIB: 'ICICI',
  SBI: 'SBI',
  SBIN: 'SBI',
  SBIINB: 'SBI',
  AXIS: 'AXIS',
  AXISBK: 'AXIS',
  KOTAK: 'KOTAK',
  KOTAKB: 'KOTAK',
  PNB: 'PNB',
  PNBSMS: 'PNB',
  YES: 'YES',
  YESBNK: 'YES',
  IDFC: 'IDFC',
  IDFCFB: 'IDFC',
  CANARA: 'CANARA',
  CANBNK: 'CANARA',
  BOB: 'BOB',
  BOI: 'BOI',
  INDUS: 'INDUS',
  INDUSB: 'INDUS',
  RBL: 'RBL',
  RBLBNK: 'RBL',
  FEDERAL: 'FEDERAL',
  FEDBNK: 'FEDERAL',
};

/**
 * Extracts a normalized bank issuer token from SMS sender string (e.g. "AD-HDFCBK" -> "HDFC").
 * Returns null if sender is empty or issuer cannot be identified.
 * Never returns wildcards ('.*' or '*').
 *
 * @param {string} sender
 * @returns {string|null}
 */
function deriveIssuerPrefix(sender) {
  if (typeof sender !== 'string' || !sender.trim()) return null;
  const upper = sender.trim().toUpperCase();
  // Strictly forbid wildcards
  if (upper === '.*' || upper === '*' || upper === '.+' || upper.includes('*') || upper.includes('.*')) {
    return null;
  }

  const match = upper.match(/^[A-Z]{2}-([A-Z0-9]+)(?:-[A-Z]+)?$/);
  const token = match ? match[1] : upper.replace(/[^A-Z0-9]/g, '');
  if (!token) return null;

  for (const [key, issuer] of Object.entries(ISSUER_MAP)) {
    if (token.includes(key)) {
      return issuer;
    }
  }
  return token.length >= 3 ? token : null;
}

/**
 * Derives a strict, non-wildcard sender pattern for a candidate rule.
 * Never returns '.*' or '*' - returns null if issuer is unknown so candidate proposal can abstain.
 *
 * @param {string} sender
 * @returns {string|null}
 */
function deriveSenderPattern(sender) {
  const issuer = deriveIssuerPrefix(sender);
  if (!issuer || issuer === '*' || issuer === '.*' || issuer.includes('*')) return null;
  return issuer;
}

const SLOT_DEFINITIONS = {
  AMOUNT: '(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?)',
  LAST4: '([0-9]{4})',
  MERCHANT: '([A-Za-z0-9\\s&._-]{2,40}?)',
  DATE: '(\\d{1,2}(?:[-/]\\d{1,2}|\\s+[A-Za-z]{3,9})[-/\\s]\\d{2,4})',
  REF: '([A-Za-z0-9]{6,25})',
  BAL: '(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?)',
  DUE_DATE: '(\\d{1,2}(?:[-/]\\d{1,2}|\\s+[A-Za-z]{3,9})[-/\\s]\\d{2,4})',
  OPT_SPACE: '\\s*',
};

const MAX_REGEX_LENGTH = 250;

function escapeRegex(literal) {
  if (typeof literal !== 'string') return '';
  return literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Compiles a template string into a safe, bounded regex with a capture-group field map.
 *
 * @param {string} template - e.g. "debited by {AMOUNT} on card {LAST4} at {MERCHANT}"
 * @param {object|string} [options] - options or family name
 * @returns {{ compiledRegex: string|null, fieldMap: object, valid: boolean, error: string|null }}
 */
function compileTemplate(template, options = {}) {
  const opts = typeof options === 'string' ? { family: options } : (options || {});
  if (typeof template !== 'string' || template.trim().length === 0) {
    return { compiledRegex: null, fieldMap: {}, valid: false, error: 'template_empty_or_invalid' };
  }

  if (template.length > MAX_REGEX_LENGTH) {
    return {
      compiledRegex: null,
      fieldMap: {},
      valid: false,
      error: `template_exceeds_max_length (${template.length} > ${MAX_REGEX_LENGTH})`,
    };
  }

  const family = opts.family || 'posted_movement';
  const customSlotMap = opts.slotMap || opts.fieldOverrides || {};

  let compiledRegex = '';
  const fieldMap = {};
  let currentGroup = 0;
  let lastIndex = 0;
  const slotPattern = /\{([A-Za-z0-9_]+)\}/g;
  let match;

  while ((match = slotPattern.exec(template)) !== null) {
    const literal = template.slice(lastIndex, match.index);
    if (literal.length > 0) {
      compiledRegex += escapeRegex(literal);
    }
    lastIndex = slotPattern.lastIndex;

    const slotName = match[1];
    if (!(slotName in SLOT_DEFINITIONS)) {
      return {
        compiledRegex: null,
        fieldMap: {},
        valid: false,
        error: `unknown_slot: {${slotName}}`,
      };
    }

    const slotReplacement = SLOT_DEFINITIONS[slotName];
    compiledRegex += slotReplacement;

    if (slotName !== 'OPT_SPACE') {
      currentGroup += 1;
      let fieldName = customSlotMap[slotName];
      if (!fieldName) {
        switch (slotName) {
          case 'AMOUNT':
            fieldName = family === 'bill_obligation' ? 'amountDue' : 'amount';
            break;
          case 'LAST4':
            fieldName = family === 'balance_snapshot' ? 'accountLast4' : 'last4';
            break;
          case 'MERCHANT':
            fieldName = 'merchant';
            break;
          case 'DATE':
            fieldName = family === 'bill_obligation' ? 'dueDate' : 'asOf';
            break;
          case 'REF':
            fieldName = 'reference';
            break;
          case 'BAL':
            fieldName = 'availableBalance';
            break;
          case 'DUE_DATE':
            fieldName = 'dueDate';
            break;
          default:
            fieldName = slotName.toLowerCase();
        }
      }

      if (fieldName) {
        fieldMap[fieldName] = currentGroup;
      }
    }
  }

  const trailingLiteral = template.slice(lastIndex);
  if (trailingLiteral.length > 0) {
    compiledRegex += escapeRegex(trailingLiteral);
  }

  // Length check
  if (compiledRegex.length > MAX_REGEX_LENGTH) {
    return {
      compiledRegex,
      fieldMap,
      valid: false,
      error: `compiled_regex_exceeds_max_length (${compiledRegex.length} > ${MAX_REGEX_LENGTH})`,
    };
  }

  // Safe regex check
  if (!isSafeRegex(compiledRegex)) {
    return {
      compiledRegex,
      fieldMap,
      valid: false,
      error: 'unsafe_regex',
    };
  }

  // Valid RegExp compilation check
  try {
    new RegExp(compiledRegex);
  } catch (err) {
    return {
      compiledRegex,
      fieldMap,
      valid: false,
      error: `regex_compilation_failed: ${err.message}`,
    };
  }

  // Validate fieldMap entries against allowed fields if family is not ignore_noise
  const finalFieldMap = opts.fieldMap && typeof opts.fieldMap === 'object' && !Array.isArray(opts.fieldMap)
    ? { ...opts.fieldMap }
    : fieldMap;

  if (family === 'ignore_noise') {
    if (FINANCIAL_KEYWORDS.test(compiledRegex)) {
      return {
        compiledRegex,
        fieldMap: {},
        valid: false,
        error: 'ignore_noise_cannot_match_financial_keywords',
      };
    }
  } else {
    for (const [field, groupIdx] of Object.entries(finalFieldMap)) {
      if (!ALLOWED_FIELDS.has(field)) {
        return {
          compiledRegex,
          fieldMap: finalFieldMap,
          valid: false,
          error: `forbidden_field_mapping: ${field}`,
        };
      }
      if (!Number.isInteger(groupIdx) || groupIdx < 1 || groupIdx > currentGroup) {
        return {
          compiledRegex,
          fieldMap: finalFieldMap,
          valid: false,
          error: `invalid_capture_group_index_${groupIdx}_for_${field}`,
        };
      }
    }
  }

  return {
    compiledRegex,
    fieldMap: family === 'ignore_noise' ? {} : finalFieldMap,
    valid: true,
    error: null,
  };
}

/**
 * Synthesizes a slot-based template from a sample body and known extracted fields.
 * Replaces changing transaction data with typed placeholders ({AMOUNT}, {LAST4}, etc.).
 *
 * @param {string} sampleBody
 * @param {object} [extractedFields]
 * @returns {string}
 */
function synthesizeTemplate(sampleBody, extractedFields = {}) {
  if (typeof sampleBody !== 'string' || !sampleBody.trim()) return '';
  let text = sampleBody.trim().replace(/\s+/g, ' ');

  // 1. Balance replacement
  const balVal = extractedFields.availableBalance || extractedFields.currentBalance || extractedFields.bal;
  if (balVal) {
    const balText = String(balVal);
    const balNum = balText.replace(/,/g, '');
    const balGrouped = balNum.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    const balPattern = new RegExp(`(?:₹|Rs\\.?|INR)\\s*(?:${escapeRegex(balText)}|${escapeRegex(balNum)}|${escapeRegex(balGrouped)})(?:\\.00)?`, 'i');
    const before = text;
    text = text.replace(balPattern, '{BAL}');
    if (text === before) {
      text = text.replace(/(?<=\b(?:bal|balance|avl bal|avail bal)\s*[:=]?\s*)(?:₹|Rs\.?|INR)\s*[0-9,]+(?:\.[0-9]{1,2})?/i, '{BAL}');
    }
  } else {
    text = text.replace(/(?<=\b(?:bal|balance|avl bal|avail bal)\s*[:=]?\s*)(?:₹|Rs\.?|INR)\s*[0-9,]+(?:\.[0-9]{1,2})?/gi, '{BAL}');
  }

  // 2. Amount replacement
  const amtVal = extractedFields.amount || extractedFields.amountDue || extractedFields.amountInr;
  if (amtVal) {
    const amtText = String(amtVal);
    const amtNum = amtText.replace(/,/g, '');
    const amtGrouped = amtNum.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    const amtPattern = new RegExp(`(?:₹|Rs\\.?|INR)\\s*(?:${escapeRegex(amtText)}|${escapeRegex(amtNum)}|${escapeRegex(amtGrouped)})(?:\\.00)?`, 'i');
    const before = text;
    text = text.replace(amtPattern, '{AMOUNT}');
    if (text === before) {
      text = text.replace(/(?<!\{BAL\})(?:₹|Rs\.?|INR)\s*[0-9,]+(?:\.[0-9]{1,2})?/i, '{AMOUNT}');
    }
  } else {
    text = text.replace(/(?<!\{BAL\})(?:₹|Rs\.?|INR)\s*[0-9,]+(?:\.[0-9]{1,2})?/i, '{AMOUNT}');
  }

  // 3. Due Date replacement
  const dueDateVal = extractedFields.dueDate;
  if (dueDateVal) {
    text = text.replace(new RegExp(escapeRegex(String(dueDateVal)), 'i'), '{DUE_DATE}');
  }

  // 4. Date replacement
  const dateVal = extractedFields.asOf || extractedFields.date;
  if (dateVal) {
    text = text.replace(new RegExp(escapeRegex(String(dateVal)), 'i'), '{DATE}');
  } else {
    text = text.replace(/\b[0-9]{1,2}[-/][0-9]{1,2}[-/][0-9]{2,4}\b|\b[0-9]{1,2}\s+[A-Za-z]{3,9}\s+[0-9]{2,4}\b/i, '{DATE}');
  }

  // 5. Last4 replacement
  const last4Val = extractedFields.last4 || extractedFields.accountLast4;
  if (last4Val && String(last4Val).length === 4) {
    const last4 = escapeRegex(String(last4Val));
    text = text.replace(new RegExp(`\\b(?:X{2,12}|\\*{2,12})?${last4}\\b`, 'i'), '{LAST4}');
  } else {
    text = text.replace(/(?<=\b(?:card|a\/c|ac|account)\s*(?:no\.?|ending)?\s*(?:[Xx*]{2,12})?\s*)[0-9]{4}\b/i, '{LAST4}');
  }

  // 6. Reference replacement
  const refVal = extractedFields.reference || extractedFields.ref;
  if (refVal) {
    text = text.replace(new RegExp(`\\b${escapeRegex(String(refVal))}\\b`, 'i'), '{REF}');
  } else {
    text = text.replace(/(?<=\b(?:ref|rrn|utr|txn id)\s*[:#-]?\s*)[A-Za-z0-9]{6,25}\b/i, '{REF}');
  }

  // 7. Merchant replacement
  const merchantVal = extractedFields.merchant;
  if (merchantVal && typeof merchantVal === 'string' && merchantVal.length >= 2) {
    text = text.replace(new RegExp(`(?<=\\b(?:at|to|towards|for)\\s+)${escapeRegex(merchantVal)}`, 'i'), '{MERCHANT}');
  }

  return text.trim();
}

module.exports = {
  SLOT_DEFINITIONS,
  MAX_REGEX_LENGTH,
  escapeRegex,
  compileTemplate,
  deriveIssuerPrefix,
  deriveSenderPattern,
  synthesizeTemplate,
};
