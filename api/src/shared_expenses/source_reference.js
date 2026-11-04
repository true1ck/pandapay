'use strict';

const { record, matches, fail } = require('./validation');
const ERROR = 'INVALID_SOURCE_REFERENCE';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function token(value, field, pattern, max) {
  if (typeof value !== 'string' || value.length > max || !matches(pattern, value)) fail(ERROR, field);
}

// Shape and identity validation only. The server must independently resolve
// active source truth, authenticated ownership, funding and current version.
function parseSharedExpenseSourceReference(input) {
  record(input, ['kind', 'ownerAccountId'], '$', ERROR,
    ['canonicalTransactionId', 'sourceVersion', 'sourceKey', 'eventId', 'localProjectionId', 'foreignPaymentId']);
  let required, optional;
  switch (input.kind) {
    case 'legacy_transaction':
      required = ['kind', 'ownerAccountId', 'canonicalTransactionId', 'sourceVersion'];
      optional = ['sourceKey'];
      break;
    case 'sms_v2_event':
      required = ['kind', 'ownerAccountId', 'eventId'];
      optional = ['localProjectionId', 'canonicalTransactionId', 'sourceVersion', 'sourceKey'];
      break;
    case 'confirmed_foreign_payment':
      required = ['kind', 'ownerAccountId', 'foreignPaymentId', 'canonicalTransactionId', 'sourceVersion'];
      optional = ['sourceKey'];
      break;
    default: fail(ERROR, 'kind');
  }
  record(input, required, '$', ERROR, optional);
  for (const key of ['ownerAccountId', 'canonicalTransactionId', 'foreignPaymentId']) {
    if (Object.hasOwn(input, key)) token(input[key], key, UUID, 36);
  }
  for (const key of ['sourceVersion', 'sourceKey']) {
    if (Object.hasOwn(input, key)) token(input[key], key, /^[A-Za-z0-9][A-Za-z0-9:._-]*$/, 128);
  }
  if (input.kind === 'sms_v2_event') {
    token(input.eventId, 'eventId', /^[a-f0-9]{64}$/, 64);
    if (Object.hasOwn(input, 'localProjectionId') && input.localProjectionId !== `v2:${input.eventId}`) fail(ERROR, 'localProjectionId');
    if (Object.hasOwn(input, 'canonicalTransactionId') !== Object.hasOwn(input, 'sourceVersion')) fail(ERROR, 'canonicalTransactionId');
  }
  return { ...input };
}

function canonicalLegacySplitTarget(input) {
  return parseSharedExpenseSourceReference(input).canonicalTransactionId ?? null;
}

module.exports = { parseSharedExpenseSourceReference, canonicalLegacySplitTarget };
