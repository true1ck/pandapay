/**
 * Restricted typed template compiler for autonomous SMS rule learning.
 *
 * Compiles human-readable/synthesized SMS templates containing typed slots
 * into strict, ReDoS-safe regular expressions with deterministic field mappings.
 */

const { isSafeRegex, countCaptureGroups, ALLOWED_FIELDS } = require('./sms_rule_bundle');

const SLOT_DEFINITIONS = {
  AMOUNT: '(?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
  LAST4: '([0-9]{4})',
  MERCHANT: '([A-Za-z0-9\\s&._-]{2,40}?)',
  DATE: '([0-9]{1,2}[-/][0-9]{1,2}[-/][0-9]{2,4}|[0-9]{1,2}\\s+[A-Za-z]{3,9}\\s+[0-9]{2,4})',
  REF: '([A-Za-z0-9]{6,25})',
  BAL: '(?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
  DUE_DATE: '([0-9]{1,2}[-/][0-9]{1,2}[-/][0-9]{2,4}|[0-9]{1,2}\\s+[A-Za-z]{3,9}\\s+[0-9]{2,4})',
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

  if (family !== 'ignore_noise') {
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
    fieldMap: finalFieldMap,
    valid: true,
    error: null,
  };
}

module.exports = {
  SLOT_DEFINITIONS,
  MAX_REGEX_LENGTH,
  escapeRegex,
  compileTemplate,
};
