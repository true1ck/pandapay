'use strict';

const { createHmac } = require('node:crypto');

/** Normalize the app's India-friendly input to a stable E.164 representation. */
function canonicalizePhone(phoneNumber) {
  if (typeof phoneNumber !== 'string') throw new TypeError('Phone number must be a string');
  let phone = phoneNumber.trim().replace(/[\s().-]/g, '');
  if (/^\d{10}$/.test(phone)) phone = `+91${phone}`;
  if (!/^\+[1-9]\d{1,14}$/.test(phone)) throw new TypeError('Phone number must be a valid E.164 value');
  return phone;
}

function getLookupKey() {
  const key = process.env.PHONE_LOOKUP_HMAC_KEY;
  if (!key || Buffer.byteLength(key) < 32) {
    throw new Error('PHONE_LOOKUP_HMAC_KEY must be configured with at least 32 bytes');
  }
  return key;
}

/** A stable, keyed digest for phone equality/index lookups. */
function phoneLookupHash(phoneNumber) {
  return createHmac('sha256', getLookupKey())
    .update(`pandapay-phone-lookup:v1:${canonicalizePhone(phoneNumber)}`)
    .digest('hex');
}

function buildPhoneLookupWhereClause(paramIndex = '$1') {
  return `(phone_lookup_hash = ${paramIndex})`;
}

function preparePhoneSearchParams(phoneNumber) {
  return [phoneLookupHash(phoneNumber)];
}

function buildPhoneLookupQuery(baseQuery, phoneParamIndex = '$1') {
  const whereClause = buildPhoneLookupWhereClause(phoneParamIndex);
  const query = /\bWHERE\b/i.test(baseQuery)
    ? `${baseQuery} AND ${whereClause}`
    : `${baseQuery} WHERE ${whereClause}`;
  return { query };
}

module.exports = {
  canonicalizePhone,
  phoneLookupHash,
  buildPhoneLookupWhereClause,
  preparePhoneSearchParams,
  buildPhoneLookupQuery,
  // Compatibility aliases now use the keyed hash column, never ciphertext.
  buildEncryptedPhoneWhereClause: buildPhoneLookupWhereClause,
  buildEncryptedPhoneQuery: buildPhoneLookupQuery,
};
