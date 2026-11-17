'use strict';
// The production compose file must give the API the Firebase project number and the production app ids, and they
// must match what the apps ship with. Without them no phone is ever counted as attested: layouts stay "held" and
// the app says "AI is not receiving your message formats yet". Synthetic tokens only.
// Run: node --test api/test/sms_v2/app_check_config.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const jwt = require('jsonwebtoken');
const { createAppCheckVerifier, createSecurity } = require('../../src/sms_v2/security');

const repo = path.join(__dirname, '..', '..', '..');
const read = (...parts) => fs.readFileSync(path.join(repo, ...parts), 'utf8').replace(/\r\n/g, '\n');

// The api service block of the production compose file, and the default of one variable in it.
const compose = read('docker-compose.prod.yml');
const apiBlock = compose.slice(compose.indexOf('\n  api:\n'), compose.indexOf('\n  rewards-worker:\n'));
const composeDefault = (name) => {
  const match = new RegExp(`^\\s+${name}: "\\$\\{${name}:-([^}]*)\\}"`, 'm').exec(apiBlock);
  return match ? match[1] : null;
};

const googleServices = JSON.parse(read('app', 'android', 'app', 'google-services.json'));
const androidIdOf = (packageName) =>
  googleServices.client.find((c) => c.client_info.android_client_info.package_name === packageName).client_info.mobilesdk_app_id;
const plist = read('app', 'ios', 'Runner', 'GoogleService-Info.plist');
const iosAppId = /<key>GOOGLE_APP_ID<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)[1];

const PROJECT = composeDefault('SMS_V2_FIREBASE_PROJECT_NUMBER');
const APP_IDS = (composeDefault('SMS_V2_FIREBASE_APP_IDS') || '').split(',').filter(Boolean);

test('the api service gets the Firebase project number and app ids that the apps ship with', () => {
  assert.equal(PROJECT, googleServices.project_info.project_number);
  assert.ok(APP_IDS.includes(androidIdOf('app.pandapay.pandapay')), 'production Android app id');
  assert.ok(APP_IDS.includes(iosAppId), 'production iOS app id');
});

test('Staging and dev builds are not listed, so they stay uncounted', () => {
  assert.ok(!APP_IDS.includes(androidIdOf('app.pandapay.pandapay.staging')));
  assert.ok(!APP_IDS.includes(androidIdOf('app.pandapay.pandapay.dev2')));
  assert.equal(APP_IDS.length, 2);
});

test('attestation stays in monitor mode, so a phone without a valid token keeps working', () => {
  assert.equal(/^\s+SMS_V2_ATTESTATION_MODE:/m.test(apiBlock), false, 'no override: the default is monitor');
});

const key = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...key.publicKey.export({ format: 'jwk' }), kid: 'k1', use: 'sig', alg: 'RS256' };
const now = Date.parse('2026-11-20T10:00:00Z');
const token = (sub, project = PROJECT) => jwt.sign(
  { sub, iss: `https://firebaseappcheck.googleapis.com/${project}`, aud: [`projects/${project}`], iat: now / 1000 - 60, exp: now / 1000 + 300 },
  key.privateKey, { algorithm: 'RS256', keyid: 'k1', header: { typ: 'JWT' } },
);
const verifier = (fetchJwks = async () => ({ keys: [jwk] })) => createAppCheckVerifier({
  projectNumber: PROJECT, appIds: APP_IDS, now: () => now, fetchJwks, rejectDebug: true,
});

test('with the compose values a production Android or iOS token verifies; others do not', async () => {
  const verify = verifier();
  assert.equal((await verify(token(androidIdOf('app.pandapay.pandapay')))).appId, androidIdOf('app.pandapay.pandapay'));
  assert.equal((await verify(token(iosAppId))).appId, iosAppId);
  assert.equal(await verify(token(androidIdOf('app.pandapay.pandapay.staging'))), null, 'staging app');
  assert.equal(await verify(token(iosAppId, '999999999')), null, 'another Firebase project');
  assert.equal(await verify('not-a-token'), null);
});

test('when Google cannot be reached the check fails closed without throwing', async () => {
  const verify = verifier(async () => { throw new Error('network down'); });
  assert.equal(await verify(token(iosAppId)), null);
});

const request = (attestation) => ({
  userId: '00000000-0000-4000-8000-0000000000a1',
  headers: { 'x-sms-device-id': 'device_synthetic_01', ...(attestation ? { 'x-device-attestation': attestation } : {}) },
});
const consume = async () => ({ allowed: true, retryAfterSeconds: 0 });
const security = () => createSecurity({
  env: { SMS_V2_ATTESTATION_BINDING: 'off' }, verifyToken: verifier(), consume, now: () => now, log: () => {},
});

test('counted only with a valid token; a phone without one is still admitted (monitor) but not counted', async () => {
  const withToken = request(token(iosAppId));
  assert.equal(await security().verifyAttestation(withToken), true);
  assert.equal(withToken.smsV2Security.verified, true);
  assert.equal(withToken.smsV2Security.sharedLearningEligible, true);

  const without = request(null);
  assert.equal(await security().verifyAttestation(without), true);
  assert.equal(without.smsV2Security.verified, false);
  assert.equal(without.smsV2Security.sharedLearningEligible, false);

  const staging = request(token(androidIdOf('app.pandapay.pandapay.staging')));
  assert.equal(await security().verifyAttestation(staging), true);
  assert.equal(staging.smsV2Security.sharedLearningEligible, false);
});
