'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  validateSyncRegistration,
  validateSyncPushRequest,
  validateSyncPushChange,
  validateSyncPullQuery,
  validateSyncAck,
  validateSyncConflictId,
  syncRejectionDetail,
} = require('../src/sync_request_validation');

const DEVICE_ID = '11110000-0000-0000-0000-00000000aaaa';
const ENTITY_ID = '22220000-0000-0000-0000-00000000bbbb';

test('registration preserves omitted values and normalizes optional client fields', () => {
  assert.deepEqual(validateSyncRegistration(), {
    value: { platform: 'web', label: null, appVersion: null, deviceId: null },
  });
  assert.deepEqual(validateSyncRegistration(null), {
    value: { platform: 'web', label: null, appVersion: null, deviceId: null },
  });
  assert.deepEqual(validateSyncRegistration({
    platform: 'android',
    label: 'Pixel',
    appVersion: '1.2.3',
    deviceId: DEVICE_ID,
  }), {
    value: { platform: 'android', label: 'Pixel', appVersion: '1.2.3', deviceId: DEVICE_ID },
  });
  // The SQL function deliberately maps an unrecognized platform to web.
  assert.equal(validateSyncRegistration({ platform: 'future-platform' }).value.platform, 'future-platform');
  assert.deepEqual(validateSyncRegistration({ platform: [], label: {}, appVersion: 4, deviceId: '' }).value, {
    platform: 'web', label: null, appVersion: null, deviceId: null,
  });
});

test('registration rejects non-object shapes and malformed non-empty UUIDs', () => {
  for (const body of [[], 'body', 4, false]) {
    assert.equal(validateSyncRegistration(body).status, 400);
  }
  for (const deviceId of ['x', '11110000-0000-0000-0000-00000000aaa', '11110000-0000-0000-0000-00000000aaag']) {
    assert.equal(validateSyncRegistration({ deviceId }).status, 400);
  }
});

test('push request validates envelope while retaining array ordering and partial-item handling', () => {
  const changes = [
    { entity: 'transactions', entityId: ENTITY_ID, op: 'update' },
    null,
    { entity: 'transactions', entityId: 'bad-id', op: 'update' },
  ];
  assert.deepEqual(validateSyncPushRequest({ deviceId: DEVICE_ID, changes }), {
    value: { deviceId: DEVICE_ID, changes },
  });
  for (const body of [null, [], 'body', 3]) assert.equal(validateSyncPushRequest(body).status, 400);
  assert.equal(validateSyncPushRequest({ deviceId: 'bad', changes: [] }).status, 400);
  assert.equal(validateSyncPushRequest({ deviceId: DEVICE_ID, changes: {} }).status, 400);
  assert.equal(validateSyncPushRequest({ deviceId: DEVICE_ID, changes: Array(201) }).status, 413);
});

test('push item accepts Dart JSON shapes and leaves unknown entity policy to SQL', () => {
  const valid = {
    entity: 'future_entity',
    entityId: ENTITY_ID,
    op: 'update',
    payload: { name: 'custom category' },
    fieldClocks: { name: 1792920000000 },
    clientSeq: 23,
  };
  assert.deepEqual(validateSyncPushChange(valid), { value: valid });
  assert.deepEqual(validateSyncPushChange({
    entity: 'transactions', entityId: ENTITY_ID, op: 'delete', payload: null, fieldClocks: null,
  }), {
    value: {
      entity: 'transactions', entityId: ENTITY_ID, op: 'delete',
      payload: {}, fieldClocks: {}, clientSeq: null,
    },
  });
});

test('push item rejects malformed shapes, UUIDs, payload maps, and unsafe or fractional integer fields', () => {
  for (const change of [null, [], 'change', 2]) assert.equal(validateSyncPushChange(change).error, 'malformed');
  const base = { entity: 'transactions', entityId: ENTITY_ID, op: 'update' };
  for (const patch of [
    { entityId: 'not-a-uuid' },
    { op: 'merge' },
    { entity: [] },
    { payload: [] },
    { payload: 'scalar' },
    { fieldClocks: [] },
    { fieldClocks: { note: 1.5 } },
    { fieldClocks: { note: Number.MAX_SAFE_INTEGER + 1 } },
    { clientSeq: 1.5 },
    { clientSeq: Number.MAX_SAFE_INTEGER + 1 },
    { clientSeq: -1 },
  ]) {
    assert.equal(validateSyncPushChange({ ...base, ...patch }).error, 'malformed');
  }
});

test('pull uses current defaults and clamps the SQL limit range', () => {
  assert.deepEqual(validateSyncPullQuery({ deviceId: DEVICE_ID }), {
    value: { deviceId: DEVICE_ID, since: 0, limit: 500 },
  });
  assert.deepEqual(validateSyncPullQuery({ deviceId: DEVICE_ID, since: '', limit: '' }).value, {
    deviceId: DEVICE_ID, since: 0, limit: 500,
  });
  assert.deepEqual(validateSyncPullQuery({ deviceId: DEVICE_ID, since: '-5', limit: '200' }).value, {
    deviceId: DEVICE_ID, since: -5, limit: 200,
  });
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, limit: '0' }).value.limit, 500);
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, limit: '-3' }).value.limit, 1);
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, limit: '9000' }).value.limit, 1000);
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, limit: '2147483648' }).value.limit, 1000);
});

test('pull rejects malformed UUIDs, fractional, exponential, non-scalar, and unsafe query integers', () => {
  for (const deviceId of [undefined, '', 'nope', [DEVICE_ID]]) {
    assert.equal(validateSyncPullQuery({ deviceId }).status, 400);
  }
  for (const value of ['1.5', '1e3', '1E3', 'Infinity', '9007199254740992', ['1']]) {
    assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, since: value }).status, 400);
  }
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, limit: '1e3' }).status, 400);
  assert.equal(validateSyncPullQuery({ deviceId: DEVICE_ID, since: '9007199254740992' }).status, 400);
});

test('ack accepts only non-negative safe integer server sequences', () => {
  assert.deepEqual(validateSyncAck({ deviceId: DEVICE_ID, serverSeq: 0 }), {
    value: { deviceId: DEVICE_ID, serverSeq: 0 },
  });
  assert.deepEqual(validateSyncAck({ deviceId: DEVICE_ID, serverSeq: 17 }).value.serverSeq, 17);
  for (const body of [null, [], 'body', { deviceId: 'bad', serverSeq: 1 }]) {
    assert.equal(validateSyncAck(body).status, 400);
  }
  for (const serverSeq of [undefined, null, '17', 1.2, -1, Number.MAX_SAFE_INTEGER + 1, Infinity]) {
    assert.equal(validateSyncAck({ deviceId: DEVICE_ID, serverSeq }).status, 400);
  }
});

test('conflict acknowledgement path validates UUID shape without deciding row existence', () => {
  assert.deepEqual(validateSyncConflictId(ENTITY_ID), { value: ENTITY_ID });
  assert.equal(validateSyncConflictId('invalid').status, 400);
  assert.equal(validateSyncConflictId(['invalid']).status, 400);
});

test('sync rejection details map SQLSTATEs to fixed safe strings', () => {
  const cases = [
    ['22P02', 'A value has an invalid format.'],
    ['22003', 'A number is outside the supported range.'],
    ['23503', 'A referenced record is missing.'],
    ['23505', 'This change duplicates an existing record.'],
    ['23514', 'This change violates a data rule.'],
    ['42501', 'This change is not permitted.'],
  ];
  for (const [code, expected] of cases) {
    assert.equal(syncRejectionDetail({
      code,
      message: 'secret account 1234567890 / SQL text / stack trace',
      detail: 'private row values',
      cause: new Error('credential=secret'),
    }), expected);
  }
});

test('sync rejection details expose the split invariant only through its explicit safe code', () => {
  const exact = 'amount is less than saved split shares; edit or clear the split first';
  assert.equal(syncRejectionDetail({
    code: 'SYNC_SPLIT_TOTAL_CONFLICT',
    message: 'secret payload=account number 1234567890',
  }), exact);
  assert.notEqual(syncRejectionDetail({
    code: '23514',
    message: exact,
  }), exact);
});

test('sync rejection details use a fixed fallback and never echo arbitrary error text', () => {
  for (const err of [
    undefined,
    null,
    { code: 'UNKNOWN', message: 'secret@example.com raw database value' },
    { code: '22P02; DROP TABLE users', message: 'private payload' },
    { code: 'toString', message: 'prototype lookup must not become a detail' },
    { code: '23503', message: 'email=user@example.com', detail: 'token=abc123' },
  ]) {
    const detail = syncRejectionDetail(err);
    assert.equal(typeof detail, 'string');
    assert.equal(detail.includes('secret'), false);
    assert.equal(detail.includes('user@example.com'), false);
    assert.equal(detail.includes('abc123'), false);
  }
  assert.equal(syncRejectionDetail({ code: 'UNKNOWN', message: 'private raw message' }), 'The change could not be applied.');
});
