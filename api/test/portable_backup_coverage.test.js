'use strict';

const fs = require('fs');
const path = require('path');
const { test } = require('node:test');
const assert = require('node:assert');
const { PORTABLE_SECTIONS } = require('../src/portable_backup/contract');

const migrationsDir = path.join(__dirname, '..', '..', 'db', 'supabase', 'migrations');
const coverage = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'src', 'portable_backup', 'coverage.json'), 'utf8'),
);

function stripSqlCommentsAndStrings(sql) {
  let output = '';
  for (let i = 0; i < sql.length;) {
    if (sql.startsWith('--', i)) {
      const end = sql.indexOf('\n', i + 2);
      if (end < 0) break;
      output += '\n';
      i = end + 1;
      continue;
    }
    if (sql.startsWith('/*', i)) {
      let depth = 1;
      i += 2;
      while (i < sql.length && depth > 0) {
        if (sql.startsWith('/*', i)) {
          depth += 1;
          i += 2;
        } else if (sql.startsWith('*/', i)) {
          depth -= 1;
          i += 2;
        } else {
          i += 1;
        }
      }
      output += ' ';
      continue;
    }
    if (sql[i] === '$') {
      const delimiter = sql.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/)?.[0];
      if (delimiter) {
        const end = sql.indexOf(delimiter, i + delimiter.length);
        i = end < 0 ? sql.length : end + delimiter.length;
        output += ' ';
        continue;
      }
    }
    if (sql[i] === "'") {
      i += 1;
      while (i < sql.length) {
        if (sql[i] === "'" && sql[i + 1] === "'") {
          i += 2;
        } else if (sql[i] === "'") {
          i += 1;
          break;
        } else if (sql[i] === '\\' && i + 1 < sql.length) {
          i += 2;
        } else {
          i += 1;
        }
      }
      output += ' ';
      continue;
    }
    output += sql[i];
    i += 1;
  }
  return output;
}

function identifierValue(token) {
  if (token.startsWith('"')) return token.slice(1, -1).replaceAll('""', '"');
  return token.toLowerCase();
}

function tableCoverageKey(schema, table) {
  return schema === 'public' ? table : `${schema}.${table}`;
}

function migrationTableKeysFromSql(sql) {
  const cleanSql = stripSqlCommentsAndStrings(sql);
  const identifier = '(?:"(?:""|[^"])+"|[A-Za-z_][A-Za-z0-9_$]*)';
  const pattern = new RegExp(
    `\\bcreate\\s+(?:(unlogged|temporary|temp)\\s+)?table\\s+(?:if\\s+not\\s+exists\\s+)?(${identifier})(?:\\s*\\.\\s*(${identifier}))?`,
    'gi',
  );
  const keys = new Set();
  let match;
  while ((match = pattern.exec(cleanSql)) !== null) {
    // Migration scratch tables marked TEMP are dropped at transaction end;
    // they are not objects in the resulting persistent schema.
    if (match[1]?.toLowerCase() === 'temp' || match[1]?.toLowerCase() === 'temporary') continue;
    const first = identifierValue(match[2]);
    const schema = match[3] ? first : 'public';
    const table = identifierValue(match[3] || match[2]);
    keys.add(tableCoverageKey(schema, table));
  }
  return [...keys].sort();
}

function migrationTableKeys() {
  const names = new Set();
  const files = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql'));
  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    for (const name of migrationTableKeysFromSql(sql)) names.add(name);
  }
  return [...names].sort();
}

test('schema-aware inventory distinguishes public and promotions tables with the same name', () => {
  const keys = migrationTableKeysFromSql(`
    CREATE TABLE public.same_name (id int);
    CREATE TABLE promotions.same_name (id int);
    CREATE TABLE same_name_default_schema (id int);
    CREATE TEMP TABLE migration_scratch (id int);
    -- CREATE TABLE public.comment_fake (id int);
    /* nested comment /* CREATE TABLE promotions.block_fake (id int); */ still comment */
    INSERT INTO audit_log VALUES ('CREATE TABLE public.string_fake (id int)');
    DO $body$ BEGIN RAISE NOTICE 'CREATE TABLE promotions.body_fake'; END $body$;
  `);
  assert.deepStrictEqual(keys, [
    'promotions.same_name',
    'same_name',
    'same_name_default_schema',
  ]);
});

test('every migration table is classified using its schema-aware key', () => {
  const tables = migrationTableKeys();
  assert.ok(tables.length > 120, `expected a schema-aware migration inventory, found ${tables.length}`);
  const missing = tables.filter((table) => !coverage.tables[table]);
  assert.deepStrictEqual(
    missing,
    [],
    'migration tables missing from coverage.json: add an entry with a disposition and reason',
  );
});

test('exported coverage tables match PORTABLE_SECTIONS exactly', () => {
  const exported = Object.entries(coverage.tables)
    .filter(([, entry]) => entry.disposition === 'exported_v1')
    .map(([table, entry]) => ({ table, section: entry.section, name: table }));
  assert.deepStrictEqual(
    exported.map((entry) => entry.section).sort(),
    PORTABLE_SECTIONS.map((section) => section.name).sort(),
  );
  for (const section of PORTABLE_SECTIONS) {
    const entry = coverage.tables[section.table];
    assert.ok(entry, `section ${section.name} references unclassified table ${section.table}`);
    assert.strictEqual(entry.disposition, 'exported_v1');
  }
});

test('non-exported user-linked tables explain the portable-backup gap', () => {
  for (const [table, entry] of Object.entries(coverage.tables)) {
    assert.ok(entry.disposition, `${table} has no disposition`);
    if (entry.disposition !== 'exported_v1') {
      assert.ok(
        ['global_catalog', 'platform_ops', 'excluded_with_intent'].includes(entry.disposition),
        `${table} has unknown disposition ${entry.disposition}`,
      );
      if (entry.disposition === 'excluded_with_intent') {
        assert.ok(entry.reason, `${table} excluded without a documented reason`);
      }
    }
  }

  for (const table of [
    'promotions.memberships',
    'promotions.referral_attributions',
    'promotions.reward_entitlements',
    'promotions.credit_ledger',
  ]) {
    assert.strictEqual(coverage.tables[table]?.disposition, 'excluded_with_intent');
    assert.match(coverage.tables[table].reason, /user-linked|account-linked/i);
    assert.match(coverage.tables[table].reason, /not included|not exported/i);
  }
});
