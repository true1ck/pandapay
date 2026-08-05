// src/utils/encryptedPhoneSearch.js
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
// Helper for searching encrypted phone numbers in database
// Handles backward compatibility with plaintext phone numbers

const { encryptPhoneNumber } = require('./fieldEncryption');

/**
 * Build SQL WHERE clause for encrypted phone number search
 * Handles both encrypted and plaintext (backward compatibility)
 * 
 * @param {string} paramIndex - SQL parameter index (e.g., '$1', '$2')
 * @returns {string} - SQL WHERE clause
 */
function buildEncryptedPhoneWhereClause(paramIndex) {
  // Search for both encrypted and plaintext (backward compatibility)
  // The encrypted phone will be passed as first param, plaintext as second
  return `(phone_number = ${paramIndex} OR phone_number = $${parseInt(paramIndex.replace('$', '')) + 1})`;
}

/**
 * Prepare phone number search parameters
 * Returns both encrypted and plaintext for backward compatibility
 * 
 * @param {string} phoneNumber - Plaintext phone number
 * @returns {string[]} - Array with [encryptedPhone, plaintextPhone]
 */
function preparePhoneSearchParams(phoneNumber) {
  const encryptedPhone = encryptPhoneNumber(phoneNumber);
  return [encryptedPhone, phoneNumber];
}

/**
 * Build SQL query with encrypted phone search
 * 
 * @param {string} baseQuery - Base SQL query (without WHERE clause)
 * @param {string} phoneParamIndex - Starting parameter index (e.g., '$1')
 * @returns {Object} - { query: string, params: string[] }
 */
function buildEncryptedPhoneQuery(baseQuery, phoneParamIndex = '$1') {
  const whereClause = buildEncryptedPhoneWhereClause(phoneParamIndex);
  const query = baseQuery.includes('WHERE') 
    ? `${baseQuery} AND ${whereClause}`
    : `${baseQuery} WHERE ${whereClause}`;
  
  return { query };
}

module.exports = {
  buildEncryptedPhoneWhereClause,
  preparePhoneSearchParams,
  buildEncryptedPhoneQuery,
};

