/**
 * CSV writing for the spend-report export.
 *
 * Small, but two of the rules here are the difference between a usable file
 * and a corrupt or dangerous one, and both are easy to leave out.
 */

/**
 * Escapes one CSV field per RFC 4180, with a formula-injection guard.
 *
 * QUOTING: anything containing a comma, a quote or a newline is quoted and
 * embedded quotes are doubled. Merchant names are free text taken from bank
 * messages and regularly contain commas; an unquoted one shifts every later
 * column on that row, which is the kind of corruption nobody notices until
 * they have already filed the numbers somewhere.
 *
 * FORMULA INJECTION: a field starting with `=`, `+`, `-`, `@`, tab or
 * carriage return is prefixed with a single quote. Excel, LibreOffice and
 * Google Sheets all treat those as the start of a formula, so a merchant
 * string like `=cmd|'/c calc'!A1` becomes an executable cell the moment the
 * file is opened. The merchant string arrives from SMS and email we do not
 * control, so this is a real path from an attacker-influenced field to code
 * execution on the user's machine — not a theoretical one.
 */
function csvField(value) {
  if (value === null || value === undefined) return '';
  let text = String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  if (/[",\n\r]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
  return text;
}

/** One CSV row from an array of values. */
function csvRow(values) {
  return values.map(csvField).join(',');
}

/**
 * A complete CSV document, with a UTF-8 BOM.
 *
 * The BOM is there for Excel on Windows, which otherwise reads the file as
 * the local ANSI codepage and renders ₹ and non-ASCII merchant names as
 * mojibake. Every other reader ignores it.
 */
function csvDocument(header, rows) {
  const lines = [csvRow(header), ...rows.map(csvRow)];
  return `﻿${lines.join('\n')}\n`;
}

module.exports = { csvField, csvRow, csvDocument };
