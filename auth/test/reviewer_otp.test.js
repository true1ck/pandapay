'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { isReviewerOtpIdentifier, reviewerOtpCode } = require('../src/utils/reviewerOtp');

const NOW = Date.parse('2026-11-21T00:00:00Z');
const base = {
  NODE_ENV: 'production',
  REVIEWER_OTP_ENABLED: 'true',
  REVIEWER_OTP_CODE: '482916',
  REVIEWER_OTP_UNTIL: '2026-12-21T00:00:00Z',
  REVIEWER_OTP_IDENTIFIERS: 'Reviewer@Example.com, +911234567891',
};

test('reviewer code is issued only for listed identifiers, even in production', () => {
  assert.equal(reviewerOtpCode('reviewer@example.com', base, NOW), '482916');
  assert.equal(reviewerOtpCode(' REVIEWER@example.com ', base, NOW), '482916');
  assert.equal(reviewerOtpCode('+911234567891', base, NOW), '482916');
  assert.equal(reviewerOtpCode('someone@example.com', base, NOW), null);
  assert.equal(isReviewerOtpIdentifier('someone@example.com', base, NOW), false);
  assert.equal(isReviewerOtpIdentifier('reviewer@example.com', base, NOW), true);
});

test('legacy 4-digit protocol uses the first four digits, v2 uses all six', () => {
  assert.equal(reviewerOtpCode('reviewer@example.com', base, NOW, { legacy: true }), '4829');
  assert.equal(reviewerOtpCode('reviewer@example.com', base, NOW, { legacy: false }), '482916');
  assert.equal(reviewerOtpCode('someone@example.com', base, NOW, { legacy: true }), null);
});

test('bypass is off unless every setting is present and valid', () => {
  const off = (patch) => reviewerOtpCode('reviewer@example.com', { ...base, ...patch }, NOW);
  assert.equal(off({ REVIEWER_OTP_ENABLED: undefined }), null);
  assert.equal(off({ REVIEWER_OTP_ENABLED: 'yes' }), null);
  assert.equal(off({ REVIEWER_OTP_CODE: '1234' }), null);
  assert.equal(off({ REVIEWER_OTP_CODE: '12345a' }), null);
  assert.equal(off({ REVIEWER_OTP_CODE: undefined }), null);
  assert.equal(off({ REVIEWER_OTP_UNTIL: undefined }), null);
  assert.equal(off({ REVIEWER_OTP_UNTIL: 'not a date' }), null);
  assert.equal(off({ REVIEWER_OTP_IDENTIFIERS: '' }), null);
  assert.equal(off({ REVIEWER_OTP_IDENTIFIERS: 'a@x.com,b@x.com,c@x.com,d@x.com,e@x.com' }), null);
});

test('bypass stops working after the expiry date', () => {
  const after = Date.parse('2026-12-21T00:00:01Z');
  assert.equal(reviewerOtpCode('reviewer@example.com', base, after), null);
  assert.equal(isReviewerOtpIdentifier('reviewer@example.com', base, after), false);
});
