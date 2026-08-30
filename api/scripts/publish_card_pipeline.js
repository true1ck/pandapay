#!/usr/bin/env node
/**
 * Publish the exact CardPipeline records supplied in --input after import.
 *
 * Safety properties:
 * - a database row is eligible only when its import source hash and importer
 *   transform version match the supplied normalized JSON exactly;
 * - draft rows follow draft -> in_review -> published, with the same audit
 *   records as the admin status endpoint;
 * - already-published rows are no-ops;
 * - each card is isolated in its own transaction;
 * - --dry-run executes every database constraint and rolls every card back.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const {
  IMPORT_TRANSFORM_VERSION,
  sourceHash,
} = require('./import_card_pipeline');

for (const envPath of [path.resolve(__dirname, '../../.env'), path.resolve(__dirname, '../.env')]) {
  if (fs.existsSync(envPath)) require('dotenv').config({ path: envPath, quiet: true });
}

function parseArgs(argv) {
  const args = {
    dryRun: false,
    adminId: process.env.CARD_IMPORT_ADMIN_ID || null,
    reportDir: process.env.CARD_IMPORT_REPORT_DIR || null,
  };
  const takeValue = (flag, index) => {
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    return value;
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--input') args.input = takeValue(arg, i++);
    else if (arg === '--admin-id') args.adminId = takeValue(arg, i++);
    else if (arg === '--report-dir') args.reportDir = takeValue(arg, i++);
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function createPool() {
  const databaseUrl =
    process.env.DATABASE_URL || process.env.API_DATABASE_URL || process.env.ADMIN_DATABASE_URL;
  if (!databaseUrl) {
    throw new Error('DATABASE_URL, API_DATABASE_URL, or ADMIN_DATABASE_URL must be set.');
  }
  return new Pool({
    connectionString: databaseUrl,
    ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  });
}

async function withAdminClient(pool, adminId, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [adminId]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

async function auditTransition(client, adminId, cardId, before, after, reason) {
  await client.query(
    `INSERT INTO admin_audit_log
       (admin_id, action, entity, entity_id, before_value, after_value, reason)
     VALUES ($1, 'change_card_status', 'card_products', $2, $3, $4, $5)`,
    [adminId, cardId, JSON.stringify(before), JSON.stringify(after), reason]
  );
}

async function publishOne(client, adminId, record, { dryRun = false } = {}) {
  const slug = record.card_product.slug;
  const expectedHash = sourceHash(record);
  const selected = await client.query(
    `SELECT id, slug, status, verified_at, verified_by,
            import_source_hash, import_transform_version
       FROM card_products
      WHERE slug = $1
      FOR UPDATE`,
    [slug]
  );
  if (selected.rows.length === 0) return { slug, action: 'missing' };
  const card = selected.rows[0];
  if (
    card.import_source_hash !== expectedHash
    || card.import_transform_version !== IMPORT_TRANSFORM_VERSION
  ) {
    return {
      slug,
      cardProductId: card.id,
      action: 'source_mismatch',
      databaseTransformVersion: card.import_transform_version,
    };
  }
  if (card.status === 'published') {
    return {
      slug,
      cardProductId: card.id,
      action: 'already_published',
      status: card.status,
      publishedAt: card.verified_at,
      verifiedBy: card.verified_by,
      sourceHash: card.import_source_hash,
    };
  }
  if (!['draft', 'in_review'].includes(card.status)) {
    return { slug, cardProductId: card.id, action: 'invalid_status', status: card.status };
  }

  let current = card;
  if (current.status === 'draft') {
    const staged = await client.query(
      `UPDATE card_products SET status = 'in_review' WHERE id = $1
       RETURNING id, status, verified_at, verified_by`,
      [card.id]
    );
    await auditTransition(
      client,
      adminId,
      card.id,
      { status: current.status, verified_at: current.verified_at },
      staged.rows[0],
      'User-approved CardPipeline publication: staged verified normalized data for final publication.'
    );
    current = { ...current, ...staged.rows[0] };
  }

  const published = await client.query(
    `UPDATE card_products
        SET status = 'published',
            verified_at = COALESCE(verified_at, now()),
            verified_by = COALESCE(verified_by, $2::uuid)
      WHERE id = $1
      RETURNING id, status, verified_at, verified_by, import_source_hash`,
    [card.id, adminId]
  );
  await auditTransition(
    client,
    adminId,
    card.id,
    { status: current.status, verified_at: current.verified_at },
    published.rows[0],
    'User-approved CardPipeline publication after incremental extraction and publication-gate audit.'
  );
  const result = {
    slug,
    cardProductId: card.id,
    action: 'published',
    status: published.rows[0].status,
    publishedAt: published.rows[0].verified_at,
    verifiedBy: published.rows[0].verified_by,
    sourceHash: published.rows[0].import_source_hash,
  };
  if (dryRun) {
    const rollback = new Error('__DRY_RUN_ROLLBACK__');
    rollback.result = result;
    throw rollback;
  }
  return result;
}

function uniqueRecords(records) {
  const bySlug = new Map();
  for (const record of records) {
    const slug = record?.card_product?.slug;
    if (!slug) throw new Error('Every input record must have card_product.slug.');
    if (bySlug.has(slug)) throw new Error(`Duplicate input slug: ${slug}`);
    bySlug.set(slug, record);
  }
  return [...bySlug.values()];
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(
      'Usage: node publish_card_pipeline.js --input <all-collected.json> ' +
      '[--admin-id <uuid>] [--report-dir <dir>] [--dry-run]'
    );
    return;
  }
  if (!args.input) throw new Error('--input is required.');
  if (!args.adminId) throw new Error('--admin-id or CARD_IMPORT_ADMIN_ID is required.');
  const records = uniqueRecords(JSON.parse(fs.readFileSync(args.input, 'utf8')));
  const report = {
    generatedAt: new Date().toISOString(),
    dryRun: args.dryRun,
    input: path.resolve(args.input),
    transformVersion: IMPORT_TRANSFORM_VERSION,
    total: records.length,
    published: [],
    alreadyPublished: [],
    missing: [],
    sourceMismatch: [],
    invalidStatus: [],
    failed: [],
  };

  const pool = createPool();
  const lockClient = await pool.connect();
  let lockAcquired = false;
  try {
    const lock = await lockClient.query(
      "SELECT pg_try_advisory_lock(hashtextextended('pandapay.card_catalogue_publish', 0)) AS acquired"
    );
    lockAcquired = lock.rows[0]?.acquired === true;
    if (!lockAcquired) throw new Error('another card catalogue publication is already running.');

    const admin = await withAdminClient(pool, args.adminId, (client) =>
      client.query('SELECT is_active FROM admin_users WHERE id = $1', [args.adminId])
    );
    if (admin.rows.length === 0 || !admin.rows[0].is_active) {
      throw new Error(`--admin-id ${args.adminId} is not an active admin_users row.`);
    }

    for (const record of records) {
      let result;
      try {
        result = await withAdminClient(pool, args.adminId, (client) =>
          publishOne(client, args.adminId, record, { dryRun: args.dryRun })
        );
      } catch (error) {
        if (error.message === '__DRY_RUN_ROLLBACK__') result = error.result;
        else {
          report.failed.push({ slug: record.card_product.slug, reason: error.message });
          continue;
        }
      }
      if (result.action === 'published') report.published.push(result);
      else if (result.action === 'already_published') report.alreadyPublished.push(result);
      else if (result.action === 'missing') report.missing.push(result);
      else if (result.action === 'source_mismatch') report.sourceMismatch.push(result);
      else report.invalidStatus.push(result);
    }

    const reportDir = path.resolve(args.reportDir || path.dirname(args.input));
    fs.mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, `publish-report-${Date.now()}.json`);
    fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    console.log(`Publication ${args.dryRun ? 'dry run' : 'run'} for ${records.length} card(s)`);
    console.log(`published:         ${report.published.length}`);
    console.log(`already published: ${report.alreadyPublished.length}`);
    console.log(`source mismatch:   ${report.sourceMismatch.length}`);
    console.log(`missing:           ${report.missing.length}`);
    console.log(`invalid status:    ${report.invalidStatus.length}`);
    console.log(`failed:            ${report.failed.length}`);
    console.log(`Report: ${reportPath}`);
    if (
      report.sourceMismatch.length
      || report.missing.length
      || report.invalidStatus.length
      || report.failed.length
    ) process.exitCode = 1;
  } finally {
    if (lockAcquired) {
      await lockClient
        .query("SELECT pg_advisory_unlock(hashtextextended('pandapay.card_catalogue_publish', 0))")
        .catch(() => {});
    }
    lockClient.release();
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error('Fatal error:', error.message || error);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs, publishOne, uniqueRecords };
