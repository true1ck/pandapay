'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { transactionalSql, migrationInventory } = require('../scripts/product_migrate');

const filename = '20261112210000_shared_expenses_foundation.sql';
const directory = path.resolve(__dirname, '../supabase/migrations');
const migration = () => fs.readFileSync(path.join(directory, filename), 'utf8');

test('shared foundation is an additive uniquely ordered transactional migration', () => {
  const sql = migration();
  assert.doesNotThrow(() => transactionalSql(sql));
  assert.equal(migrationInventory(path.resolve(__dirname, '..')).filter(([name]) => name === filename).length, 1);
  assert.ok(filename > '20261112200000_sms_v2_correction_update_guard.sql');
  assert.doesNotMatch(sql, /\b(?:DROP\s+(?:TABLE|SCHEMA)|TRUNCATE|CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY)\b/i);
  assert.doesNotMatch(sql, /\bALTER\s+TABLE\s+(?:public\.)?(?:transactions|transaction_splits|sms_v2_\w+|foreign_payments)\b/i);
});

test('isolated storage is fail-closed and public role setup cannot expose financial CRUD', () => {
  const sql = migration();
  assert.match(sql, /CREATE SCHEMA shared_expenses AUTHORIZATION shared_expenses_owner/i);
  assert.match(sql, /NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS/i);
  assert.match(sql, /FORCE ROW LEVEL SECURITY/i);
  assert.match(sql, /REVOKE ALL ON ALL TABLES IN SCHEMA shared_expenses FROM PUBLIC, app_user/i);
  assert.match(sql, /REVOKE ALL ON ALL FUNCTIONS IN SCHEMA shared_expenses FROM PUBLIC, app_user/i);
  assert.doesNotMatch(sql, /GRANT\s+(?:ALL|INSERT|UPDATE|DELETE)[^;]+TO\s+app_user/i);
  assert.doesNotMatch(sql, /GRANT\s+shared_expenses_owner\s+TO\s+app_user/i);
  assert.match(sql, /reads_enabled boolean NOT NULL DEFAULT false/i);
  assert.match(sql, /accepted_writes_enabled boolean NOT NULL DEFAULT false/i);
});

test('financial provenance cannot be cascaded away and source aliases share canonical reservations', () => {
  const sql = migration();
  for (const table of ['contexts', 'members', 'expenses', 'expense_revisions', 'revision_members', 'revision_approvals', 'source_resources', 'source_aliases', 'source_reservations', 'journal_entries', 'obligation_edges', 'settlement_reports', 'settlement_events', 'settlement_allocations', 'operation_receipts', 'context_events', 'profile_stream_heads', 'profile_events', 'member_balances', 'pair_balances', 'private_cost_facts']) {
    assert.match(sql, new RegExp('CREATE TABLE shared_expenses\\.' + table + '\\b', 'i'), table);
  }
  assert.match(sql, /UNIQUE\s*\(owner_profile_id,\s*canonical_transaction_id\)/i);
  assert.match(sql, /PRIMARY KEY\s*\(actor_profile_id,\s*operation_id\)/i);
  assert.match(sql, /high_member_id\s*>\s*low_member_id/i);
  assert.match(sql, /immutable financial record/i);
  assert.doesNotMatch(sql, /REFERENCES\s+public\.(?:transactions|profiles)[^;]*ON DELETE CASCADE/i);
});

test('source admission re-resolves all typed source families and is protected by existing ingest lock', () => {
  const sql = migration();
  assert.match(sql, /FUNCTION shared_expenses\.admit_source\(p_ref jsonb\)/i);
  for (const kind of ['legacy_transaction', 'sms_v2_event', 'confirmed_foreign_payment']) assert.ok(sql.includes(kind));
  assert.match(sql, /transaction-ingest:/);
  assert.match(sql, /public\.sms_v2_events/);
  assert.match(sql, /public\.sms_v2_ledger_entries/);
  assert.match(sql, /public\.foreign_payments/);
  assert.match(sql, /source_version_mismatch/);
  assert.match(sql, /SET search_path = pg_catalog, shared_expenses, pg_temp/i);
});

test('runtime commands derive frozen balanced revisions and isolate unsupported funding', () => {
  const sql=migration();
  for(const fn of ['invite_member','submit_proposal','respond_expense','report_settlement','respond_settlement']) {
    assert.ok(sql.includes(`FUNCTION shared_expenses.${fn}(p_payload jsonb,p_operation_id uuid,p_request_hash text)`),fn);
  }
  assert.match(sql,/projection_version text NOT NULL DEFAULT 'pair_v1'/);
  assert.match(sql,/jsonb_array_elements\(old_edges\)/);
  assert.match(sql,/sum\(abs\(balance_minor::numeric\)\)/);
  assert.match(sql,/awaiting_source_authorization/);
  assert.match(sql,/'sourceFunding',false/);
  assert.doesNotMatch(sql,/GRANT EXECUTE ON FUNCTION[^;]*\._(?:post_pair|accept_revision|operation|finish|emit|inspect_source)\(/);
  assert.ok(sql.includes("'pair_balance','pair_credit'"));
});

test('a later migration turns the shared expense runtime flags on for deployed databases', () => {
  const sql = fs.readFileSync(path.join(directory, '20261118010000_shared_expenses_enable_runtime_flags.sql'), 'utf8');
  assert.match(sql, /UPDATE shared_expenses\.settings/);
  for (const flag of ['reads_enabled', 'proposals_enabled', 'accepted_writes_enabled', 'settlements_enabled']) {
    assert.match(sql, new RegExp(flag + " *= *true"));
  }
  assert.doesNotMatch(sql, /source_guards_enabled/);
});
