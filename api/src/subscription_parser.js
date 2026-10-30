const { extractVpa } = require('./merchant_category');
const {
  isUsableSubscriptionName,
  isInvestmentFundingMessage,
  isInvestmentMandateMessage,
} = require('./recurring');

// This parser handles subscription e-mandates, Standing Instructions (SI),
// and AutoPay notifications across Indian issuers (Axis, HDFC, ICICI, SBI, Kotak, UPI).
const MANDATE = /\b(?:(?:upi|e)[-\s]?mandate|emandate|mandate|standing\s+instruction|recurring\s+(?:payment|debit|charge)|subscription|auto[-\s]?pay|autopay|si\b)\b/i;
const ACTIVATION = /\b(?:created|registered|activat(?:ed|ion)|approved|confirmed|enabled|set\s+up|initiated|accepted|success(?:ful)?)\b/i;
const CANCELLATION = /\b(?:cancel(?:led|ed)?|revoked|stopped|de-?activat(?:ed|ion)|disabled|terminated)\b/i;
const NON_MANDATE = /\b(?:otp|verification\s+code|payment\s+due|amount\s+due|minimum\s+due|declined|failed|reversed|refund(?:ed)?)\b/i;

function extractMandateAmount(body) {
  const text = String(body || '');

  // 1. Look for explicit max limit / mandate amount / monthly limit / up to
  const limitMatch = text.match(
    /(?:max(?:imum)?\s*(?:limit|amount|amt)|mandate\s*(?:limit|amount|amt)|monthly\s*(?:limit|amount|amt)|amount\s*up\s*to|max\s*amount|upto|up\s*to)\s*[:.-]?\s*(?:₹|\bINR\b|\bRS\.?)\s*([0-9][0-9,]*(?:\.\d{1,2})?)/i
  ) || text.match(
    /(?:₹|\bINR\b|\bRS\.?)\s*[:.-]?\s*([0-9][0-9,]*(?:\.\d{1,2})?)\s*(?:max(?:imum)?\s*(?:limit|amount|amt)|monthly|recurring|per\s+month)/i
  );

  if (limitMatch) {
    const val = Number(limitMatch[1].replace(/,/g, ''));
    if (Number.isFinite(val) && val > 0) return val;
  }

  // 2. Look for positive amount associated with of / for / amt (excluding 0)
  const ofMatch = text.match(
    /(?:of|for|amount|amt)\s*[:.-]?\s*(?:₹|\bINR\b|\bRS\.?)\s*([1-9][0-9,]*(?:\.\d{1,2})?)/i
  );
  if (ofMatch) {
    const val = Number(ofMatch[1].replace(/,/g, ''));
    if (Number.isFinite(val) && val > 0) return val;
  }

  // 3. Scan all positive currency amounts in the body (ignoring ₹0 authentication debits)
  const allAmounts = [...text.matchAll(/(?:₹|\bINR\b|\bRS\.?)\s*[:.-]?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/gi)]
    .map((m) => Number(m[1].replace(/,/g, '')))
    .filter((v) => Number.isFinite(v) && v > 0);

  return allAmounts.length > 0 ? allAmounts[0] : null;
}

function cadenceDays(body) {
  const text = String(body || '').toLowerCase();
  if (/weekly|every\s+week/.test(text)) return 7;
  if (/fortnight|every\s+two\s+weeks/.test(text)) return 14;
  if (/quarterly|every\s+quarter|three\s+months/.test(text)) return 91;
  if (/half[-\s]?yearly|six\s+months/.test(text)) return 182;
  if (/yearly|annual|every\s+year|12\s+months/.test(text)) return 365;
  if (/monthly|every\s+month|30\s+days?/.test(text)) return 30;
  // AutoPay card mandates and Standing Instructions without a named cadence
  // typically bill on a monthly cycle.
  return 30;
}

function hasExplicitCadence(body) {
  return /weekly|every\s+week|fortnight|every\s+two\s+weeks|quarterly|every\s+quarter|three\s+months|half[-\s]?yearly|six\s+months|yearly|annual|every\s+year|12\s+months|monthly|every\s+month|30\s+days?/i.test(String(body || ''));
}

function merchantFromBody(body) {
  const text = String(body || '');

  // 1. Line-oriented or labeled format: "Merchant: OpenAILLC"
  const labeled = text.match(
    /(?:^|[\r\n\s])(?:merchant|towards?)\s*[:\-]\s*([A-Za-z0-9][A-Za-z0-9 ._&@'+/*-]{1,60}?)(?=\s*(?:[\r\n]|axis|card|bank|account|a\/c|max\s*limit|txn|id\s*:|manage|https?:\/\/|\bhas\b|\bis\b|\bwas\b|\bof\b|\bfor\b|\bamount\b|\bmaximum\b|\bevery\b|\bmonthly\b|\bweekly\b|\bquarterly\b|\byearly\b|\bon\b|\bfrom\b|\bvia\b|\busing\b|\bunder\b|\bvalid\b|\breference\b|\bref\b|\bmandate\b|\bupi\b|[,.;]|$))/im
  );
  if (labeled) {
    return labeled[1].trim();
  }

  const flattened = text.replace(/\s+/g, ' ').trim();

  // 2. Prose with explicit 'towards <merchant>'
  const towards = flattened.match(
    /\b(?:towards?)\s+([A-Za-z0-9][A-Za-z0-9 ._&@'+/*-]{1,80}?)(?=\s+(?:has|is|was|of|for|amount|maximum|every|monthly|weekly|quarterly|yearly|on|from|via|using|under|valid|reference|ref|mandate|upi|card|bank|axis)\b|\s*[,.;]|$)/i
  );
  if (towards) {
    return towards[1].trim();
  }

  // 3. Prose with 'for <merchant>' where not followed by currency/numbers
  const afterFor = flattened.match(
    /\b(?:for|to|at|with)\s+(?!(?:₹|\bINR\b|\bRS\.?|\d))\s*([A-Za-z0-9][A-Za-z0-9 ._&@'+/*-]{1,80}?)(?=\s+(?:has|is|was|of|for|amount|maximum|every|monthly|weekly|quarterly|yearly|on|from|via|using|under|valid|reference|ref|mandate|upi|card|bank|axis)\b|\s*[,.;]|$)/i
  );
  if (afterFor) {
    return afterFor[1].trim();
  }

  // 4. Many UPI mandate alerts omit a prose merchant but include a VPA.
  const vpa = extractVpa(flattened);
  if (vpa) return vpa;

  // 5. Well-known recurring services named anywhere in the alert.
  const known = flattened.match(
    /\b(?:chatgpt(?:plus)?|openai(?:llc)?|claude(?:ai|pro)?|anthropic|gemini|google\s*(?:one|gemini)|cursor|perplexity|midjourney|youtube|amazon\s+prime|prime\s+video|netflix|spotify|hotstar|jiocinema|microsoft(?:\s*365)?|office\s*365|swiggy|zomato|starbucks|reliance)\b/i
  );
  return known ? known[0] : null;
}

function mandateReference(body) {
  const match = String(body || '').match(
    /\b(?:umrn|umn|ref(?:erence)?(?:\s*(?:no\.?|num|id))?|txn(?:\s*id)?|mandate\s*(?:id|ref|no\.?)|instruction\s*(?:id|ref|no\.?)|\bid\b)\s*[:#-]?\s*([A-Za-z0-9-]{6,})\b/i
  );
  return match ? match[1] : null;
}

function parseSubscriptionMandate(sms) {
  const body = String(sms?.body || '').trim();
  if (!body) return { ok: false, reason: 'empty_body' };
  if (body.length > 20000) return { ok: false, reason: 'body_too_long' };
  if (NON_MANDATE.test(body)) return { ok: false, reason: 'non_mandate_alert' };
  // A SIP/investment mandate is not a consumer subscription. It must not
  // create a renewal card or later be counted as recurring spend.
  if (isInvestmentFundingMessage(body) || isInvestmentMandateMessage(body)) {
    return { ok: false, reason: 'investment_mandate' };
  }
  if (!MANDATE.test(body)) return { ok: false, reason: 'no_mandate_match' };

  const isCancelled = CANCELLATION.test(body);
  const isActive = !isCancelled && ACTIVATION.test(body);
  if (!isCancelled && !isActive) return { ok: false, reason: 'no_mandate_match' };

  const merchant = merchantFromBody(body);
  if (!merchant) return { ok: false, reason: 'mandate_merchant_missing' };
  if (!isUsableSubscriptionName(merchant)) {
    return { ok: false, reason: 'mandate_merchant_invalid' };
  }

  const lower = body.toLowerCase();
  const instrument = /\b(?:credit|debit|bank|forex)?\s*cards?\b|\bcard\s+(?:no|ending)\b/i.test(lower)
    ? 'card'
    : /\b(?:upi|vpa|account|a\/?c)\b/i.test(lower)
      ? 'upi_bank'
      : 'unknown';
  const last4Match = body.match(
    /\b(?:card|account|a\/?c\.?)\b[\s\S]{0,50}?(?:ending(?:\s+with)?|x{2,}|\*{2,}|last\s*4|no\.?:?\s*[x*]*)\D{0,5}(\d{4})\b/i
  );

  return {
    ok: true,
    lifecycle: isCancelled ? 'cancelled' : 'active',
    fields: {
      merchant,
      amountInr: extractMandateAmount(body),
      cadenceDays: cadenceDays(body),
      cadenceExplicit: hasExplicitCadence(body),
      instrument,
      ...(last4Match ? { last4: last4Match[1] } : {}),
      ...(extractVpa(body) ? { vpa: extractVpa(body) } : {}),
      ...(mandateReference(body) ? { reference: mandateReference(body) } : {}),
    },
  };
}

module.exports = { parseSubscriptionMandate };
