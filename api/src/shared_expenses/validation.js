'use strict';

const MAX_EXPENSE_MINOR = 1000000000n;
const MAX_AGGREGATE_MINOR = 9007199254740991n;

class SharedExpenseError extends Error {
  constructor(code, field) {
    super(`${code} at ${field}`);
    this.name = 'SharedExpenseError';
    this.code = code;
    this.field = field;
  }
}
function fail(code, field) { throw new SharedExpenseError(code, field); }
// Comparing the entire match also rejects a trailing newline accepted by `$`.
function matches(pattern, value) {
  return typeof value === 'string' && pattern.exec(value)?.[0] === value;
}
function record(value, keys, field = '$', code = 'INVALID_INPUT', optional = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail(code, field);
  const allowed = new Set([...keys, ...optional]);
  if (keys.some(key => !Object.hasOwn(value, key)) || Object.keys(value).some(key => !allowed.has(key))) fail(code, field);
}
function amount(value, field, { max = MAX_EXPENSE_MINOR, positive = false, overflow = 'AMOUNT_LIMIT_EXCEEDED' } = {}) {
  if (typeof value !== 'string' || value.length > 16 || !matches(/^(0|[1-9][0-9]*)$/, value)) fail('INVALID_AMOUNT', field);
  const parsed = BigInt(value);
  if (positive && parsed === 0n) fail('INVALID_AMOUNT', field);
  if (parsed > max) fail(overflow, field);
  return parsed;
}
function member(value, field) {
  if (typeof value !== 'string' || value.length > 64 || !matches(/^[A-Za-z0-9][A-Za-z0-9_-]*$/, value)) fail('INVALID_MEMBER_ID', field);
  return value;
}
function currency(value) { if (value !== 'INR') fail('UNSUPPORTED_CURRENCY', 'currency'); }
function order(value, members, field) {
  if (!Array.isArray(value) || value.length !== members.size || new Set(value).size !== value.length
      || value.some(id => typeof id !== 'string' || !members.has(id))) fail('INVALID_TIE_ORDER', field);
  return new Map(value.map((id, index) => [id, index]));
}
function count(value, max, code, field) {
  if (!Array.isArray(value) || value.length < 1 || value.length > max) fail(code, field);
}
module.exports = { MAX_EXPENSE_MINOR, MAX_AGGREGATE_MINOR, SharedExpenseError, fail, matches, record, amount, member, currency, order, count };
