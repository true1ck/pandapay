'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'test';
process.env.API_DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'test-access-secret';
process.env.REFERRAL_IDENTITY_HMAC_KEY = 'test-referral-identity-hmac-key-over-32-bytes';
process.env.REFERRAL_IDENTITY_HMAC_KEY_VERSION = 'test-v3';
process.env.REFERRAL_PREVIEW_SECRET = 'test-referral-preview-secret-over-32-bytes';
process.env.ENGAGEMENT_RECEIPT_SECRET = 'test-engagement-receipt-secret-over-32-bytes';

const {
  buildEligibilityClaims,
  createInvitationPreviewToken,
  verifyInvitationPreviewToken,
  createEngagementReceipt,
  verifyPayload,
  publicValidationFingerprint,
  parseLedgerCursor,
  encodeLedgerCursor,
  hasWorkerSecret,
  normalizeWorkerEvent,
  workerEventCopy,
} = require('../src/referral_routes');

test('eligibility fingerprints only verified, normalized contacts and never returns raw values', () => {
  const claims = buildEligibilityClaims({
    email: { verified: true, value: ' Person@Example.COM ' },
    phone: { verified: true, value: '(987) 654-3210' },
  });
  assert.deepEqual(claims.map(({ kind }) => kind), ['email', 'phone']);
  assert.equal(claims[0].fingerprint.length, 64);
  assert.equal(claims[0].keyVersion, 'test-v3');
  assert.equal(JSON.stringify(claims).includes('Person@Example.COM'), false);
  assert.equal(JSON.stringify(claims).includes('987'), false);
  assert.deepEqual(buildEligibilityClaims({
    email: { verified: false, value: 'person@example.com' },
  }), []);
});

test('preview token binds the normalized code and expires', () => {
  const now = 1_800_000_000_000;
  const preview = {
    campaignVersion: 'pilot-v1',
    termsVersion: 'referral-v2',
    accessRevision: 8,
    rewardAvailable: true,
  };
  const token = createInvitationPreviewToken(preview, 'PANDA-ABC123', undefined, now);
  assert.equal(verifyInvitationPreviewToken(token, undefined, now + 1).code, 'PANDA-ABC123');
  assert.equal(verifyInvitationPreviewToken(token, undefined, now + 10 * 60 * 1000), null);
  assert.equal(verifyInvitationPreviewToken(`${token}x`, undefined, now), null);
});

test('engagement receipt is short-lived, user-bound and server-dated in campaign zone', () => {
  const now = Date.parse('2026-10-20T19:00:00.000Z');
  const token = createEngagementReceipt('user-123', 'Asia/Kolkata', undefined, now, 300);
  const receipt = verifyPayload(token, process.env.ENGAGEMENT_RECEIPT_SECRET,
    'pandapay-engagement-receipt', now + 1);
  assert.equal(receipt.subject, 'user-123');
  assert.equal(receipt.action, 'home_summary');
  assert.equal(receipt.activityDate, '2026-10-21');
  assert.equal(verifyPayload(token, process.env.ENGAGEMENT_RECEIPT_SECRET,
    'pandapay-engagement-receipt', now + 301_000), null);
});

test('ledger cursors round-trip only valid timestamp and UUID tuples', () => {
  const cursor = encodeLedgerCursor('2026-10-21T10:00:00.000Z', 'f4c8d5b4-3f7d-4f04-a5ac-b1ff96239d03');
  assert.deepEqual(parseLedgerCursor(cursor), {
    occurredAt: '2026-10-21T10:00:00.000Z',
    id: 'f4c8d5b4-3f7d-4f04-a5ac-b1ff96239d03',
  });
  assert.equal(parseLedgerCursor('not-a-cursor'), null);
});

test('public validation stores a keyed IP fingerprint rather than the address', () => {
  const ip = 'validation-test-203.0.113.9';
  const first = publicValidationFingerprint(ip);
  assert.equal(first.length, 64);
  assert.notEqual(first, publicValidationFingerprint(ip, 'different-secret-over-32-bytes-long'));
  assert.equal(first.includes('203.0.113.9'), false);
});

test('internal worker delivery requires an exact constant-time secret match', () => {
  assert.equal(hasWorkerSecret('worker-secret', 'worker-secret'), true);
  assert.equal(hasWorkerSecret('worker-secret', 'worker-secret-longer'), false);
  assert.equal(hasWorkerSecret('worker-secret', undefined), false);
});

test('worker events accept only known referral/reward types and UUID recipients', () => {
  const event = {
    eventType: 'referral.qualified',
    eventKey: 'referral:qualified:1f5ad9c2-1da3-4fb1-91fd-711971454a31:4edcbf35-b9f3-45dc-9fc4-fc3f7fd66d5e',
    beneficiaryId: '4edcbf35-b9f3-45dc-9fc4-fc3f7fd66d5e',
  };
  assert.deepEqual(normalizeWorkerEvent(event), event);
  assert.deepEqual(normalizeWorkerEvent({ ...event, eventType: 'reward.awarded' }), {
    ...event, eventType: 'reward.awarded',
  });
  assert.deepEqual(normalizeWorkerEvent({ ...event, eventType: 'reward.spin.completed' }), {
    ...event, eventType: 'reward.spin.completed',
  });
  assert.equal(normalizeWorkerEvent({ ...event, eventType: 'arbitrary' }), null);
  assert.equal(normalizeWorkerEvent({ ...event, beneficiaryId: 'another-user' }), null);
  assert.equal(normalizeWorkerEvent({ ...event, eventKey: 'x'.repeat(181) }), null);
});

test('worker notification copy is generic and does not expose friend identity', () => {
  const joined = workerEventCopy('referral.joined');
  const qualified = workerEventCopy('referral.qualified');
  const awarded = workerEventCopy('reward.awarded');
  const zero = workerEventCopy('reward.spin.completed');
  assert.match(joined.title, /friend joined/i);
  assert.match(qualified.body, /milestone is complete/);
  assert.match(awarded.body, /credits have been added/);
  assert.match(zero.body, /result is saved/);
  assert.equal(JSON.stringify([joined, qualified, awarded, zero]).includes('email'), false);
});
