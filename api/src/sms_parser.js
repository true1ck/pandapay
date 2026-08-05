/**
 * UA-5.3 — SMS-to-transaction-fields parsing engine.
 *
 * Pure function: given a `parser_patterns` row (regex + field_map) and a raw
 * SMS body, extract structured transaction fields — or return a "no match"
 * result. Never fabricates a guess: any regex miss or unparseable numeric
 * field is a failure, not a best-effort partial transaction.
 *
 * field_map is jsonb like {"amount": 1, "merchant": 2, "last4": 3, "date": 4}
 * mapping a known field name -> capture group index (1-based, matching JS
 * regex exec() group indexing) in `regex`. Only "amount", "merchant",
 * "last4", "date" are recognized fields; anything else in field_map is
 * ignored rather than erroring, so a pattern can carry forward-compatible
 * extra keys without breaking older parser code.
 */

const KNOWN_FIELDS = ['amount', 'merchant', 'last4', 'date'];

/**
 * Does `sender` match a pattern's `sender_pattern`? sender_pattern is a
 * plain substring/prefix match (e.g. 'HDFCBK' matching 'VM-HDFCBK-S' or
 * 'AD-HDFCBK'), NOT a regex — these values come from admin-entered short
 * alphanumeric SMS sender IDs, not attacker-controlled input, but treating
 * them as literal text (not compiled as regex) avoids any surprise from a
 * stray regex metacharacter in an admin's typo.
 */
function senderMatches(senderPattern, sender) {
  if (!senderPattern) return true; // no restriction configured
  if (!sender) return false;
  return sender.toUpperCase().includes(senderPattern.toUpperCase());
}

/**
 * Parse one SMS body against one parser_patterns row.
 *
 * @param {{regex: string, field_map: object, sender_pattern?: string}} pattern
 * @param {{body: string, sender?: string}} sms
 * @returns {{ok: true, fields: {amountInr?: number, merchant?: string, last4?: string, date?: string}}
 *          | {ok: false, reason: string}}
 */
function parseSms(pattern, sms) {
  if (!pattern || typeof pattern.regex !== 'string' || !pattern.regex) {
    return { ok: false, reason: 'invalid_pattern' };
  }
  if (!sms || typeof sms.body !== 'string' || !sms.body.trim()) {
    return { ok: false, reason: 'empty_body' };
  }
  if (!senderMatches(pattern.sender_pattern, sms.sender)) {
    return { ok: false, reason: 'sender_mismatch' };
  }

  let re;
  try {
    re = new RegExp(pattern.regex);
  } catch (err) {
    return { ok: false, reason: 'invalid_regex' };
  }

  const match = re.exec(sms.body);
  if (!match) {
    return { ok: false, reason: 'no_regex_match' };
  }

  const fieldMap = pattern.field_map || {};
  const fields = {};

  for (const fieldName of KNOWN_FIELDS) {
    const groupIndex = fieldMap[fieldName];
    if (groupIndex === undefined || groupIndex === null) continue;
    const raw = match[groupIndex];
    if (raw === undefined) {
      // field_map points at a group the regex doesn't have / didn't
      // capture in this instance — a malformed pattern, not a partial win.
      return { ok: false, reason: `missing_capture_for_${fieldName}` };
    }

    if (fieldName === 'amount') {
      const cleaned = raw.replace(/,/g, '').trim();
      const amount = Number(cleaned);
      if (!Number.isFinite(amount) || amount <= 0) {
        return { ok: false, reason: 'unparseable_amount' };
      }
      fields.amountInr = amount;
    } else if (fieldName === 'last4') {
      const digits = raw.trim();
      if (!/^\d{4}$/.test(digits)) {
        return { ok: false, reason: 'unparseable_last4' };
      }
      fields.last4 = digits;
    } else if (fieldName === 'date') {
      fields.date = raw.trim();
    } else if (fieldName === 'merchant') {
      const merchant = raw.trim();
      if (!merchant) {
        return { ok: false, reason: 'unparseable_merchant' };
      }
      fields.merchant = merchant;
    }
  }

  if (fields.amountInr === undefined) {
    // Amount is the one field every downstream consumer (cap/milestone/
    // points math in POST /transactions) requires — a pattern that doesn't
    // even map "amount" is not usable, regardless of what else it captured.
    return { ok: false, reason: 'no_amount_field_mapped' };
  }

  return { ok: true, fields };
}

/**
 * Try a raw SMS against a list of candidate parser_patterns (already
 * filtered to `channel = 'sms', is_active = true` by the caller's SQL — this
 * function doesn't touch the DB), highest-priority first. `patterns` should
 * be pre-sorted by whatever the caller considers priority (e.g. version
 * DESC); this just returns the first one that matches, or a failure
 * carrying the last-tried reason if none did.
 *
 * @param {Array<object>} patterns
 * @param {{body: string, sender?: string}} sms
 */
function parseSmsAgainstPatterns(patterns, sms) {
  let lastReason = 'no_patterns_configured';
  for (const pattern of patterns) {
    const result = parseSms(pattern, sms);
    if (result.ok) return { ...result, patternId: pattern.id };
    lastReason = result.reason;
  }
  return { ok: false, reason: lastReason };
}

/**
 * Build the `parser_failures.redacted_shape` value from a raw SMS body:
 * digits -> '#', then collapse letters run of length>=2 to 'X' to avoid
 * leaking merchant/name text, per the table's
 * `redacted_shape_has_no_digits` CHECK and its "no raw content" intent.
 */
function redactSmsShape(body) {
  return String(body || '')
    .replace(/\d/g, '#')
    .replace(/[A-Za-z]{2,}/g, 'X');
}

module.exports = { parseSms, parseSmsAgainstPatterns, senderMatches, redactSmsShape, KNOWN_FIELDS };
