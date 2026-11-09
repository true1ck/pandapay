const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const preflight = fs.readFileSync(path.join(__dirname, '../scripts/preflight_email_canonical.sql'), 'utf8');
const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0016_email_canonical.sql'), 'utf8');

const body = text => {
  const from = text.indexOf('LANGUAGE plpgsql IMMUTABLE AS $$');
  return text.slice(from, text.indexOf('END $$;', from) + 'END $$;'.length);
};

test('the preflight uses exactly the canonical-email function that migration 0016 installs', () => {
  assert.ok(body(migration).length > 400, 'found the function in the migration');
  assert.equal(body(preflight), body(migration));
});

test('the preflight changes nothing: one transaction, always rolled back, no data statements', () => {
  const code = preflight.replace(/--.*$/gm, '');
  assert.match(code, /^\s*BEGIN;/);
  assert.match(code, /ROLLBACK;\s*$/);
  assert.doesNotMatch(code, /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|GRANT)\b/i);
  assert.match(code, /CREATE OR REPLACE FUNCTION pg_temp\.auth_canonical_email/, 'the function is temporary');
});

test('the preflight prints domains and account ids, never an address', () => {
  const select = preflight.slice(preflight.indexOf('SELECT split_part'));
  assert.doesNotMatch(select.replace(/--.*$/gm, ''), /\bemail\b[^)]*\bAS\b|canon\s+AS\s+email/i);
  assert.match(select, /split_part\(canon, '@', 2\) AS mailbox_domain/);
  assert.match(select, /array_agg\(id/);
});
