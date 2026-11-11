'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { transactionalSql, migrationInventory } = require('../scripts/product_migrate');

const filename = '20261121010000_shared_expense_avatar_visibility.sql';
const root = path.resolve(__dirname, '..');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations', filename), 'utf8');

test('avatar visibility migration is transactional, additive and ordered last', () => {
  assert.doesNotThrow(() => transactionalSql(sql));
  const names = migrationInventory(root).map(([n]) => n);
  assert.equal(names.filter((n) => n === filename).length, 1);
  assert.ok(filename > '20261120030000_sms_v2_members_count.sql');
  assert.doesNotMatch(sql, /\b(?:DROP|TRUNCATE|ALTER\s+TABLE)\b/i);
});

test('shares_context_with is a locked-down boolean-only definer function', () => {
  assert.match(sql, /FUNCTION shared_expenses\.shares_context_with\(p_other uuid\) RETURNS boolean/);
  assert.match(sql, /SECURITY DEFINER\s+SET search_path=pg_catalog,shared_expenses,pg_temp/);
  assert.match(sql, /shared_expenses\._actor\(\)/);
  assert.match(sql, /OWNER TO shared_expenses_owner/);
  assert.match(sql, /REVOKE ALL ON FUNCTION shared_expenses\.shares_context_with\(uuid\) FROM PUBLIC,app_user/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION shared_expenses\.shares_context_with\(uuid\) TO app_user/);
  assert.match(sql, /reads_enabled/);
  for (const needle of ["me.state='active'", "them.state='active'", "c.state='active'"]) assert.ok(sql.includes(needle), needle);
});

test('member_profile_name is gated by shares_context_with and locked down', () => {
  assert.match(sql, /FUNCTION shared_expenses\.member_profile_name\(p_other uuid\) RETURNS text/);
  assert.match(sql, /NOT shared_expenses\.shares_context_with\(p_other\) THEN RETURN NULL/);
  assert.match(sql, /OWNER TO shared_expenses_owner/);
  assert.match(sql, /REVOKE ALL ON FUNCTION shared_expenses\.member_profile_name\(uuid\) FROM PUBLIC,app_user/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION shared_expenses\.member_profile_name\(uuid\) TO app_user/);
});
