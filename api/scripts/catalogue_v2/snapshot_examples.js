#!/usr/bin/env node
'use strict';

// WP7 — snapshots of the v2 transform for the cards that have worked examples
// (plan §7 "Real cards", C6). For every db/fixtures/card_worked_examples/<slug>.json
// this runs exactly what the importer runs (CardPipeline record + override file
// + merchant directory → transformCardRecordV2) and writes the v2 wire card
// (C2 shape, ids built from local keys: `<slug>:rule:<source id>#<part>`,
// `<slug>:cap:<source id>`) to db/fixtures/catalogue_v2_cards/<slug>.json, plus
// the directory the feed would publish to _directory.json.
//
// The worked-example harnesses (api/test/card_worked_examples.test.js and
// packages/pandapay_domain/test/card_worked_examples_test.dart) run every
// engine-checkable example against these snapshots, so the CardPipeline repo
// is not needed to run the tests.
//
//   node api/scripts/catalogue_v2/snapshot_examples.js \
//     [--pipeline /path/to/CardPipeline] [--slug <source_slug>]... [--check]
//
// --check regenerates in memory and exits 1 if any snapshot on disk differs
// (stale after a loader, override, directory or CardPipeline change).
//
// Each snapshot records the hashes of its inputs. The tests compare the
// override and directory hashes with the files in this repo, so a stale
// snapshot fails even where CardPipeline isn't checked out.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { TRANSFORM_VERSION_V2, transformCardRecordV2 } = require('./transform');
const { DEFAULT_DIRECTORY_PATH, buildDirectoryIndex } = require('./directory');
const { DEFAULT_OVERRIDES_DIR, loadOverride, loadVerifiedSlugs } = require('./overrides');
const { loadDoneRecords } = require('./source');
const { toV2WireCard } = require('./wire');
const { extractVerifiedNetworkVariants, resolveNetwork } = require('../import_card_pipeline');

const REPO = path.resolve(__dirname, '../../..');
const DEFAULT_EXAMPLES_DIR = path.join(REPO, 'db/fixtures/card_worked_examples');
const DEFAULT_OUT_DIR = path.join(REPO, 'db/fixtures/catalogue_v2_cards');
const DEFAULT_PIPELINE = path.resolve(REPO, '../CardPipeline');
const DIRECTORY_FILE = '_directory.json';

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function fileSha256(file) {
  return fs.existsSync(file) ? sha256(fs.readFileSync(file)) : null;
}

function parseArgs(argv) {
  const args = {
    pipeline: process.env.CARDPIPELINE_DIR || DEFAULT_PIPELINE,
    examplesDir: DEFAULT_EXAMPLES_DIR,
    outDir: DEFAULT_OUT_DIR,
    directory: DEFAULT_DIRECTORY_PATH,
    overridesDir: DEFAULT_OVERRIDES_DIR,
    slugs: [],
    check: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--pipeline') args.pipeline = path.resolve(argv[++i]);
    else if (a === '--examples-dir') args.examplesDir = path.resolve(argv[++i]);
    else if (a === '--out-dir') args.outDir = path.resolve(argv[++i]);
    else if (a === '--directory') args.directory = path.resolve(argv[++i]);
    else if (a === '--overrides-dir') args.overridesDir = path.resolve(argv[++i]);
    else if (a === '--slug') args.slugs.push(argv[++i]);
    else if (a === '--check') args.check = true;
    else if (a === '--help' || a === '-h') args.help = true;
    else throw new Error(`unknown argument ${a}`);
  }
  return args;
}

function exampleSlugs(examplesDir) {
  return fs
    .readdirSync(examplesDir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(fs.readFileSync(path.join(examplesDir, f), 'utf8')).source_slug)
    .filter(Boolean)
    .sort();
}

/**
 * The D18j blocking flags for a card: what would stop it being `verified`
 * if it were listed in verified_cards.json (the transform reports them only
 * for listed cards, so ask it as if this one were).
 */
function blockingFlags(record, sourceSlug, { index, overrides }) {
  const t = transformCardRecordV2(record, { index, overrides, verifiedSlugs: new Set([sourceSlug]), sourceSlug });
  return t.coverage.verifiedBlockedBy || [];
}

/**
 * The snapshot for one card: the v2 wire card plus the hashes of every input
 * that shaped it. Pure apart from reading the override file.
 */
function buildSnapshot(record, sourceSlug, { directory, directoryText, overridesDir, verifiedSlugs, index }) {
  const overrides = loadOverride(sourceSlug, overridesDir);
  const t = transformCardRecordV2(record, {
    index: index || buildDirectoryIndex(directory),
    overrides,
    verifiedSlugs,
    sourceSlug,
  });
  // Network and UPI linkability as the importer writes them (the feed carries
  // the enum, never the raw research text).
  const cp = record?.card_product || {};
  const network = resolveNetwork(cp.network).network;
  const rupayVariant = extractVerifiedNetworkVariants(record).some((v) => v.network === 'rupay');
  const isUpiLinkable = cp.is_upi_linkable === true &&
    (cp.card_type == null || cp.card_type === 'credit') &&
    (network === 'rupay' || (network === 'unknown' && rupayVariant));
  const card = {
    ...toV2WireCard(t, { network, issuerSlug: cp.issuer_slug ?? null }),
    is_upi_linkable: isUpiLinkable,
  };
  return {
    generated_by: 'api/scripts/catalogue_v2/snapshot_examples.js',
    source_slug: sourceSlug,
    inputs: {
      transform_version: TRANSFORM_VERSION_V2,
      source_record_sha256: sha256(JSON.stringify(record)),
      override_sha256: fileSha256(path.join(overridesDir, `${sourceSlug}.json`)),
      directory_sha256: sha256(directoryText),
      verified: verifiedSlugs.has(sourceSlug),
    },
    // D18j: flags that keep this card from `verified` even when listed.
    blocking_flags: blockingFlags(record, sourceSlug, { index: index || buildDirectoryIndex(directory), overrides }),
    card,
  };
}

function render(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function run(args) {
  const directoryText = fs.readFileSync(args.directory, 'utf8');
  const directory = JSON.parse(directoryText);
  const index = buildDirectoryIndex(directory);
  const verifiedSlugs = loadVerifiedSlugs(args.overridesDir);
  const wanted = args.slugs.length ? args.slugs : exampleSlugs(args.examplesDir);
  const { records, problems } = loadDoneRecords(args.pipeline);
  const bySlug = new Map();
  for (const r of records) if (!bySlug.has(r.sourceSlug)) bySlug.set(r.sourceSlug, r.record);

  const outputs = new Map();
  const missing = [];
  for (const slug of wanted) {
    const record = bySlug.get(slug);
    if (!record) {
      missing.push(slug);
      continue;
    }
    const snap = buildSnapshot(record, slug, { directory, directoryText, overridesDir: args.overridesDir, verifiedSlugs, index });
    outputs.set(`${slug}.json`, render(snap));
  }
  outputs.set(DIRECTORY_FILE, render({
    generated_by: 'api/scripts/catalogue_v2/snapshot_examples.js',
    directory_sha256: sha256(directoryText),
    merchants: directory.merchants || [],
    platforms: directory.platforms || [],
  }));

  for (const p of problems) console.warn(`  CardPipeline ${p.id}: ${p.reason}`);
  for (const slug of missing) console.warn(`  no done CardPipeline record for ${slug}`);

  if (args.check) {
    const stale = [];
    for (const [name, text] of outputs) {
      const file = path.join(args.outDir, name);
      if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== text) stale.push(name);
    }
    if (stale.length || missing.length) {
      console.error(`Stale or missing snapshots: ${[...stale, ...missing].join(', ')}`);
      process.exitCode = 1;
    } else {
      console.log(`All ${outputs.size} snapshot file(s) are current.`);
    }
    return { outputs, stale, missing };
  }

  fs.mkdirSync(args.outDir, { recursive: true });
  for (const [name, text] of outputs) fs.writeFileSync(path.join(args.outDir, name), text);
  console.log(`Wrote ${outputs.size} file(s) to ${path.relative(process.cwd(), args.outDir) || args.outDir}`);
  if (missing.length) process.exitCode = 1;
  return { outputs, stale: [], missing };
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: node api/scripts/catalogue_v2/snapshot_examples.js [--pipeline <CardPipeline root>] [--slug <source_slug>]... [--check]');
  } else {
    run(args);
  }
}

module.exports = { DIRECTORY_FILE, buildSnapshot, fileSha256, run, sha256 };
