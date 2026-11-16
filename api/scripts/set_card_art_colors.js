#!/usr/bin/env node
/**
 * Set card_products.art_primary_color from a reviewed colour map.
 *
 * The app already reads art_primary_color from GET /catalogue and uses it as
 * the base colour of the card face (app/lib/features/cards/card_visual.dart),
 * so a colour written here reaches phones on the next catalogue refresh with
 * no new app build.
 *
 * Input: JSON object { "<card slug>": "#RRGGBB", ... }.
 *
 * Safety properties:
 * - a dry run executes every statement and rolls every card back;
 * - each card is its own transaction, locked FOR UPDATE;
 * - only art_primary_color changes (plus data_version, so devices re-sync);
 * - every change writes an admin_audit_log row with the old and new colour;
 * - slugs that are not in the database are reported, never created.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

const HEX = /^#[0-9A-F]{6}$/;

/** Returns { colors: Map(slug -> '#RRGGBB'), errors: [string] }. */
function parseColorMap(raw) {
  const colors = new Map();
  const errors = [];
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { colors, errors: ['input must be a JSON object of slug -> #RRGGBB'] };
  }
  for (const [slug, value] of Object.entries(raw)) {
    const hex = typeof value === 'string' ? value.trim().toUpperCase() : '';
    if (!slug || !/^[a-z0-9][a-z0-9-]*$/.test(slug)) errors.push(`bad slug: ${JSON.stringify(slug)}`);
    else if (!HEX.test(hex)) errors.push(`${slug}: "${value}" is not #RRGGBB`);
    else colors.set(slug, hex);
  }
  return { colors, errors };
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

async function setOne(client, adminId, slug, hex, { dryRun = false } = {}) {
  const selected = await client.query(
    'SELECT id, art_primary_color FROM card_products WHERE slug = $1 FOR UPDATE',
    [slug]
  );
  if (selected.rows.length === 0) return { slug, action: 'missing' };
  const card = selected.rows[0];
  const before = (card.art_primary_color || '').toUpperCase() || null;
  if (before === hex) return { slug, cardProductId: card.id, action: 'unchanged', color: hex };

  await client.query(
    `UPDATE card_products
        SET art_primary_color = $2, data_version = data_version + 1
      WHERE id = $1`,
    [card.id, hex]
  );
  await client.query(
    `INSERT INTO admin_audit_log
       (admin_id, action, entity, entity_id, before_value, after_value, reason)
     VALUES ($1, 'set_card_art_color', 'card_products', $2, $3, $4, $5)`,
    [
      adminId,
      card.id,
      JSON.stringify({ art_primary_color: before }),
      JSON.stringify({ art_primary_color: hex }),
      'Card face colour matched to the issuer card picture (reviewed colour map).',
    ]
  );
  const result = { slug, cardProductId: card.id, action: 'updated', before, color: hex };
  if (dryRun) {
    const rollback = new Error('__DRY_RUN_ROLLBACK__');
    rollback.result = result;
    throw rollback;
  }
  return result;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(
      'Usage: node set_card_art_colors.js --input <colors.json> ' +
      '[--admin-id <uuid>] [--report-dir <dir>] [--dry-run]'
    );
    return;
  }
  if (!args.input) throw new Error('--input is required.');
  if (!args.adminId) throw new Error('--admin-id or CARD_IMPORT_ADMIN_ID is required.');
  const { colors, errors } = parseColorMap(JSON.parse(fs.readFileSync(args.input, 'utf8')));
  if (errors.length) throw new Error(`invalid colour map:\n${errors.join('\n')}`);

  const report = {
    generatedAt: new Date().toISOString(),
    dryRun: args.dryRun,
    input: path.resolve(args.input),
    total: colors.size,
    updated: [],
    unchanged: [],
    missing: [],
    failed: [],
  };

  const pool = createPool();
  try {
    const admin = await withAdminClient(pool, args.adminId, (client) =>
      client.query('SELECT is_active FROM admin_users WHERE id = $1', [args.adminId])
    );
    if (admin.rows.length === 0 || !admin.rows[0].is_active) {
      throw new Error(`--admin-id ${args.adminId} is not an active admin_users row.`);
    }
    for (const [slug, hex] of colors) {
      let result;
      try {
        result = await withAdminClient(pool, args.adminId, (client) =>
          setOne(client, args.adminId, slug, hex, { dryRun: args.dryRun })
        );
      } catch (error) {
        if (error.message === '__DRY_RUN_ROLLBACK__') result = error.result;
        else {
          report.failed.push({ slug, reason: error.message });
          continue;
        }
      }
      if (result.action === 'updated') report.updated.push(result);
      else if (result.action === 'unchanged') report.unchanged.push(result);
      else report.missing.push(result);
    }
    const reportDir = path.resolve(args.reportDir || path.dirname(args.input));
    fs.mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, `art-color-report-${Date.now()}.json`);
    fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    console.log(`Card colour ${args.dryRun ? 'dry run' : 'run'} for ${colors.size} card(s)`);
    console.log(`updated:   ${report.updated.length}`);
    console.log(`unchanged: ${report.unchanged.length}`);
    console.log(`missing:   ${report.missing.length}`);
    console.log(`failed:    ${report.failed.length}`);
    console.log(`report:    ${reportPath}`);
    if (report.failed.length) process.exitCode = 1;
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}

module.exports = { parseColorMap, setOne };
