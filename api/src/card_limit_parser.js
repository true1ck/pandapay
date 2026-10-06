/**
 * Conservative extraction of a credit-card limit from a bank alert.
 *
 * This intentionally does not try to infer a limit from "available credit",
 * "amount due", or a balance. Only an explicit credit-limit label is strong
 * enough to persist automatically.
 */

function parseAmount(value) {
  const normalized = String(value || '').replace(/,/g, '').trim();
  const amount = Number(normalized);
  if (!Number.isFinite(amount) || amount <= 0 || amount > 1_000_000_000) return null;
  return amount;
}

function extractLast4(text) {
  const value = String(text || '');
  const match = value.match(
    /\b(?:credit\s+card|card)\b[\s\S]{0,80}?(?:ending(?:\s+(?:in|with))?|last\s*4|x{1,4}|\*{1,4}|\.{2,})\s*([0-9]{4})\b/i,
  );
  return match ? match[1] : null;
}

function extractCreditLimit(body) {
  const text = String(body || '');
  if (!text.trim()) return null;

  // Keep the amount close to the explicit label. This prevents an alert such
  // as "credit limit ₹1,00,000; available limit ₹80,000" from capturing the
  // available amount, and rejects balance/amount-due wording.
  const limitPatterns = [
    /\b(?:total\s+|sanctioned\s+|assigned\s+|your\s+)?credit\s+limit\b\s*(?::|is|of|has\s+been\s+set\s+at|set\s+at)?\s*(?:rs\.?|inr|₹)?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/gi,
    /\bcredit\s+limit\b[^.\n]{0,100}?\b(?:increased|revised|assigned|sanctioned|set)\s+(?:to|at)\s*(?:rs\.?|inr|₹)?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/gi,
  ];
  for (const limitPattern of limitPatterns) {
    let match;
    while ((match = limitPattern.exec(text)) !== null) {
      const prefix = text.slice(Math.max(0, match.index - 24), match.index).toLowerCase();
      if (/available|remaining|outstanding|due|used/.test(prefix)) continue;
      const amountInr = parseAmount(match[1]);
      if (!amountInr) continue;
      return { amountInr, last4: extractLast4(text) };
    }
  }
  return null;
}

module.exports = { extractCreditLimit };
