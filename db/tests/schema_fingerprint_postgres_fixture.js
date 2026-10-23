'use strict';

const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const {
  ACL_INVENTORY_SQL,
  canonicalInventory,
  normalizeCheckDump,
} = require('../scripts/schema_fingerprint');

function quoteIdentifier(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function quoteLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

/**
 * Disposable PostgreSQL regression fixture. Caller must pass an idle client
 * connected to the isolated restored-copy database; all changes are rolled
 * back. This exercises real catalog deparsing and pg_identify_object output.
 */
async function runSchemaFingerprintPostgresFixture(client) {
  const suffix = randomUUID().replaceAll('-', '').slice(0, 16);
  const schema = `fp_${suffix}`;
  const table = `check_table_${suffix}`;
  const domain = `check_domain_${suffix}`;
  const routine = `check_text_${suffix}`;
  const constraint = `check_${suffix}`;
  const domainConstraint = `domain_check_${suffix}`;
  const qSchema = quoteIdentifier(schema);
  const qTable = quoteIdentifier(table);
  const qDomain = quoteIdentifier(domain);
  const qRoutine = quoteIdentifier(routine);
  const qConstraint = quoteIdentifier(constraint);
  const qDomainConstraint = quoteIdentifier(domainConstraint);

  await client.query('BEGIN');
  try {
    await client.query('CREATE EXTENSION IF NOT EXISTS plpgsql');
    await client.query(`CREATE SCHEMA ${qSchema}`);
    await client.query(`CREATE TABLE ${qSchema}.${qTable} ("a" integer, CONSTRAINT ${qConstraint} CHECK ("a" > 1))`);
    await client.query(`CREATE DOMAIN ${qSchema}.${qDomain} AS numeric CONSTRAINT ${qDomainConstraint} CHECK (VALUE > -90)`);
    const checkResult = await client.query(`SELECT c.conname,
      ('"' || replace(c.conname::text, '"', '""') || '"') AS quoted_name,
      pg_get_constraintdef(c.oid, false) AS raw_definition,
      pg_get_constraintdef(c.oid, true) AS pretty_definition
      FROM pg_constraint c
      JOIN pg_class r ON r.oid=c.conrelid
      JOIN pg_namespace n ON n.oid=r.relnamespace
      WHERE n.nspname=$1 AND r.relname=$2 AND c.conname=$3 AND c.contype='c'`,
    [schema, table, constraint]);
    assert.equal(checkResult.rows.length, 1, 'fixture CHECK must exist');
    const check = checkResult.rows[0];
    const domainCheckResult = await client.query(`SELECT c.conname,
      ('"' || replace(c.conname::text, '"', '""') || '"') AS quoted_name,
      pg_get_constraintdef(c.oid, false) AS raw_definition,
      pg_get_constraintdef(c.oid, true) AS pretty_definition
      FROM pg_constraint c JOIN pg_type t ON t.oid=c.contypid
      JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE n.nspname=$1 AND t.typname=$2 AND c.conname=$3 AND c.contype='c'`,
    [schema, domain, domainConstraint]);
    assert.equal(domainCheckResult.rows.length, 1, 'fixture domain CHECK must exist');
    const domainCheck = domainCheckResult.rows[0];
    const quotedDefinition = `${qConstraint} ${check.raw_definition}`;
    await client.query(`CREATE FUNCTION ${qSchema}.${qRoutine}() RETURNS text
      LANGUAGE sql AS $fixture$ SELECT ${quoteLiteral(quotedDefinition)}::text $fixture$`);
    const functionResult = await client.query(`SELECT pg_get_functiondef(p.oid) AS definition
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname=$1 AND p.proname=$2`, [schema, routine]);
    assert.equal(functionResult.rows.length, 1, 'fixture routine must exist');
    const functionDdl = `${functionResult.rows[0].definition};\n`;
    const row = {
      quoted_schema: qSchema,
      quoted_object: qTable,
      quoted_name: check.quoted_name,
      object_kind: 'table',
      raw_definition: check.raw_definition,
      pretty_definition: check.pretty_definition,
    };
    const tableDdl = `CREATE TABLE ${qSchema}.${qTable} ("a" integer, CONSTRAINT ${qConstraint} ${check.raw_definition});\n`;
    const domainDdl = `CREATE DOMAIN ${qSchema}.${qDomain} AS numeric CONSTRAINT ${qDomainConstraint} ${domainCheck.raw_definition};\n`;
    const dump = `${functionDdl}${tableDdl}${domainDdl}`;
    const normalized = normalizeCheckDump(dump, [row]);
    assert.ok(normalized.startsWith(functionDdl), 'function text containing CHECK-like text must remain byte-for-byte unchanged');
    assert.ok(normalized.includes(`${qConstraint} ${check.pretty_definition});`), 'real inline table CHECK DDL must be matched and normalized');
    assert.throws(() => normalizeCheckDump(functionDdl, [row]), /missing or ambiguous/,
      'CHECK-like function text must not satisfy a missing DDL constraint');
    assert.throws(() => normalizeCheckDump(`${functionDdl}CREATE TABLE ${qSchema}.${qTable} ("a" integer, CONSTRAINT ${qConstraint} CHECK ("a" >= 2));`, [row]), /missing or ambiguous/,
      'a changed real CHECK expression must fail closed');
    const domainRow = {
      quoted_schema: qSchema, quoted_object: qDomain, quoted_name: domainCheck.quoted_name,
      object_kind: 'domain', raw_definition: domainCheck.raw_definition,
      pretty_definition: domainCheck.pretty_definition,
    };
    const normalizedDomain = normalizeCheckDump(domainDdl, [domainRow]);
    assert.ok(normalizedDomain.includes(`${qDomainConstraint} ${domainCheck.pretty_definition};`),
      'real inline domain CHECK DDL must be matched and normalized');

    const inventoryResult = await client.query(ACL_INVENTORY_SQL);
    const inventory = inventoryResult.rows[0]?.inventory;
    assert.ok(inventory && Array.isArray(inventory.extension_members), 'extension membership inventory must be present');
    assert.ok(inventory.extension_members.some(member => member[2] === 'language' && member[4] === 'plpgsql'),
      'generic member inventory must include the non-class/procedure/type plpgsql language member');
    const member = inventory.extension_members.find(item => item[2] === 'language' && item[4] === 'plpgsql');
    const languageOwner = await client.query(`SELECT pg_get_userbyid(lanowner) AS owner
      FROM pg_language WHERE lanname='plpgsql'`);
    assert.equal(member[6], languageOwner.rows[0]?.owner,
      'extension member owner must come from the catalog even when pg_shdepend omits a pinned role');
    const changedInventory = structuredClone(inventory);
    const changedMember = changedInventory.extension_members.find(item => item[2] === 'language' && item[4] === 'plpgsql');
    changedMember[5] = `${changedMember[5]} changed`;
    assert.notDeepEqual(canonicalInventory(inventory), canonicalInventory(changedInventory),
      'semantic identity drift for a generic extension member must change the fingerprint inventory');
    assert.ok(member.every(value => typeof value !== 'number'), 'extension member identity must not expose catalog OIDs');
    return { checks: 4, extensionMembers: 1 };
  } finally {
    await client.query('ROLLBACK');
  }
}

module.exports = { runSchemaFingerprintPostgresFixture };
