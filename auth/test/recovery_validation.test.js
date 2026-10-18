const test = require('node:test');
const assert = require('node:assert/strict');

const {
  validateVerifyEmailOtpBody,
  validateVerifyOtpBody,
} = require('../src/middleware/validation');

function responseRecorder() {
  return {
    statusCode: null,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

test('email OTP verification accepts a boolean recovery_only flag', () => {
  const req = {
    body: {
      email: 'person@example.com',
      code: '1234',
      device_id: 'device-1',
      recovery_only: true,
    },
  };
  const res = responseRecorder();
  let nextCalled = false;

  validateVerifyEmailOtpBody(req, res, () => { nextCalled = true; });

  assert.equal(nextCalled, true);
  assert.equal(res.statusCode, null);
});

test('email OTP verification rejects a non-boolean recovery_only flag', () => {
  const req = {
    body: {
      email: 'person@example.com',
      code: '1234',
      recovery_only: 'true',
    },
  };
  const res = responseRecorder();
  let nextCalled = false;

  validateVerifyEmailOtpBody(req, res, () => { nextCalled = true; });

  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'recovery_only must be a boolean' });
});

test('phone OTP verification rejects a non-boolean recovery_only flag', () => {
  const req = {
    body: {
      phone_number: '+919876543210',
      code: '1234',
      recovery_only: 'true',
    },
  };
  const res = responseRecorder();
  let nextCalled = false;

  validateVerifyOtpBody(req, res, () => { nextCalled = true; });

  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'recovery_only must be a boolean' });
});
