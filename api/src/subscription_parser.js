const { extractVpa } = require('./merchant_category');
const { isUsableSubscriptionName } = require('./recurring');

// This parser is intentionally narrower than the spend parser. A word such
// as "autopay" in a bill reminder is not proof that a subscription exists;
// the message must describe a mandate being created, registered, activated,
// approved, or confirmed.
const LIFECYCLE = /\b(?:created|registered|activated|approved|confirmed|enabled|set\s+up|initiated|accepted)\b/i;
const MANDATE = /\b(?:e[-\s]?mandate|emandate|standing\s+instruction|recurring\s+(?:payment|debit)|subscription|auto[-\s]?pay|autopay)\b/i;
const NEGATIVE = /\b(?:otp|verification\s+code|payment\s+due|amount\s+due|minimum\s+due|declined|failed|reversed|refund(?:ed)?|cancel(?:led|ed)?|revoked|stopped)\b/i;

function numberAfterCurrency(body) {
  const match = String(body || '').match(
    /(?:₹|\bINR\b|\bRS\.?)(?:\s*[:.]?\s*)([0-9][0-9,]*(?:\.\d{1,2})?)/i,
  );
  if (!match) return null;
  const value = Number(match[1].replace(/,/g, ''));
  return Number.isFinite(value) && value > 0 ? value : null;
}

function cadenceDays(body) {
  const text = String(body || '').toLowerCase();
  if (/weekly|every\s+week/.test(text)) return 7;
  if (/fortnight|every\s+two\s+weeks/.test(text)) return 14;
  if (/quarterly|every\s+quarter|three\s+months/.test(text)) return 91;
  if (/half[-\s]?yearly|six\s+months/.test(text)) return 182;
  if (/yearly|annual|every\s+year|12\s+months/.test(text)) return 365;
  if (/monthly|every\s+month|30\s+days?/.test(text)) return 30;
  return null;
}

function merchantFromBody(body) {
  const text = String(body || '').replace(/\s+/g, ' ').trim();
  const afterKeyword = text.match(
    /\b(?:for|to|at|with|towards?|merchant)\s+([A-Za-z0-9][A-Za-z0-9 ._&@'/-]{1,80}?)(?=\s+(?:has|is|was|of|for|amount|maximum|every|monthly|weekly|quarterly|yearly|on|from|via|using|under|valid|reference|ref|mandate|upi)\b|\s*[,.;]|$)/i,
  );
  if (afterKeyword) return afterKeyword[1].trim();

  // Many UPI mandate alerts omit a prose merchant but include a VPA.
  const vpa = extractVpa(text);
  if (vpa) return vpa;

  // Keep this fallback deliberately small and high-signal. It is only used
  // when a well-known service is named elsewhere in the alert.
  const known = text.match(/\b(?:chatgpt|openai|youtube|amazon\s+prime|prime\s+video|netflix|spotify|hotstar|google\s+one|swiggy|zomato|starbucks|reliance)\b/i);
  return known ? known[0] : null;
}

function mandateReference(body) {
  const match = String(body || '').match(
    /\b(?:mandate|instruction|umrn|reference|ref(?:erence)?(?:\s+no)?|txn(?:\s+id)?)\s*[:#-]?\s*([A-Za-z0-9-]{6,})\b/i,
  );
  return match ? match[1] : null;
}

function parseSubscriptionMandate(sms) {
  const body = String(sms?.body || '').replace(/\s+/g, ' ').trim();
  if (!body) return { ok: false, reason: 'empty_body' };
  if (body.length > 20000) return { ok: false, reason: 'body_too_long' };
  if (NEGATIVE.test(body)) return { ok: false, reason: 'non_mandate_alert' };
  if (!MANDATE.test(body) || !LIFECYCLE.test(body)) return { ok: false, reason: 'no_mandate_match' };

  const merchant = merchantFromBody(body);
  if (!merchant) return { ok: false, reason: 'mandate_merchant_missing' };
  if (!isUsableSubscriptionName(merchant)) {
    return { ok: false, reason: 'mandate_merchant_invalid' };
  }

  const lower = body.toLowerCase();
  const instrument = /\b(?:upi|vpa|e[-\s]?mandate|emandate)\b/.test(lower)
    ? 'upi_bank'
    : /\b(?:credit|debit)\s+card\b/.test(lower)
      ? 'card'
      : 'unknown';
  const last4Match = body.match(/\b(?:card|account|a\/?c\.?)\b[\s\S]{0,50}?(?:ending(?:\s+with)?|x{2,}|\*{2,}|last\s*4)\D{0,5}(\d{4})\b/i);

  return {
    ok: true,
    fields: {
      merchant,
      amountInr: numberAfterCurrency(body),
      cadenceDays: cadenceDays(body),
      instrument,
      ...(last4Match ? { last4: last4Match[1] } : {}),
      ...(extractVpa(body) ? { vpa: extractVpa(body) } : {}),
      ...(mandateReference(body) ? { reference: mandateReference(body) } : {}),
    },
  };
}

module.exports = { parseSubscriptionMandate };
