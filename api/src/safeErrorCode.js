'use strict';

const SAFE_ERROR_NAMES = new Set([
  'AbortError',
  'AggregateError',
  'AssertionError',
  'DatabaseError',
  'Error',
  'ReferenceError',
  'RangeError',
  'RequestError',
  'SyntaxError',
  'TypeError',
  'URIError',
]);

/** Return a bounded, allowlisted error identifier suitable for logs. */
function safeErrorCode(error) {
  const code = error?.code;
  if (Number.isInteger(code) && Math.abs(code) <= 99999999) return String(code);

  if (typeof code === 'string' && (
    /^[0-9A-Z]{5}$/.test(code) ||
    /^E[A-Z0-9_]{2,31}$/.test(code) ||
    /^ERR_[A-Z0-9_]{1,27}$/.test(code)
  )) {
    return code;
  }

  return SAFE_ERROR_NAMES.has(error?.name) ? error.name : 'Error';
}

module.exports = { safeErrorCode };
