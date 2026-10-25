'use strict';

// Immediate admission, no queue or per-recipient map. These process-local
// bounds supplement (never replace) the durable cross-instance abuse store.
const DEFAULT_LIMITS = Object.freeze({ workMaxConcurrent: 2, emailMaxConcurrent: 2, smsMaxConcurrent: 2 });
const VARIABLES = Object.freeze({ workMaxConcurrent: 'OTP_WORK_MAX_CONCURRENT', emailMaxConcurrent: 'OTP_EMAIL_MAX_CONCURRENT', smsMaxConcurrent: 'OTP_SMS_MAX_CONCURRENT' });
const BUSY_CODE = 'otp_capacity_unavailable';
const RETRY_AFTER_SECONDS = 2;

function validateLimits(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== 3 || Object.keys(value).some(key => !Object.hasOwn(DEFAULT_LIMITS, key)) ||
      Object.values(value).some(limit => !Number.isSafeInteger(limit) || limit < 1 || limit > 16)) {
    throw new Error('Invalid OTP concurrency limits');
  }
  return value;
}
function readAdmissionLimits(env = process.env) {
  const limits = {};
  for (const [key, variable] of Object.entries(VARIABLES)) {
    const raw = env[variable];
    if (raw === undefined || raw === '') limits[key] = DEFAULT_LIMITS[key];
    else {
      if (typeof raw !== 'string' || !/^(?:[1-9]|1[0-6])$/.test(raw)) throw new Error(`Invalid ${variable}; use an integer from 1 to 16`);
      limits[key] = Number(raw);
    }
  }
  return validateLimits(limits);
}
class OtpCapacityError extends Error {
  constructor() { super('Authentication is temporarily busy'); this.name = 'OtpCapacityError'; this.code = BUSY_CODE; }
}
function respondOtpCapacityUnavailable(res) {
  res.setHeader('Retry-After', String(RETRY_AFTER_SECONDS));
  res.setHeader('Cache-Control', 'no-store');
  return res.status(503).json({ error: 'Authentication is temporarily busy. Please try again shortly.', code: BUSY_CODE });
}
function createOtpWorkAdmission(limits = DEFAULT_LIMITS) {
  validateLimits(limits);
  const stages = Object.fromEntries(Object.entries({ work: limits.workMaxConcurrent, email: limits.emailMaxConcurrent, sms: limits.smsMaxConcurrent })
    .map(([name, maximum]) => [name, { maximum, active: 0, admitted: 0, rejected: 0, failed: 0 }]));
  const increment = (state, key) => { state[key] = Math.min(Number.MAX_SAFE_INTEGER, state[key] + 1); };
  async function run(stage, operation) {
    if (!Object.hasOwn(stages, stage) || typeof operation !== 'function') throw new TypeError('Invalid OTP admission operation');
    const state = stages[stage];
    if (state.active >= state.maximum) { increment(state, 'rejected'); throw new OtpCapacityError(); }
    // No await between checking and claiming: one JS process cannot overbook.
    state.active++; increment(state, 'admitted');
    try { return await operation(); }
    catch (error) { increment(state, 'failed'); throw error; }
    // Hold the slot until the real operation settles. A response timeout must
    // not free it early while native work/provider I/O is still running.
    finally { state.active--; }
  }
  return { run, snapshot: () => Object.fromEntries(Object.entries(stages).map(([name, state]) => [name, { ...state }])) };
}
let runtime;
function getOtpWorkAdmission() { return runtime ||= createOtpWorkAdmission(readAdmissionLimits()); }
module.exports = { DEFAULT_LIMITS, VARIABLES, BUSY_CODE, RETRY_AFTER_SECONDS, validateLimits, readAdmissionLimits,
  OtpCapacityError, respondOtpCapacityUnavailable, createOtpWorkAdmission, getOtpWorkAdmission };
