'use strict';

const { safeErrorCode } = require('../src/utils/safeErrorCode');

const DEFAULT_STATEMENT_TIMEOUT_MS = 15000;
const DEFAULT_CONNECT_TIMEOUT_MS = 5000;
const MAX_STATEMENT_TIMEOUT_MS = 300000;
const MAX_CONNECT_TIMEOUT_MS = 30000;

function boundedTimeout(value, fallback, name, maximum) {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1000 || parsed > maximum) {
    throw new Error(`${name} must be an integer from 1000 to ${maximum}`);
  }
  return parsed;
}

function countValue(value) {
  const count = BigInt(value === null || value === undefined ? 0 : value);
  if (count < 0n) throw new Error('Audit query returned a negative count');
  return count <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(count) : count.toString();
}

function countRecord(row, fields) {
  const result = {};
  for (const field of fields) result[field] = countValue(row[field]);
  return result;
}

const CONTACT_METRICS_SQL = `
  SELECT
    COUNT(*)::bigint AS total_users,
    COUNT(*) FILTER (WHERE deleted IS FALSE)::bigint AS active_users,
    COUNT(*) FILTER (WHERE deleted IS TRUE)::bigint AS deleted_users,
    COUNT(*) FILTER (WHERE deleted IS NULL)::bigint AS null_deleted_users,
    COUNT(*) FILTER (WHERE email IS NULL)::bigint AS email_null_rows,
    COUNT(*) FILTER (WHERE email IS NOT NULL AND btrim(email) = '')::bigint AS email_blank_rows,
    COUNT(*) FILTER (
      WHERE email IS NOT NULL AND btrim(email) <> ''
        AND btrim(email) !~ '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$'
    )::bigint AS email_malformed_rows,
    COUNT(*) FILTER (WHERE phone_number IS NULL)::bigint AS phone_null_rows,
    COUNT(*) FILTER (WHERE phone_number IS NOT NULL AND btrim(phone_number) = '')::bigint AS phone_blank_storage_rows,
    COUNT(*) FILTER (WHERE phone_number IS NOT NULL)::bigint AS phone_present_rows,
    COUNT(*) FILTER (WHERE phone_number IS NOT NULL AND phone_lookup_hash IS NULL)::bigint AS phone_missing_hash_rows,
    COUNT(*) FILTER (WHERE phone_lookup_hash IS NOT NULL AND phone_lookup_hash !~ '^[0-9a-fA-F]{64}$')::bigint AS phone_malformed_hash_rows
  FROM users
`;

const DUPLICATE_EXPRESSIONS = Object.freeze({
  email_lower: Object.freeze({ column: 'email', expression: 'lower(email)' }),
  email_trimmed_lower: Object.freeze({ column: 'email', expression: 'lower(btrim(email))' }),
  phone_lookup_hash: Object.freeze({ column: 'phone_lookup_hash', expression: 'phone_lookup_hash' }),
});

function duplicateMetricsSql({ column, expression }) {
  return `
    SELECT
      COUNT(*) FILTER (WHERE group_rows > 1)::bigint AS duplicate_groups,
      COALESCE(SUM(group_rows) FILTER (WHERE group_rows > 1), 0)::bigint AS duplicate_rows,
      COALESCE(SUM(group_rows - 1) FILTER (WHERE group_rows > 1), 0)::bigint AS extra_rows
    FROM (
      SELECT ${expression} AS identity_key, COUNT(*)::bigint AS group_rows
      FROM users
      WHERE ${column} IS NOT NULL
        AND ($1::boolean IS FALSE OR deleted IS FALSE)
      GROUP BY ${expression}
    ) AS duplicate_groups
  `;
}

async function runAudit(pool, {
  statementTimeoutMs = DEFAULT_STATEMENT_TIMEOUT_MS,
} = {}) {
  const statementTimeout = boundedTimeout(
    statementTimeoutMs,
    DEFAULT_STATEMENT_TIMEOUT_MS,
    'CONTACT_AUDIT_STATEMENT_TIMEOUT_MS',
    MAX_STATEMENT_TIMEOUT_MS,
  );
  const client = await pool.connect();
  let transactionStarted = false;
  let discardConnection = false;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    transactionStarted = true;
    await client.query(`SET LOCAL statement_timeout = '${statementTimeout}ms'`);
    await client.query("SET LOCAL lock_timeout = '5000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '30000ms'");
    const readOnly = await client.query('SHOW transaction_read_only');
    if (String(readOnly.rows[0]?.transaction_read_only).toLowerCase() !== 'on') {
      throw new Error('Contact audit transaction is not read-only');
    }
    const isolation = await client.query('SHOW transaction_isolation');
    if (String(isolation.rows[0]?.transaction_isolation).toLowerCase() !== 'repeatable read') {
      throw new Error('Contact audit transaction does not use repeatable-read isolation');
    }

    const metrics = await client.query(CONTACT_METRICS_SQL);
    const lifecycleAndQuality = countRecord(metrics.rows[0] || {}, [
      'total_users', 'active_users', 'deleted_users', 'null_deleted_users',
      'email_null_rows', 'email_blank_rows', 'email_malformed_rows',
      'phone_null_rows', 'phone_blank_storage_rows', 'phone_present_rows', 'phone_missing_hash_rows',
      'phone_malformed_hash_rows',
    ]);
    const duplicates = {};
    for (const [name, definition] of Object.entries(DUPLICATE_EXPRESSIONS)) {
      duplicates[name] = {};
      const sql = duplicateMetricsSql(definition);
      for (const [scope, activeOnly] of [['all_rows', false], ['active_only', true]]) {
        const result = await client.query(sql, [activeOnly]);
        duplicates[name][scope] = countRecord(result.rows[0] || {}, [
          'duplicate_groups', 'duplicate_rows', 'extra_rows',
        ]);
      }
    }

    return {
      audit: 'auth-contact-uniqueness-v1',
      source: 'public.users',
      lifecycle: {
        total: lifecycleAndQuality.total_users,
        active: lifecycleAndQuality.active_users,
        deleted: lifecycleAndQuality.deleted_users,
        null_deleted: lifecycleAndQuality.null_deleted_users,
      },
      contact_quality: {
        email: {
          null_rows: lifecycleAndQuality.email_null_rows,
          blank_rows: lifecycleAndQuality.email_blank_rows,
          malformed_rows: lifecycleAndQuality.email_malformed_rows,
        },
        phone: {
          null_rows: lifecycleAndQuality.phone_null_rows,
          blank_storage_rows: lifecycleAndQuality.phone_blank_storage_rows,
          present_rows: lifecycleAndQuality.phone_present_rows,
          missing_hash_rows: lifecycleAndQuality.phone_missing_hash_rows,
          malformed_hash_rows: lifecycleAndQuality.phone_malformed_hash_rows,
        },
      },
      duplicates,
      gates: {
        lifecycle_defined: lifecycleAndQuality.null_deleted_users === 0,
        phone_hashes_complete: lifecycleAndQuality.phone_missing_hash_rows === 0,
        no_malformed_phone_hashes: lifecycleAndQuality.phone_malformed_hash_rows === 0,
        active_uniqueness_clear: Object.values(duplicates).every(metric =>
          metric.active_only.duplicate_groups === 0),
      },
    };
  } catch (error) {
    if (transactionStarted) {
      try {
        await client.query('ROLLBACK');
        transactionStarted = false;
      } catch (_) {
        discardConnection = true;
      }
    }
    throw error;
  } finally {
    if (transactionStarted) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {
        discardConnection = true;
      }
    }
    client.release(discardConnection);
  }
}

function auditExitCode(report, requireUnique = false) {
  if (!report.gates.lifecycle_defined) return 2;
  return requireUnique && !report.gates.active_uniqueness_clear ? 2 : 0;
}

async function main(argv = process.argv.slice(2)) {
  if (argv.some(arg => arg !== '--require-unique') || argv.length > 1) throw new Error('Unknown audit option');
  const connectionString = process.env.AUTH_MIGRATION_DATABASE_URL || process.env.AUTH_DATABASE_URL;
  if (!connectionString) throw new Error('An explicit auth database URL is required');
  const connectTimeoutMs = boundedTimeout(
    process.env.CONTACT_AUDIT_CONNECT_TIMEOUT_MS,
    DEFAULT_CONNECT_TIMEOUT_MS,
    'CONTACT_AUDIT_CONNECT_TIMEOUT_MS',
    MAX_CONNECT_TIMEOUT_MS,
  );
  const statementTimeoutMs = boundedTimeout(
    process.env.CONTACT_AUDIT_STATEMENT_TIMEOUT_MS,
    DEFAULT_STATEMENT_TIMEOUT_MS,
    'CONTACT_AUDIT_STATEMENT_TIMEOUT_MS',
    MAX_STATEMENT_TIMEOUT_MS,
  );
  const { Pool } = require('pg');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const tls = resolveDatabaseTls(connectionString, process.env);
  const pool = new Pool({
    ...tls,
    max: 1,
    connectionTimeoutMillis: connectTimeoutMs,
    idleTimeoutMillis: 1000,
  });
  try {
    const report = await runAudit(pool, { statementTimeoutMs });
    process.stdout.write(`${JSON.stringify(report)}\n`);
    process.exitCode = auditExitCode(report, argv.includes('--require-unique'));
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`Contact uniqueness audit failed (${safeErrorCode(error)})\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  runAudit,
  boundedTimeout,
  CONTACT_METRICS_SQL,
  duplicateMetricsSql,
  auditExitCode,
};
