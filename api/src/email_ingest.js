/**
 * F3 email-ingestion helpers — everything that doesn't need DB access.
 * The privileged DB work (looking up a forwarding address by local_part
 * and inserting the row) lives in pandapay.ingest_inbound_email(), a
 * SECURITY DEFINER RPC (0021_email_ingest_rpc.sql) — see that migration's
 * comment for why a plain owner-scoped query can't do this lookup.
 */

/**
 * Extracts the local-part of the "to" address the mail was actually
 * delivered to. Forwarding rewrites vary by provider (some wrap the
 * original recipient in the envelope, some just pass the header through),
 * so this accepts either a bare address or a "Display Name <addr>" form
 * and is tolerant of surrounding whitespace/angle brackets. Returns null
 * (not throws) on anything that doesn't look like an email address — the
 * caller treats that as "can't route this", not a crash.
 */
function extractLocalPart(toHeader) {
  if (!toHeader || typeof toHeader !== 'string') return null;
  const match = toHeader.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+/);
  if (!match) return null;
  return match[0].split('@')[0].toLowerCase();
}

/**
 * admin-console-plan.md AD-5.1.3 (Signal B2): change-announcement language
 * a bank uses when revising card terms — "revised terms", "effective
 * from", "important update to your rewards", and near-synonyms. This is a
 * cheap heuristic first pass, not a classifier: matches enter the admin
 * queue verbatim for a human to read (per the plan's own note), never
 * auto-parsed as fact. False positives are acceptable (a human triages);
 * false negatives just mean that one email doesn't get flagged, no worse
 * than the status quo of not scanning at all.
 */
const POLICY_KEYWORDS = [
  'revised terms',
  'revised term',
  'effective from',
  'important update to your rewards',
  'important update',
  'change in terms',
  'changes to terms',
  'terms and conditions have changed',
  'annual fee revision',
  'annual fee has changed',
  'reward program update',
  'rewards program update',
  'policy change',
  'discontinued',
  'we are updating our',
  "we're updating our",
  'new terms',
];

function scanPolicyKeywords(text) {
  if (!text) return false;
  const lower = text.toLowerCase();
  return POLICY_KEYWORDS.some((kw) => lower.includes(kw));
}

module.exports = { extractLocalPart, scanPolicyKeywords, POLICY_KEYWORDS };
