'use strict';

const crypto = require('node:crypto');

const FORMAT_VERSION = 1;
const SCHEMA_VERSION = 1;
const MEDIA_TYPE = 'application/vnd.pandapay.portable-backup+ndjson';
const EXPORT_PATH = '/portable-backups/export-v1';

// This is deliberately a static allow-list. Table and column names must never
// be taken from request input. The list also makes additions visible in code
// review and gives the client a stable section order.
const PORTABLE_SECTIONS = Object.freeze([
  { name: 'profile', table: 'profiles', alias: 'p', filter: 'p.id = $1', orderBy: 'p.id', cursor: 'p.id' },
  { name: 'settings', table: 'user_settings', alias: 't', filter: 't.profile_id = $1', orderBy: 't.profile_id', cursor: 't.profile_id' },
  { name: 'user_categories', table: 'user_categories', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'user_cards', table: 'user_cards', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'card_overrides', table: 'card_overrides', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'transactions', table: 'transactions', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'user_merchant_category_rules', table: 'user_merchant_category_rules', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  {
    name: 'transaction_splits',
    table: 'transaction_splits',
    alias: 't',
    filter: 'EXISTS (SELECT 1 FROM public.transactions owner_txn WHERE owner_txn.id = t.transaction_id AND owner_txn.profile_id = $1)',
    orderBy: 't.id',
    cursor: 't.id',
  },
  { name: 'transaction_observations', table: 'transaction_observations', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'transaction_tags', table: 'transaction_tags', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'transaction_tag_links', table: 'transaction_tag_links', alias: 't', filter: 't.profile_id = $1', orderBy: 't.transaction_id, t.tag_id', cursor: null },
  { name: 'points_ledger', table: 'points_ledger', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'cap_states', table: 'cap_states', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'milestone_states', table: 'milestone_states', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'fee_waiver_states', table: 'fee_waiver_states', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'lounge_usage', table: 'lounge_usage', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'needs_review_items', table: 'needs_review_items', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'duplicate_candidates', table: 'duplicate_candidates', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'monthly_reports', table: 'monthly_reports', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'statement_imports', table: 'statement_imports', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'sms_import_batches', table: 'sms_import_batches', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'budgets', table: 'budgets', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'budget_periods', table: 'budget_periods', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'recurring_series', table: 'recurring_series', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'sms_sources', table: 'sms_sources', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'sms_source_facts', table: 'sms_source_facts', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
  { name: 'fact_overrides', table: 'fact_overrides', alias: 't', filter: 't.profile_id = $1', orderBy: 't.id', cursor: 't.id' },
]);

// Device identity, credentials and operational queues are intentionally not
// selected. This list is applied in SQL before rows reach Node.
const EXCLUDED_FIELDS = Object.freeze([
  'access_token', 'refresh_token', 'push_token', 'device_id', 'os_version',
  'biometric_state', 'sms_provider_cursor', 'sync_cursor', 'private_key',
]);

const DECIMAL_FIELD = /(?:^|_)(?:amount|balance|cap|cost|delta|fee|limit|points?|rate|spend|value|paise|threshold|quota|price|reward)(?:_inr)?$/i;

function decimalString(value) {
  if (typeof value === 'bigint') return value.toString();
  if (typeof value !== 'number' || !Number.isFinite(value)) return value;
  // PostgreSQL numeric values are normally decoded by pg as strings. This
  // fallback handles test doubles and integer JSON values without exponents.
  if (Number.isInteger(value)) return String(value);
  const text = String(value);
  if (!/[eE]/.test(text)) return text;
  return value.toFixed(12).replace(/0+$/, '').replace(/\.$/, '');
}

function canonicalize(value, fieldName = '') {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString();
  if (Buffer.isBuffer(value)) return value.toString('base64');
  if (typeof value === 'bigint') return value.toString();
  if (DECIMAL_FIELD.test(fieldName)) return decimalString(value);
  if (Array.isArray(value)) return value.map((item) => canonicalize(item, fieldName));
  if (typeof value === 'object') {
    return Object.keys(value).sort().reduce((out, key) => {
      if (EXCLUDED_FIELDS.includes(key)) return out;
      out[key] = canonicalize(value[key], key);
      return out;
    }, {});
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function digestBytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

module.exports = {
  EXPORT_PATH,
  EXCLUDED_FIELDS,
  FORMAT_VERSION,
  MEDIA_TYPE,
  PORTABLE_SECTIONS,
  SCHEMA_VERSION,
  canonicalJson,
  canonicalize,
  digestBytes,
};
