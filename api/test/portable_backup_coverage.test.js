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

function migrationTableNames() {
  const names = new Set();
  const files = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql'));
  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    const pattern = /create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z_][a-z0-9_]*)/gi;
    let match;
    while ((match = pattern.exec(sql)) !== null) {
      const table = match[1];
      if (table !== 'public') names.add(table);
    }
  }
  return [...names].sort();
}

test('every migration table is classified in portable backup coverage', () => {
  const tables = migrationTableNames();
  assert.ok(tables.length > 50, `expected a real migration inventory, found ${tables.length}`);
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

test('every non-exported table carries an explicit disposition', () => {
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
});
