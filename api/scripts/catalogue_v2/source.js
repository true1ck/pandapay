'use strict';

// Reading CardPipeline research records without a database (the loader's
// --transform-only mode and the tests).
//
// A saved item file wraps the record: `final` is the accepted payload (after
// fact-checking); `original` is the pre-check extraction, used only when no
// `final` exists. Row selection follows collect_card_pipeline.js: checklist
// rows with status "done", resolved through its resolveItemFile.

const fs = require('fs');
const path = require('path');
const { resolveItemFile } = require('../collect_card_pipeline');

function unwrapItem(body) {
  if (!body || typeof body !== 'object') return { record: null, from: null };
  if (body.card_product && typeof body.card_product === 'object') return { record: body, from: 'bare' };
  if (body.ok === false) return { record: null, from: null };
  if (body.final && typeof body.final === 'object') return { record: body.final, from: 'final' };
  if (body.original && typeof body.original === 'object') return { record: body.original, from: 'original' };
  return { record: null, from: null };
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Every checklist row marked done, unwrapped.
 * @returns {{records: {id, sourceSlug, cardName, issuer, runId, from, record}[], problems: object[]}}
 */
function loadDoneRecords(pipelineRoot) {
  const checklist = readJson(path.join(pipelineRoot, 'data', 'checklist.json'));
  if (!checklist || !Array.isArray(checklist.rows)) {
    throw new Error(`No usable checklist at ${path.join(pipelineRoot, 'data', 'checklist.json')}`);
  }
  const records = [];
  const problems = [];
  const seen = new Set();
  for (const row of checklist.rows) {
    if (row.status !== 'done' || seen.has(row.id)) continue;
    seen.add(row.id);
    const relative = row.output_file && !path.isAbsolute(row.output_file)
      ? { ...row, output_file: path.join(pipelineRoot, row.output_file) }
      : row;
    const file = resolveItemFile(pipelineRoot, relative);
    if (!file) {
      problems.push({ id: row.id, reason: 'no readable output file' });
      continue;
    }
    const { record, from } = unwrapItem(readJson(file));
    if (!record) {
      problems.push({ id: row.id, reason: 'no final or original payload' });
      continue;
    }
    records.push({
      id: row.id,
      sourceSlug: row.source_slug || record?.card_product?.slug || row.id,
      cardName: row.card_name || null,
      issuer: row.issuer || null,
      runId: row.run_id || null,
      from,
      record,
    });
  }
  return { records, problems };
}

module.exports = { loadDoneRecords, unwrapItem };
