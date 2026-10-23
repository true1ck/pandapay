'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeCheckDump, schemaFingerprint, canonicalInventory, ACL_INVENTORY_SQL } = require('../scripts/schema_fingerprint');

test('catalog ordering is independent of database collation without sorting tuple positions', () => {
  const grants = [['owner', 'app', 'SELECT', false], ['owner', 'other', 'UPDATE', true]];
  const routines = [['public', 'a_fn', '', 'f', 'owner', grants], ['public', '_fn', '', 'f', 'owner', []]];
  const members = [
    ['ext', 'e', 'function', 'public', 'a_fn', 'a_fn(integer)', 'owner'],
    ['ext', 'e', 'language', null, 'plpgsql', 'language plpgsql', 'owner'],
  ];
  const source = { database: ['owner', grants], routines, extension_members: members };
  const restored = { database: ['owner', [...grants].reverse()], routines: [routines[1], [...routines[0].slice(0, 5), [...grants].reverse()]], extension_members: [...members].reverse() };
  assert.deepEqual(canonicalInventory(source), canonicalInventory(restored));
  const changed = { ...source, database: ['owner', [['app', 'owner', 'SELECT', false], grants[1]]] };
  assert.notDeepEqual(canonicalInventory(source), canonicalInventory(changed));
});

test('normalizes a CHECK only in its matching table DDL statement', () => {
  const oldDefinition = 'CHECK (((a > 1) AND (b < 5)))';
  const canonicalDefinition = 'CHECK ((a > 1) AND (b < 5))';
  const name = '"merchant_locations_check"';
  const row = {
    quoted_schema: '"public"', quoted_object: '"merchant_locations"',
    quoted_name: name, object_kind: 'table',
    raw_definition: oldDefinition, pretty_definition: canonicalDefinition,
  };
  const prefix = `ALTER TABLE ONLY "public"."merchant_locations" ADD CONSTRAINT ${name} `;
  const body = `CREATE FUNCTION "public"."definition_text"() RETURNS text AS $fn$ BEGIN RETURN '${name} ${oldDefinition}'; END; $fn$ LANGUAGE plpgsql;\n`;
  const dump = `${body}${prefix}${oldDefinition};\n`;
  const normalized = normalizeCheckDump(dump, [row]);
  assert.equal(normalized, `${body}${prefix}${canonicalDefinition};\n`);
  assert.throws(() => normalizeCheckDump(body, [row]), /missing or ambiguous/);
  assert.throws(() => normalizeCheckDump(`${body}${prefix}CHECK (a > 2);`, [row]), /missing or ambiguous/);
});

test('normalizes named inline table and domain CHECK clauses by object identity', () => {
  const tableRow = {
    quoted_schema: '"public"', quoted_object: '"locations"', quoted_name: '"coords_ok"', object_kind: 'table',
    raw_definition: 'CHECK (((latitude >= -90) AND (latitude <= 90)))',
    pretty_definition: 'CHECK ((latitude >= -90) AND (latitude <= 90))',
  };
  const tableDump = 'CREATE TABLE "public"."locations" ("latitude" numeric, CONSTRAINT "coords_ok" CHECK (((latitude >= -90) AND (latitude <= 90))));';
  assert.equal(normalizeCheckDump(tableDump, [tableRow]),
    'CREATE TABLE "public"."locations" ("latitude" numeric, CONSTRAINT "coords_ok" CHECK ((latitude >= -90) AND (latitude <= 90)));');
  const followedByAnother = `CREATE TABLE "public"."locations" ("latitude" numeric, CONSTRAINT "coords_ok" ${tableRow.raw_definition}, CONSTRAINT "other" CHECK (latitude IS NOT NULL));`;
  assert.equal(normalizeCheckDump(followedByAnother, [tableRow]),
    followedByAnother.replace(tableRow.raw_definition, tableRow.pretty_definition));

  const domainRow = {
    quoted_schema: '"public"', quoted_object: '"latitude_degrees"', quoted_name: '"valid_latitude"', object_kind: 'domain',
    raw_definition: 'CHECK (((VALUE >= -90) AND (VALUE <= 90)))',
    pretty_definition: 'CHECK ((VALUE >= -90) AND (VALUE <= 90))',
  };
  const domainDump = 'CREATE DOMAIN "public"."latitude_degrees" AS numeric CONSTRAINT "valid_latitude" CHECK (((VALUE >= -90) AND (VALUE <= 90)));';
  assert.equal(normalizeCheckDump(domainDump, [domainRow]),
    'CREATE DOMAIN "public"."latitude_degrees" AS numeric CONSTRAINT "valid_latitude" CHECK ((VALUE >= -90) AND (VALUE <= 90));');
});

test('SQL result uses the always-quoted identifier expected by quote-all-identifiers pg_dump', async () => {
  const name = 'ordinary_check';
  const quoted = '"ordinary_check"';
  const dump = `ALTER TABLE ONLY "public"."t" ADD CONSTRAINT ${quoted} CHECK (a > 1);`;
  const client = { async query(sql) {
    if (sql.includes("current_setting('search_path')")) return { rows: [{ search_path: '"$user", public', quote_all_identifiers: 'off' }] };
    if (sql.includes("set_config('search_path'")) return { rows: [] };
    if (sql.includes('pg_get_constraintdef')) {
      assert.match(sql, /replace\(c\.conname::text, '\"', '\"\"'\)/);
      return { rows: [{ name, quoted_name: quoted, quoted_schema: '"public"', quoted_object: '"t"', object_kind: 'table', raw_definition: 'CHECK (a > 1)', pretty_definition: 'CHECK (a > 1)' }] };
    }
    if (sql.includes("'extension_members'")) return { rows: [{ inventory: { grants: [] } }] };
    throw new Error('Unexpected query');
  } };
  assert.match(await schemaFingerprint({ client, dump }), /^[a-f0-9]{64}$/);
});

test('does not normalize real CHECK operator or value changes', async () => {
  const first = await fingerprint({
    dump: 'ALTER TABLE ONLY "public"."t" ADD CONSTRAINT "ck" CHECK (a > 1);',
    raw: 'CHECK (a > 1)', pretty: 'CHECK (a > 1)', inventory: { grants: [] },
  });
  const changed = await fingerprint({
    dump: 'ALTER TABLE ONLY "public"."t" ADD CONSTRAINT "ck" CHECK (a >= 1);',
    raw: 'CHECK (a >= 1)', pretty: 'CHECK (a >= 1)', inventory: { grants: [] },
  });
  assert.notEqual(first, changed);
});

test('equivalent grouped CHECK dumps fingerprint identically after narrow normalization', async () => {
  const source = await fingerprint({
    dump: 'ALTER TABLE ONLY "public"."t" ADD CONSTRAINT "ck" CHECK (((a > 1) AND (b < 5)));',
    raw: 'CHECK (((a > 1) AND (b < 5)))', pretty: 'CHECK ((a > 1) AND (b < 5))',
    inventory: { grants: [], owners: [] },
  });
  const restored = await fingerprint({
    dump: 'ALTER TABLE ONLY "public"."t" ADD CONSTRAINT "ck" CHECK ((a > 1) AND (b < 5));',
    raw: 'CHECK ((a > 1) AND (b < 5))', pretty: 'CHECK ((a > 1) AND (b < 5))',
    inventory: { grants: [], owners: [] },
  });
  assert.equal(source, restored);
});

test('effective ACL grant and owner drift each change the baseline fingerprint', async () => {
  const base = { grants: [['owner', 'app', 'SELECT', false]], owners: [['public.t', 'owner']] };
  const grantDrift = { grants: [['owner', 'app', 'SELECT', true]], owners: [['public.t', 'owner']] };
  const ownerDrift = { grants: base.grants, owners: [['public.t', 'other_owner']] };
  const fingerprintBase = await fingerprint({ dump: 'CREATE TABLE public.t (id integer);', inventory: base });
  assert.notEqual(fingerprintBase, await fingerprint({ dump: 'CREATE TABLE public.t (id integer);', inventory: grantDrift }));
  assert.notEqual(fingerprintBase, await fingerprint({ dump: 'CREATE TABLE public.t (id integer);', inventory: ownerDrift }));
});

test('extension member identity includes non-relation and non-routine classes', () => {
  const base = { extension_members: [['plpgsql', 'e', 'language', null, 'plpgsql', 'language plpgsql', 'postgres']] };
  const changed = { extension_members: [['plpgsql', 'e', 'language', null, 'plpgsql', 'language plpgsql', 'other_owner']] };
  assert.notDeepEqual(canonicalInventory(base), canonicalInventory(changed));
  assert.match(ACL_INVENTORY_SQL, /pg_identify_object\(d\.classid, d\.objid, d\.objsubid\)/);
  assert.match(ACL_INVENTORY_SQL, /FROM pg_shdepend shared/);
  assert.match(ACL_INVENTORY_SQL, /FROM pg_language x WHERE x\.oid=d\.objid/);
  assert.match(ACL_INVENTORY_SQL, /pg_get_userbyid\(x\.lanowner\)/);
  assert.match(ACL_INVENTORY_SQL, /FROM pg_operator x WHERE x\.oid=d\.objid/);
  assert.doesNotMatch(ACL_INVENTORY_SQL, /d\.classid IN \('pg_class'::regclass, 'pg_proc'::regclass, 'pg_type'::regclass\)/);
  assert.doesNotMatch(ACL_INVENTORY_SQL, /json_build_array\(d\.classid, d\.objid/);
});

test('new ACL catalog collections canonicalize ACL ordering and preserve privilege drift', () => {
  const grantA = ['owner', 'app_role', 'USAGE', false];
  const grantB = ['owner', 'PUBLIC', 'SELECT', true];
  const inventory = {
    languages: [['plx', 'owner', [grantA, grantB]]],
    foreign_data_wrappers: [['fdw', 'owner', [grantA, grantB]]],
    foreign_servers: [['server', 'owner', [grantA, grantB]]],
    tablespaces: [['archive', 'owner', [grantA, grantB]]],
    large_objects: [['12345', 'owner', [grantA, grantB]]],
    parameter_acl: [['statement_timeout', [grantA, grantB]]],
  };
  const reordered = {
    languages: [['plx', 'owner', [grantB, grantA]]],
    foreign_data_wrappers: [['fdw', 'owner', [grantB, grantA]]],
    foreign_servers: [['server', 'owner', [grantB, grantA]]],
    tablespaces: [['archive', 'owner', [grantB, grantA]]],
    large_objects: [['12345', 'owner', [grantB, grantA]]],
    parameter_acl: [['statement_timeout', [grantB, grantA]]],
  };
  assert.deepEqual(canonicalInventory(inventory), canonicalInventory(reordered));

  for (const [category, rows] of Object.entries(inventory)) {
    const changed = structuredClone(inventory);
    const aclIndex = category === 'parameter_acl' ? 1 : 2;
    changed[category][0][aclIndex][0][3] = true;
    assert.notDeepEqual(canonicalInventory(inventory), canonicalInventory(changed), `${category} grantability drift is retained`);
  }

  const largeObjectChanged = structuredClone(inventory);
  largeObjectChanged.large_objects[0][0] = '12346';
  assert.notDeepEqual(canonicalInventory(inventory), canonicalInventory(largeObjectChanged), 'large-object OID identity is retained');
});

test('ACL catalog query captures all portable ACL identities and does not read large-object contents', () => {
  for (const catalog of ['pg_language', 'pg_foreign_data_wrapper', 'pg_foreign_server', 'pg_tablespace', 'pg_largeobject_metadata', 'pg_parameter_acl']) {
    assert.match(ACL_INVENTORY_SQL, new RegExp(`FROM ${catalog}\\b`));
  }
  for (const aclDefault of ["acldefault('l',", "acldefault('F',", "acldefault('S',", "acldefault('t',", "acldefault('L',"]) {
    assert.ok(ACL_INVENTORY_SQL.includes(aclDefault), `default ACL handling exists for ${aclDefault}`);
  }
  assert.match(ACL_INVENTORY_SQL, /m\.oid::text, pg_get_userbyid\(m\.lomowner\)/);
  assert.match(ACL_INVENTORY_SQL, /ORDER BY m\.oid/);
  assert.doesNotMatch(ACL_INVENTORY_SQL, /FROM pg_largeobject\b/);
  assert.match(ACL_INVENTORY_SQL, /p\.parname/);
  assert.match(ACL_INVENTORY_SQL, /semantic_owner','builtin-language/);
  assert.match(ACL_INVENTORY_SQL, /semantic_owner','builtin-tablespace/);
});

async function fingerprint({ dump, raw, pretty, inventory }) {
  const client = { async query(sql) {
    if (sql.includes("current_setting('search_path')")) return { rows: [{ search_path: 'public', quote_all_identifiers: 'off' }] };
    if (sql.includes("set_config('search_path'")) return { rows: [] };
    if (sql.includes('pg_get_constraintdef')) return { rows: raw ? [{
      quoted_name: '"ck"', quoted_schema: '"public"', quoted_object: '"t"', object_kind: 'table',
      raw_definition: raw, pretty_definition: pretty,
    }] : [] };
    if (sql.includes("'extension_members'")) return { rows: [{ inventory }] };
    throw new Error('Unexpected query in fingerprint fixture');
  } };
  return schemaFingerprint({ client, dump });
}
