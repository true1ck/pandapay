#!/usr/bin/env node
/**
 * Seeds merchant_brands / payment_platforms (plan C1, C5) from
 * db/fixtures/merchant_directory.json. Idempotent: a second run changes
 * nothing. Never deletes rows.
 *
 * Usage:
 *   node api/scripts/seed_merchant_directory.js --dry-run
 *   node api/scripts/seed_merchant_directory.js --apply [--deactivate-missing]
 *   Optional: --file <path to directory json>
 *
 * - Slugs in the file are upserted; a slug present in the file is active.
 * - Slugs that disappeared from the file are left alone, unless
 *   --deactivate-missing is given, which sets is_active = false for them
 *   (slugs are permanent; they are never renamed or deleted).
 * - Connects with ADMIN_DATABASE_URL (preferred, the table owner), else
 *   DATABASE_URL / API_DATABASE_URL. The directory tables are admin-write
 *   under RLS, so a plain customer-runtime role cannot seed them.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_FILE = path.resolve(__dirname, '../../db/fixtures/merchant_directory.json');
const SLUG_RE = /^[a-z0-9_]+$/;
const PLATFORM_KINDS = new Set(['payment_app', 'bank_portal', 'merchant_app', 'network_program']);

function strArray(value, where) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.some((v) => typeof v !== 'string')) {
    throw new Error(`${where} must be an array of strings`);
  }
  return value;
}

function optText(value, where) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new Error(`${where} must be a string`);
  return value;
}

/** Validates the file and returns normalised {merchants, platforms}. Throws on any problem. */
function parseDirectory(doc) {
  if (!doc || typeof doc !== 'object' || doc.version !== 1) {
    throw new Error('directory file must be an object with version 1');
  }
  if (!Array.isArray(doc.merchants) || !Array.isArray(doc.platforms)) {
    throw new Error('directory file needs "merchants" and "platforms" arrays');
  }
  const merchants = [];
  const seen = new Set();
  for (const m of doc.merchants) {
    const where = `merchant ${m && m.slug}`;
    if (!m || typeof m.slug !== 'string' || !SLUG_RE.test(m.slug)) throw new Error(`${where}: invalid slug`);
    if (seen.has(m.slug)) throw new Error(`${where}: duplicate slug`);
    seen.add(m.slug);
    if (typeof m.name !== 'string' || !m.name) throw new Error(`${where}: name required`);
    merchants.push({
      slug: m.slug,
      name: m.name,
      parent_slug: optText(m.parent_slug, `${where}.parent_slug`),
      category_slug: optText(m.category_slug, `${where}.category_slug`),
      aliases: strArray(m.aliases, `${where}.aliases`),
      vpa_prefixes: strArray(m.vpa_prefixes, `${where}.vpa_prefixes`),
      mcc: strArray(m.mcc, `${where}.mcc`),
    });
  }
  const bySlug = new Map(merchants.map((m) => [m.slug, m]));
  for (const m of merchants) {
    if (m.parent_slug !== null && !bySlug.has(m.parent_slug)) {
      throw new Error(`merchant ${m.slug}: parent_slug ${m.parent_slug} is not in the file`);
    }
    const chain = new Set([m.slug]);
    for (let p = m.parent_slug; p !== null; p = bySlug.get(p).parent_slug) {
      if (chain.has(p)) throw new Error(`merchant ${m.slug}: parent cycle`);
      chain.add(p);
    }
  }
  const platforms = [];
  const seenP = new Set();
  for (const p of doc.platforms) {
    const where = `platform ${p && p.slug}`;
    if (!p || typeof p.slug !== 'string' || !SLUG_RE.test(p.slug)) throw new Error(`${where}: invalid slug`);
    if (seenP.has(p.slug)) throw new Error(`${where}: duplicate slug`);
    seenP.add(p.slug);
    if (typeof p.name !== 'string' || !p.name) throw new Error(`${where}: name required`);
    if (!PLATFORM_KINDS.has(p.kind)) throw new Error(`${where}: unknown kind ${p.kind}`);
    platforms.push({
      slug: p.slug,
      name: p.name,
      kind: p.kind,
      issuer_slug: optText(p.issuer_slug, `${where}.issuer_slug`),
      aliases: strArray(p.aliases, `${where}.aliases`),
      notes: optText(p.notes, `${where}.notes`),
    });
  }
  return { merchants: orderParentsFirst(merchants), platforms };
}

/** Parents before children so the self-referencing FK is satisfied row by row. */
function orderParentsFirst(merchants) {
  const bySlug = new Map(merchants.map((m) => [m.slug, m]));
  const out = [];
  const done = new Set();
  const visit = (m) => {
    if (done.has(m.slug)) return;
    if (m.parent_slug) visit(bySlug.get(m.parent_slug));
    done.add(m.slug);
    out.push(m);
  };
  merchants.forEach(visit);
  return out;
}

const MERCHANT_FIELDS = ['name', 'parent_slug', 'category_slug', 'aliases', 'vpa_prefixes', 'mcc'];
const PLATFORM_FIELDS = ['name', 'kind', 'issuer_slug', 'aliases', 'notes'];

function sameValue(a, b) {
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

function diffRows(wanted, existingRows, fields) {
  const existing = new Map(existingRows.map((r) => [r.slug, r]));
  const insert = [];
  const update = [];
  let unchanged = 0;
  for (const row of wanted) {
    const current = existing.get(row.slug);
    if (!current) insert.push(row);
    else if (!current.is_active || fields.some((f) => !sameValue(row[f], current[f]))) update.push(row);
    else unchanged += 1;
  }
  const wantedSlugs = new Set(wanted.map((r) => r.slug));
  const missing = existingRows.filter((r) => r.is_active && !wantedSlugs.has(r.slug)).map((r) => r.slug);
  return { insert, update, unchanged, missing };
}

async function loadExisting(client) {
  const merchants = await client.query(
    'SELECT slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc, is_active FROM merchant_brands');
  const platforms = await client.query(
    'SELECT slug, name, kind, issuer_slug, aliases, notes, is_active FROM payment_platforms');
  return { merchants: merchants.rows, platforms: platforms.rows };
}

function buildPlan(directory, existing) {
  return {
    merchants: diffRows(directory.merchants, existing.merchants, MERCHANT_FIELDS),
    platforms: diffRows(directory.platforms, existing.platforms, PLATFORM_FIELDS),
  };
}

const UPSERT_MERCHANT = `
  INSERT INTO merchant_brands (slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc, is_active)
  VALUES ($1, $2, $3, $4, $5, $6, $7, true)
  ON CONFLICT (slug) DO UPDATE SET
    name = EXCLUDED.name, parent_slug = EXCLUDED.parent_slug, category_slug = EXCLUDED.category_slug,
    aliases = EXCLUDED.aliases, vpa_prefixes = EXCLUDED.vpa_prefixes, mcc = EXCLUDED.mcc,
    is_active = true`;
const UPSERT_PLATFORM = `
  INSERT INTO payment_platforms (slug, name, kind, issuer_slug, aliases, notes, is_active)
  VALUES ($1, $2, $3, $4, $5, $6, true)
  ON CONFLICT (slug) DO UPDATE SET
    name = EXCLUDED.name, kind = EXCLUDED.kind, issuer_slug = EXCLUDED.issuer_slug,
    aliases = EXCLUDED.aliases, notes = EXCLUDED.notes, is_active = true`;
const DEACTIVATE_MERCHANTS = 'UPDATE merchant_brands SET is_active = false WHERE slug = ANY($1) AND is_active';
const DEACTIVATE_PLATFORMS = 'UPDATE payment_platforms SET is_active = false WHERE slug = ANY($1) AND is_active';

/** Applies a plan in one transaction. Rows are only touched when they differ. */
async function applyPlan(client, plan, { deactivateMissing = false } = {}) {
  await client.query('BEGIN');
  try {
    // Parents first across inserts and updates so a new parent exists before its child.
    const merchantOrder = [...plan.merchants.insert, ...plan.merchants.update];
    for (const m of merchantOrder) {
      await client.query(UPSERT_MERCHANT, [m.slug, m.name, m.parent_slug, m.category_slug, m.aliases, m.vpa_prefixes, m.mcc]);
    }
    for (const p of [...plan.platforms.insert, ...plan.platforms.update]) {
      await client.query(UPSERT_PLATFORM, [p.slug, p.name, p.kind, p.issuer_slug, p.aliases, p.notes]);
    }
    if (deactivateMissing) {
      if (plan.merchants.missing.length) await client.query(DEACTIVATE_MERCHANTS, [plan.merchants.missing]);
      if (plan.platforms.missing.length) await client.query(DEACTIVATE_PLATFORMS, [plan.platforms.missing]);
    }
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  }
}

function summarise(plan, { deactivateMissing }) {
  const line = (label, d) =>
    `${label}: insert ${d.insert.length}, update ${d.update.length}, unchanged ${d.unchanged}, ` +
    `missing-from-file ${d.missing.length}${deactivateMissing ? ' (will deactivate)' : ' (left as is)'}`;
  return [line('merchants', plan.merchants), line('platforms', plan.platforms)].join('\n');
}

function parseArgs(argv) {
  const args = { dryRun: false, apply: false, deactivateMissing: false, file: DEFAULT_FILE };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dry-run') args.dryRun = true;
    else if (a === '--apply') args.apply = true;
    else if (a === '--deactivate-missing') args.deactivateMissing = true;
    else if (a === '--file') args.file = path.resolve(argv[++i] || '');
    else throw new Error(`Unknown argument ${a}`);
  }
  if (args.dryRun === args.apply) throw new Error('Pass exactly one of --dry-run or --apply');
  return args;
}

async function run(argv, { createClient, log = console.log } = {}) {
  const args = parseArgs(argv);
  const directory = parseDirectory(JSON.parse(fs.readFileSync(args.file, 'utf8')));
  const client = await createClient();
  try {
    const plan = buildPlan(directory, await loadExisting(client));
    log(summarise(plan, args));
    if (args.dryRun) {
      log('dry run: no rows written');
      return plan;
    }
    await applyPlan(client, plan, args);
    log('applied');
    return plan;
  } finally {
    if (client.end) await client.end();
  }
}

async function connect() {
  const { Client } = require('pg');
  const url = process.env.ADMIN_DATABASE_URL || process.env.DATABASE_URL || process.env.API_DATABASE_URL;
  if (!url) throw new Error('ADMIN_DATABASE_URL, DATABASE_URL, or API_DATABASE_URL must be set');
  const client = new Client({
    connectionString: url,
    ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  });
  await client.connect();
  return client;
}

module.exports = { parseDirectory, buildPlan, applyPlan, loadExisting, summarise, parseArgs, run };

if (require.main === module) {
  run(process.argv.slice(2), { createClient: connect }).catch((err) => {
    console.error(`seed_merchant_directory failed: ${err.message}`);
    process.exit(1);
  });
}
