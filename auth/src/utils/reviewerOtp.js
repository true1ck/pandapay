'use strict';

// === STORE-REVIEW LOGIN — works in production, off by default ===
//
// Google Play (and App Store) reviewers cannot receive an emailed or texted
// one-time code, so a reviewer account needs a code that is known in advance.
// This is NOT the dev-only test OTP in testOtp.js (which is hard-disabled in
// production). To keep a standing code safe it is restricted four ways, and
// every one must hold or the bypass is off:
//
//   REVIEWER_OTP_ENABLED=true         explicit switch, defaults off
//   REVIEWER_OTP_IDENTIFIERS=a,b      exact emails/phones, at most 4, lowercased
//   REVIEWER_OTP_CODE=NNNNNN          secret, exactly six digits, never in git
//   REVIEWER_OTP_UNTIL=ISO date       the bypass stops working after this moment
//
// The code is only ever issued for the listed identifiers; every other
// identifier gets a random code and a real email or SMS as before. The
// reviewer account must hold synthetic data only. Switch it off by removing
// REVIEWER_OTP_ENABLED (or letting REVIEWER_OTP_UNTIL pass) and restarting auth.

const MAX_IDENTIFIERS = 4;

function readConfig(env = process.env, now = Date.now()) {
  if (env.REVIEWER_OTP_ENABLED !== 'true') return null;
  const code = String(env.REVIEWER_OTP_CODE || '').trim();
  if (!/^\d{6}$/.test(code)) return null;
  const until = Date.parse(String(env.REVIEWER_OTP_UNTIL || '').trim());
  if (!Number.isFinite(until) || until <= now) return null;
  const identifiers = String(env.REVIEWER_OTP_IDENTIFIERS || '')
    .split(',')
    .map(value => value.trim().toLowerCase())
    .filter(Boolean);
  if (identifiers.length === 0 || identifiers.length > MAX_IDENTIFIERS) return null;
  return { code, identifiers: new Set(identifiers) };
}

function isReviewerOtpIdentifier(identifier, env = process.env, now = Date.now()) {
  const config = readConfig(env, now);
  return Boolean(config) && config.identifiers.has(String(identifier || '').trim().toLowerCase());
}

// Returns the fixed code for a listed identifier, otherwise null.
function reviewerOtpCode(identifier, env = process.env, now = Date.now()) {
  const config = readConfig(env, now);
  if (!config) return null;
  return config.identifiers.has(String(identifier || '').trim().toLowerCase()) ? config.code : null;
}

module.exports = { isReviewerOtpIdentifier, reviewerOtpCode, MAX_IDENTIFIERS };
