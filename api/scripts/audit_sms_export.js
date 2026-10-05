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

function amountFromMessage(body) {
  const match = String(body || '').match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!match) return null;
  const amount = Number(match[1].replace(/,/g, ''));
  return Number.isFinite(amount) && amount > 0 ? amount : null;
}

function confidenceForMessage(body, parsed) {
  const text = String(body || '').toLowerCase();
  if (/\b(?:a\/?c\.?|account)\b[\s\S]{0,80}\bdebited\b/.test(text) && !/\bupi\b/.test(text)) {
    return 'ambiguous_account_debit';
  }
  if (parsed.fields.instrument === 'upi_bank' && !parsed.fields.merchant && !/\bupi\b/.test(text)) {
    return 'ambiguous_account_debit';
  }
  if (parsed.fields.instrument === 'upi_bank' && !parsed.fields.merchant) return 'needs_confirmation';
  return 'high_confidence_candidate';
}

function parseExportDate(value) {
  const text = String(value || '').trim();
  if (!text) return null;
  const parsed = new Date(text.replace(' ', 'T'));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function calendarDay(value) {
  if (!value) return 'unknown';
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
}

function calendarMonth(value) {
  if (!value) return 'unknown';
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}`;
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
  // Stable chronological order makes the report auditable: source duplicates,
  // same-day repeats, and month-boundary mistakes are visible in the order a
  // user would actually have received the alerts.
  messages.sort((a, b) => {
    const left = parseExportDate(a.dateTime)?.getTime() ?? Number.MAX_SAFE_INTEGER;
    const right = parseExportDate(b.dateTime)?.getTime() ?? Number.MAX_SAFE_INTEGER;
    return left - right;
  });

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
    monthConfidenceTotalsInrAfterSourceDedup: {},
    dayTotalsInrAfterSourceDedup: {},
    sameDayFingerprintCandidates: [],
    confidenceCountsAfterSourceDedup: {},
    confidenceTotalsInrAfterSourceDedup: {},
    autoCountableTotalsInrAfterSourceDedup: {},
    excludedAmbiguousAccountDebitRowsAfterSourceDedup: 0,
    excludedAmbiguousAccountDebitTotalInrAfterSourceDedup: 0,
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
      if (parsed.reason === 'ambiguous_account_debit' && !duplicate) {
        const amount = amountFromMessage(message.body);
        stats.excludedAmbiguousAccountDebitRowsAfterSourceDedup += 1;
        if (amount != null) {
          stats.excludedAmbiguousAccountDebitTotalInrAfterSourceDedup = Number(
            (stats.excludedAmbiguousAccountDebitTotalInrAfterSourceDedup + amount).toFixed(2)
          );
        }
      }
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
    const confidence = confidenceForMessage(message.body, parsed);
    parsedUnique.push({
      key,
      parsed,
      merchant,
      category,
      occurred,
      receivedAt: parseExportDate(message.dateTime),
      confidence,
    });
  }

  // The transaction date is authoritative for spend reporting. Receipt time
  // is only the deterministic tie-breaker for messages whose transaction
  // date is identical or absent. This prevents a day/month report from being
  // ordered by SMS export quirks.
  parsedUnique.sort((left, right) => {
    const leftDate = left.occurred?.getTime() ?? Number.MAX_SAFE_INTEGER;
    const rightDate = right.occurred?.getTime() ?? Number.MAX_SAFE_INTEGER;
    if (leftDate !== rightDate) return leftDate - rightDate;
    const leftReceived = left.receivedAt?.getTime() ?? Number.MAX_SAFE_INTEGER;
    const rightReceived = right.receivedAt?.getTime() ?? Number.MAX_SAFE_INTEGER;
    if (leftReceived !== rightReceived) return leftReceived - rightReceived;
    return left.key.localeCompare(right.key);
  });

  for (const entry of parsedUnique) {
    const amount = Number(entry.parsed.fields.amountInr);
    stats.parsedSpendRowsAfterSourceDedup += 1;
    stats.amountTotalInrAfterSourceDedup = Number((stats.amountTotalInrAfterSourceDedup + amount).toFixed(2));
    addAmount(stats.instrumentTotalsInrAfterSourceDedup, entry.parsed.fields.instrument || 'unknown', amount);
    stats.confidenceCountsAfterSourceDedup[entry.confidence] = (stats.confidenceCountsAfterSourceDedup[entry.confidence] || 0) + 1;
    addAmount(stats.confidenceTotalsInrAfterSourceDedup, entry.confidence, amount);
    if (entry.confidence === 'high_confidence_candidate') {
      addAmount(stats.autoCountableTotalsInrAfterSourceDedup, entry.parsed.fields.instrument || 'unknown', amount);
    }
    stats.categoryCountsAfterSourceDedup[entry.category] = (stats.categoryCountsAfterSourceDedup[entry.category] || 0) + 1;
    addAmount(stats.categoryTotalsInrAfterSourceDedup, entry.category, amount);
    const month = calendarMonth(entry.occurred);
    addAmount(stats.monthTotalsInrAfterSourceDedup, month, amount);
    const monthConfidence = stats.monthConfidenceTotalsInrAfterSourceDedup[month] || {};
    addAmount(monthConfidence, entry.confidence, amount);
    stats.monthConfidenceTotalsInrAfterSourceDedup[month] = monthConfidence;
    const day = calendarDay(entry.occurred);
    const dayRow = stats.dayTotalsInrAfterSourceDedup[day] || {
      totalInr: 0,
      txnCount: 0,
      byInstrument: {},
      byCategory: {},
    };
    dayRow.totalInr = Number((dayRow.totalInr + amount).toFixed(2));
    dayRow.txnCount += 1;
    addAmount(dayRow.byInstrument, entry.parsed.fields.instrument || 'unknown', amount);
    addAmount(dayRow.byCategory, entry.category, amount);
    stats.dayTotalsInrAfterSourceDedup[day] = dayRow;
    if (entry.category === 'other' && entry.merchant && stats.unknownMerchantExamples.length < 25) {
      stats.unknownMerchantExamples.push(entry.merchant);
    }
  }

  const fingerprintGroups = new Map();
  for (const entry of parsedUnique) {
    const day = calendarDay(entry.occurred);
    const merchant = normalizeMessagePart(entry.merchant).toLowerCase();
    // A merchant-bearing fingerprint is useful evidence. Empty-merchant
    // messages are intentionally not grouped because same-day equal amounts
    // can be legitimate purchases.
    if (!merchant) continue;
    const fingerprint = `${day}\u0000${entry.parsed.fields.instrument || 'unknown'}\u0000${entry.parsed.fields.amountInr}\u0000${merchant}`;
    const group = fingerprintGroups.get(fingerprint) || { day, instrument: entry.parsed.fields.instrument || 'unknown', amountInr: Number(entry.parsed.fields.amountInr), merchant, count: 0 };
    group.count += 1;
    fingerprintGroups.set(fingerprint, group);
  }
  stats.sameDayFingerprintCandidates = [...fingerprintGroups.values()]
    .filter((group) => group.count > 1)
    .sort((a, b) => (b.amountInr * b.count) - (a.amountInr * a.count))
    .slice(0, 50);

  // Arrays make the intended chronological order explicit to humans and to
  // any downstream audit tooling; object key order is not a reporting API.
  stats.monthTotalsChronological = Object.entries(stats.monthTotalsInrAfterSourceDedup)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([month, totalInr]) => ({ month, totalInr }));
  stats.dayTotalsChronological = Object.entries(stats.dayTotalsInrAfterSourceDedup)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([day, totals]) => ({ day, ...totals }));

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

