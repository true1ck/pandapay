const test = require('node:test');
const assert = require('node:assert/strict');
const { safeErrorCode } = require('../src/utils/safeErrorCode');

test('safeErrorCode preserves bounded operational codes and hides arbitrary provider text', () => {
  assert.equal(safeErrorCode({ code: '23505', name: 'DatabaseError' }), '23505');
  assert.equal(safeErrorCode({ code: 'ECONNRESET', name: 'Error' }), 'ECONNRESET');
  assert.equal(safeErrorCode({ code: 'phone+919876543210 token=secret', name: 'Error' }), 'Error');
  assert.equal(safeErrorCode({ name: 'CustomErrorWithPrivateData' }), 'Error');
  assert.equal(safeErrorCode({ name: 'TypeError' }), 'TypeError');
  assert.equal(safeErrorCode({}, 'delivery_error'), 'delivery_error');
});
