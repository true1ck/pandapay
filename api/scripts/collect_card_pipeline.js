#!/usr/bin/env node
/**
 * Stage 1 of the card-catalogue sync: gather CardPipeline's finished
 * extractions into the (all-collected.json + all-collected-index.json) pair
 * that import_card_pipeline.js consumes.
 *
 * Usage:
 *   node api/scripts/collect_card_pipeline.js \
 *     [--pipeline /path/to/CardPipeline] \
 *     [--out api/scripts/.staging] \
 *     [--include-unlisted]
 *
 * Normally you don't call this directly — api/scripts/sync_card_catalogue.sh
 * runs it and then hands the output straight to the importer.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * WHY NOT JUST RUN CardPipeline's OWN `node src/cli.js export`?
 * ─────────────────────────────────────────────────────────────────────────
 * That command exists and produces the same two filenames, and for a long
 * time it was the intended input. Two things make it the wrong source now:
 *
 * 1. IT IGNORES THE CHECKLIST. `collectAll()` in CardPipeline's store.js
 *    walks every run directory in ascending run-id order and keeps the last
 *    record it sees per card id. `data/checklist.json` is the project's own
 *    stated authority ("data/checklist.json is the authoritative queue and
 *    status file" — EXTRACTION_NOTES.md), it records WHICH run's output was
 *    accepted for each card, and it is where a human requeue is recorded.
 *    Two real cards were requeued exactly that way after an audit found one
 *    had captured an unrelated Oracle Cloud config dump and another had
 *    extracted SBI Card PULSE under SBI Card PRIME's name. Last-run-wins
 *    happens to agree with the checklist today; it is not guaranteed to,
 *    and the case where it disagrees is precisely the case where a human
 *    already said "not this one".
 *
 * 2. IT REQUIRES CardPipeline TO BE RUNNABLE. Its export is ESM with
 *    dependencies; this reads JSON off disk with the Node standard library.
 *    Syncing the catalogue should not depend on a sibling project's
 *    node_modules being installed and healthy.
 *
 * The output is byte-for-byte the same SHAPE the importer already expects,
 * so nothing downstream had to change to accommodate this.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * WHAT GOES IN THE INDEX, AND WHY IT MATTERS
 * ─────────────────────────────────────────────────────────────────────────
 * all-collected-index.json is positionally aligned with all-collected.json
 * and carries the checklist's EXPECTED card_name for each row — not the name
 * the extraction produced. The importer's nameLooksMismatched() check
 * compares the two, which is what catches an extraction that wandered onto a
 * different card. Feeding it the record's own name would make the check
 * compare a value against itself and always pass, silently disabling it.
 */

'use strict';

const fs = require('fs');
const path = require('path');

// The repo and CardPipeline are siblings under .../PandaPath/. Resolved from
// __dirname rather than process.cwd() so the default works no matter which
// directory the script is invoked from.
const DEFAULT_PIPELINE = path.resolve(__dirname, '../../../CardPipeline');
const DEFAULT_OUT = path.resolve(__dirname, '.staging');

function parseArgs(argv) {
  const args = { pipeline: DEFAULT_PIPELINE, out: DEFAULT_OUT, includeUnlisted: false };
  const takeValue = (flag, index) => {
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      console.error(`${flag} requires a value`);
      process.exit(1);
    }
    return value;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--pipeline') args.pipeline = path.resolve(takeValue(a, i++));
    else if (a === '--out') args.out = path.resolve(takeValue(a, i++));
    else if (a === '--include-unlisted') args.includeUnlisted = true;
    else if (a === '--help' || a === '-h') args.help = true;
    else {
      console.error(`Unknown argument: ${a}`);
      process.exit(1);
    }
  }
  return args;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Resolve the item file for one checklist row.
 *
 * `output_file` is an absolute path recorded on the machine that ran the
 * extraction. It is correct there and wrong anywhere else, so the
 * conventional layout (results/<run_id>/items/<id>.json) is tried as a
 * fallback before giving up — that keeps the collector working if the
 * CardPipeline directory is moved, copied to another machine, or passed a
 * --pipeline path that isn't where the run happened.
 */
function resolveItemFile(pipelineRoot, row) {
  if (row.output_file && fs.existsSync(row.output_file)) return row.output_file;
  if (row.run_id && row.id) {
    const byConvention = path.join(pipelineRoot, 'results', row.run_id, 'items', `${row.id}.json`);
    if (fs.existsSync(byConvention)) return byConvention;
  }
  return null;
}

/**
 * Every item file on disk, newest run last, keyed by card id.
 *
 * Only consulted for --include-unlisted, and for reporting how far ahead of
 * the checklist the run directories are.
 */
function scanRunDirs(pipelineRoot) {
  const resultsRoot = path.join(pipelineRoot, 'results');
  const byCard = new Map();
  let runIds = [];
  try {
    runIds = fs
      .readdirSync(resultsRoot, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name)
      .sort(); // ascending: a later run supersedes an earlier one
  } catch {
    return byCard;
  }
  for (const runId of runIds) {
    const itemsDir = path.join(resultsRoot, runId, 'items');
    let files = [];
    try {
      files = fs.readdirSync(itemsDir).filter((f) => f.endsWith('.json'));
    } catch {
      continue;
    }
    for (const f of files) {
      const body = readJson(path.join(itemsDir, f));
      if (body && body.ok === true && body.final && typeof body.final === 'object') {
        byCard.set(body.id, { ...body, runId });
      }
    }
  }
  return byCard;
}

function collect(args) {
  const report = {
    pipeline: args.pipeline,
    collectedAt: new Date().toISOString(),
    checklistCounts: {},
    collected: 0,
    unresolved: [],
    notOk: [],
    idMismatches: [],
    duplicateChecklistIds: [],
    unlistedIncluded: [],
    unlistedAvailable: 0,
    warnings: [],
  };

  const checklistPath = path.join(args.pipeline, 'data', 'checklist.json');
  const checklist = readJson(checklistPath);
  if (!checklist || !Array.isArray(checklist.rows)) {
    console.error(
      `No usable checklist at ${checklistPath}. ` +
        'This is CardPipeline\'s authoritative queue file; without it there is no ' +
        'record of which extraction was accepted for which card. Pass --pipeline ' +
        'if CardPipeline lives somewhere else.'
    );
    process.exit(1);
  }

  for (const row of checklist.rows) {
    report.checklistCounts[row.status] = (report.checklistCounts[row.status] || 0) + 1;
  }

  const records = [];
  const index = [];
  const seenIds = new Set();

  for (const row of checklist.rows) {
    if (row.status !== 'done') continue;

    if (seenIds.has(row.id)) {
      report.duplicateChecklistIds.push({ id: row.id, card_name: row.card_name });
      continue;
    }

    const file = resolveItemFile(args.pipeline, row);
    if (!file) {
      report.unresolved.push({ id: row.id, card_name: row.card_name, run_id: row.run_id });
      continue;
    }
    const body = readJson(file);
    if (!body) {
      report.unresolved.push({ id: row.id, card_name: row.card_name, reason: 'unreadable JSON', file });
      continue;
    }
    // A row can be marked done while its saved record carries ok:false or no
    // final payload (an interrupted stage 3, for instance). Nothing to import
    // from that; reported rather than dropped silently.
    if (body.ok !== true || !body.final || typeof body.final !== 'object') {
      report.notOk.push({ id: row.id, card_name: row.card_name, file, ok: body.ok === true });
      continue;
    }
    if (body.id && body.id !== row.id) {
      report.idMismatches.push({
        expected_id: row.id,
        actual_id: body.id,
        card_name: row.card_name,
        file,
      });
      continue;
    }

    seenIds.add(row.id);
    records.push(body.final);
    index.push({
      id: row.id,
      // The checklist's expectation, deliberately — see the header comment.
      card_name: row.card_name,
      issuer: row.issuer,
      runId: row.run_id || body.runId || null,
      finishedAt: body.finishedAt || row.updated_at || null,
    });
  }

  // Everything the run directories hold that the checklist hasn't accepted.
  // Off by default: an item file for a card the queue still calls in_progress
  // is, by the queue's own definition, not a finished result.
  const onDisk = scanRunDirs(args.pipeline);
  for (const [id, body] of onDisk) {
    if (seenIds.has(id)) continue;
    report.unlistedAvailable++;
    if (!args.includeUnlisted) continue;
    seenIds.add(id);
    records.push(body.final);
    index.push({
      id,
      card_name: body.card_name || null,
      issuer: body.issuer || null,
      runId: body.runId || null,
      finishedAt: body.finishedAt || null,
    });
    report.unlistedIncluded.push({ id, card_name: body.card_name });
  }
  if (args.includeUnlisted && report.unlistedIncluded.length) {
    report.warnings.push(
      `--include-unlisted pulled in ${report.unlistedIncluded.length} record(s) the checklist has not ` +
        'marked done. Their index entries carry the extraction\'s own card_name, so the importer\'s ' +
        'name-mismatch check cannot judge them independently.'
    );
  }

  report.collected = records.length;

  fs.mkdirSync(args.out, { recursive: true });
  const collectedPath = path.join(args.out, 'all-collected.json');
  const indexPath = path.join(args.out, 'all-collected-index.json');
  const reportPath = path.join(args.out, 'collect-report.json');
  // Publish the three-file snapshot atomically, one file at a time. If the
  // extractor or this collector is interrupted mid-write, the importer sees
  // either the previous complete JSON or the new complete JSON — never a
  // half-written array.
  for (const [target, value] of [
    [collectedPath, records],
    [indexPath, index],
    [reportPath, report],
  ]) {
    const temporary = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2));
    fs.renameSync(temporary, target);
  }

  return { report, collectedPath, indexPath, reportPath };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(
      'Usage: node collect_card_pipeline.js [--pipeline <CardPipeline root>] ' +
        '[--out <dir>] [--include-unlisted]'
    );
    return;
  }
  if (!fs.existsSync(args.pipeline)) {
    console.error(`--pipeline path does not exist: ${args.pipeline}`);
    process.exit(1);
  }

  const { report, collectedPath, indexPath, reportPath } = collect(args);

  console.log(`Pipeline:  ${report.pipeline}`);
  console.log(
    `Checklist: ${Object.entries(report.checklistCounts)
      .map(([k, v]) => `${v} ${k}`)
      .join(', ')}`
  );
  console.log(`Collected: ${report.collected} record(s)`);
  if (report.unresolved.length) {
    console.log(`  ${report.unresolved.length} done row(s) with no readable output file`);
  }
  if (report.notOk.length) {
    console.log(`  ${report.notOk.length} done row(s) whose saved record has no final payload`);
  }
  if (report.idMismatches.length) {
    console.log(`  ${report.idMismatches.length} done row(s) whose output belongs to a different checklist id`);
  }
  if (report.duplicateChecklistIds.length) {
    console.log(`  ${report.duplicateChecklistIds.length} duplicate done checklist id(s)`);
  }
  if (!args.includeUnlisted && report.unlistedAvailable) {
    console.log(
      `  ${report.unlistedAvailable} extracted record(s) on disk the checklist has not marked done ` +
        '(use --include-unlisted to take them anyway)'
    );
  }
  console.log(`\nWrote:\n  ${collectedPath}\n  ${indexPath}\n  ${reportPath}`);

  if (
    report.unresolved.length ||
    report.notOk.length ||
    report.idMismatches.length ||
    report.duplicateChecklistIds.length
  ) {
    console.error('\nCollection is incomplete or ambiguous; refusing to hand this snapshot to the importer.');
    process.exitCode = 1;
  }
}

if (require.main === module) main();

module.exports = { collect, resolveItemFile, scanRunDirs };
