#!/usr/bin/env node

/**
 * Offline SMS-export audit. This never connects to the API or database.
 *
 * Usage:
 *   node scripts/audit_sms_export.js "C:\\path\\export.csv"
 *
 * It deliberately deduplicates by the same sender + normalized body identity
 * used by the live import path, so the report distinguishes exporter repeats
 * from genuine spending observations.
 */

const fs = require('node:fs');
const path = require('node:path');
const { parseSmsAgainstPatterns, parseTransactionDate } = require('../src/sms_parser');
const { inferBuiltinCategory } = require('../src/merchant_category');

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;

  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (quoted) {
      if (char === '"' && text[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (char === '"') {
        quoted = false;
      } else {
        field += char;
      }
    } else if (char === '"' && field.length === 0) {
      quoted = true;
    } else if (char === ',') {
      row.push(field);
      field = '';
    } else if (char === '\n') {
      row.push(field.endsWith('\r') ? field.slice(0, -1) : field);
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += char;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function normalizeMessagePart(value) {
  return String(value || '').replace(/\r\n?/g, '\n').replace(/\s+/g, ' ').trim();
}

function sourceIdentity(sender, body) {
  return `${normalizeMessagePart(sender).toUpperCase()}\u0000${normalizeMessagePart(body)}`;
}

function addAmount(map, key, amount) {
  map[key] = Number(((map[key] || 0) + amount).toFixed(2));
}

function parseExportDate(value) {
  const text = String(value || '').trim();
  if (!text) return null;
  const parsed = new Date(text.replace(' ', 'T'));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function audit(fileName) {
  const content = fs.readFileSync(fileName, 'utf8');
  const rows = parseCsv(content);
  const headerIndex = rows.findIndex((row) => row[0] === 'DateTime' && row.includes('Content'));
  if (headerIndex < 0) throw new Error('CSV header DateTime/Content not found');

  const header = rows[headerIndex];
  const index = Object.fromEntries(header.map((name, position) => [name, position]));
  const messages = rows.slice(headerIndex + 1)
    .filter((row) => row.length > 1 && row[index.Content] !== undefined)
    .map((row) => ({
      dateTime: row[index.DateTime] || '',
      sender: row[index.Contact] || row[index.Phone] || '',
      body: row[index.Content] || '',
    }));

  const seen = new Set();
  const stats = {
    file: path.resolve(fileName),
    headerAtRow: headerIndex + 1,
    fileRows: messages.length,
    exactDuplicateRows: 0,
    uniqueSourceRows: 0,
    parsedSpendRows: 0,
    parsedSpendRowsAfterSourceDedup: 0,
    amountTotalInr: 0,
    amountTotalInrAfterSourceDedup: 0,
    instrumentTotalsInr: {},
    instrumentTotalsInrAfterSourceDedup: {},
    categoryCountsAfterSourceDedup: {},
    categoryTotalsInrAfterSourceDedup: {},
    monthTotalsInrAfterSourceDedup: {},
    failureReasons: {},
    unknownMerchantExamples: [],
  };

  const parsedUnique = [];
  for (const message of messages) {
    const key = sourceIdentity(message.sender, message.body);
    const duplicate = seen.has(key);
    if (duplicate) stats.exactDuplicateRows += 1;
    else {
      seen.add(key);
      stats.uniqueSourceRows += 1;
    }

    const parsed = parseSmsAgainstPatterns([], message);
    if (!parsed.ok) {
      stats.failureReasons[parsed.reason] = (stats.failureReasons[parsed.reason] || 0) + 1;
      continue;
    }

    const amount = Number(parsed.fields.amountInr);
    stats.parsedSpendRows += 1;
    stats.amountTotalInr = Number((stats.amountTotalInr + amount).toFixed(2));
    addAmount(stats.instrumentTotalsInr, parsed.fields.instrument || 'unknown', amount);
    // The first occurrence is the only one eligible for the live source-key
    // identity; repeats are still included in the raw audit totals above.
    if (duplicate) continue;
    const merchant = parsed.fields.merchant || '';
    const category = inferBuiltinCategory(merchant)?.slug || 'other';
    const occurred = parseTransactionDate(parsed.fields.date) || parseExportDate(message.dateTime);
    parsedUnique.push({ key, parsed, merchant, category, occurred });
  }

  for (const entry of parsedUnique) {
    const amount = Number(entry.parsed.fields.amountInr);
    stats.parsedSpendRowsAfterSourceDedup += 1;
    stats.amountTotalInrAfterSourceDedup = Number((stats.amountTotalInrAfterSourceDedup + amount).toFixed(2));
    addAmount(stats.instrumentTotalsInrAfterSourceDedup, entry.parsed.fields.instrument || 'unknown', amount);
    stats.categoryCountsAfterSourceDedup[entry.category] = (stats.categoryCountsAfterSourceDedup[entry.category] || 0) + 1;
    addAmount(stats.categoryTotalsInrAfterSourceDedup, entry.category, amount);
    const month = entry.occurred
      ? `${entry.occurred.getFullYear()}-${String(entry.occurred.getMonth() + 1).padStart(2, '0')}`
      : 'unknown';
    addAmount(stats.monthTotalsInrAfterSourceDedup, month, amount);
    if (entry.category === 'other' && entry.merchant && stats.unknownMerchantExamples.length < 25) {
      stats.unknownMerchantExamples.push(entry.merchant);
    }
  }

  stats.amountTotalDifferenceAfterDedup = Number(
    (stats.amountTotalInrAfterSourceDedup - Object.values(stats.categoryTotalsInrAfterSourceDedup)
      .reduce((sum, value) => sum + value, 0)).toFixed(2)
  );
  return stats;
}

const fileName = process.argv[2];
if (!fileName) {
  console.error('Usage: node scripts/audit_sms_export.js <export.csv>');
  process.exitCode = 2;
} else {
  console.log(JSON.stringify(audit(fileName), null, 2));
}

