'use strict';

// Matching for the merchant category review flow deliberately stays small and
// conservative. The database route uses these same functions for preview and
// apply so a preview cannot silently expand into a different merchant set.
const MATCH_POLICY_VERSION = 'v1';

const GENERIC_MERCHANT_NAMES = new Set([
  'unknown',
  'unknown merchant',
  'other',
  'upi',
  'upi payment',
  'upi transaction',
  'payment',
  'merchant',
  'cash withdrawal',
  'card payment',
]);

function normalizeMerchantVpa(value) {
  if (value === null || value === undefined) return null;
  const normalized = String(value).trim().toLowerCase();
  return normalized || null;
}

function normalizeMerchantName(value) {
  if (value === null || value === undefined) return null;
  const normalized = String(value).trim().toLowerCase().replace(/\s+/g, ' ');
  return normalized || null;
}

function isGenericMerchantName(value) {
  const normalized = normalizeMerchantName(value);
  if (!normalized || GENERIC_MERCHANT_NAMES.has(normalized)) return true;
  // Parser placeholders and bare phone-like recipients are not merchant
  // identities. Avoid grouping every unknown UPI payment together.
  if (/^\+?\d[\d\s-]{7,}$/.test(normalized)) return true;
  if (/^(?:(?:upi\s+)?(?:payment|transaction)|txn)[\s:_-]*\d*$/i.test(normalized)) return true;
  return false;
}

function merchantMatch(source, candidate) {
  const sourceVpa = normalizeMerchantVpa(source?.merchant_vpa ?? source?.merchantVpa);
  const candidateVpa = normalizeMerchantVpa(candidate?.merchant_vpa ?? candidate?.merchantVpa);
  if (sourceVpa) {
    return candidateVpa === sourceVpa
      ? { matched: true, basis: 'vpa', value: sourceVpa }
      : { matched: false, basis: 'vpa', value: sourceVpa };
  }
  const sourceName = normalizeMerchantName(source?.merchant_name ?? source?.merchantName);
  const candidateName = normalizeMerchantName(candidate?.merchant_name ?? candidate?.merchantName);
  if (isGenericMerchantName(sourceName)) {
    return { matched: false, basis: 'strict_name', value: sourceName, reason: 'generic_merchant_name' };
  }
  return sourceName && candidateName === sourceName
    ? { matched: true, basis: 'strict_name', value: sourceName }
    : { matched: false, basis: 'strict_name', value: sourceName };
}

function classifyCandidate(row, sourceId, target) {
  if (String(row.id) === String(sourceId)) {
    return { tier: 'ineligible', selected: false, reason: 'source_transaction' };
  }
  if (row.status !== 'active') return { tier: 'ineligible', selected: false, reason: 'not_active' };
  if ((row.entry_kind || 'spend') !== 'spend') {
    return { tier: 'ineligible', selected: false, reason: 'not_spend' };
  }
  if (row.is_split_parent || row.parent_txn_id || row.has_splits) {
    return { tier: 'ineligible', selected: false, reason: 'split_transaction' };
  }
  if (row.category_id === target.categoryId && !row.user_category_id
      && !target.userCategoryId) {
    return { tier: 'ineligible', selected: false, reason: 'already_target' };
  }
  if (row.user_category_id === target.userCategoryId && target.userCategoryId) {
    return { tier: 'ineligible', selected: false, reason: 'already_target' };
  }
  const generic = !row.user_category_id && (!row.category_id || row.category_slug === 'other');
  return generic
    ? { tier: 'default_selected', selected: true, reason: 'generic_category' }
    : { tier: 'manual_review', selected: false, reason: 'existing_meaningful_category' };
}

/**
 * Idempotency rows are written in the same transaction as category updates.
 * A null result can therefore only be a legacy/pre-deploy pending marker; it
 * is safe to replace after the request hash matches. The route serializes the
 * key with a transaction advisory lock before using this decision.
 */
function resolveBulkIdempotencyRow(row, requestHash) {
  if (!row) return { action: 'create' };
  if (row.request_hash !== requestHash) return { action: 'conflict', reason: 'key_reused' };
  if (row.result) return { action: 'replay', result: row.result };
  return { action: 'replace_pending', operationId: row.operation_id };
}

module.exports = {
  MATCH_POLICY_VERSION,
  GENERIC_MERCHANT_NAMES,
  normalizeMerchantVpa,
  normalizeMerchantName,
  isGenericMerchantName,
  merchantMatch,
  classifyCandidate,
  resolveBulkIdempotencyRow,
};
