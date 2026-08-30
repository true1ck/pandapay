#!/usr/bin/env node
/**
 * Bulk-imports CardPipeline's LLM-extracted card records
 * (../../../CardPipeline/results/all-collected.json — a sibling project,
 * see its README) into this database's card catalogue tables.
 *
 * Usage:
 *   node api/scripts/import_card_pipeline.js \
 *     --input /path/to/all-collected.json \
 *     --admin-id <admin_users.id> \
 *     [--dry-run] [--force]
 *
 * Normally you don't call this directly — api/scripts/sync_card_catalogue.sh
 * runs collect_card_pipeline.js and then this, which is the whole
 * extraction-to-catalogue path in one command.
 *
 * --input wants the output of collect_card_pipeline.js, which reads
 * CardPipeline's authoritative checklist rather than globbing its run
 * directories (see that file's header for why the difference matters).
 * CardPipeline's own `node src/cli.js export` produces a compatible file and
 * still works as input; it just makes a weaker guarantee about which
 * extraction was the accepted one.
 *
 * RE-RUNNING IS THE NORMAL CASE, NOT THE EXCEPTION. The extraction takes
 * days, so this is built to be run repeatedly against a growing input. A card
 * whose source record is byte-identical to what it was built from last time
 * is skipped outright — see upsertCardProduct and migration 0041 for why
 * that matters more than it sounds like it should.
 *
 * --admin-id must be a real, active row in admin_users (the same id an
 * authenticated operator's JWT carries as req.userId) — admin_audit_log.
 * admin_id is a real FK to admin_users(id), and every write here goes
 * through the same `<table>_admin_write` RLS policy
 * (`using (pandapay.is_admin())`) the HTTP admin routes rely on, so an
 * id that isn't an active admin_users row fails RLS on the very first
 * insert. Checked up front so that failure is one clear message instead
 * of the first of many opaque per-card errors.
 *
 * --dry-run runs every sanity check and mapping step, prints the report,
 * and touches no rows (wraps each card's work in a transaction that's
 * always rolled back).
 *
 * --force allows re-importing over a card already in `in_review` or
 * `published` (see WHY in upsertCardProduct below). Without it those
 * cards are left alone and reported as skipped.
 *
 * ─────────────────────────────────────────────────────────────────────
 * WHY THIS IS A SEPARATE SCRIPT, NOT db/seed/*.sql OR HTTP CALLS TO THE
 * NEW /admin/issuers + /admin/cards ROUTES
 * ─────────────────────────────────────────────────────────────────────
 * The transform logic below (category/period/rail mapping, CardPipeline's
 * "N/A"-as-null convention, garbage-record detection, issuer fuzzy-match,
 * tolerating the real cap_rules schema drift documented inline) needs real
 * conditionals that a seed .sql file's static INSERTs can't express. And
 * ~80-392 cards × ~5-10 child rows each as authenticated HTTP round-trips
 * is unnecessary latency for a one-time/occasional ops job. This script
 * still uses explicit enum/mapping allowlists and the database's constraints,
 * and writes its own admin_audit_log row per write in the same DB transaction
 * as the data — so nothing loses the audit trail just because the transport
 * is direct-to-Postgres instead of HTTP.
 *
 * Every card lands as status='draft', full stop. This script never sets
 * status='published' or touches verified_at/verified_by — the only way a
 * card reaches 'published' is a human going through
 * POST /admin/cards/:id/status (or the console's equivalent button),
 * matching this codebase's "AI extracts, human verifies, never
 * auto-published" rule everywhere else card data is written.
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

// Increment whenever mapping semantics change in a way that should rebuild
// existing drafts even if their CardPipeline JSON is byte-identical.
//
// '1' -> '2': network now resolves to 'unknown' instead of rejecting the
// card (migration 0042); zero-rate rules narrowed by conditions the engine
// cannot evaluate are dropped rather than allowed to shadow the real earning
// rule; `minimum_transaction_value_inr` is recognised; prose is no longer
// stored as a merchant_pattern. Existing drafts carry the old mapping and
// must be rebuilt, which is exactly what this version bump forces.
// Explicit no-rewards products are now admitted when both reward rates are
// marked N/A and effective return is 0. That changes admission of previously
// skipped records, not the mapping of an existing draft, so it intentionally
// does not bump this transform version or rebuild unrelated cards.
// '2' -> '3': verified multi-network research is projected into
// card_product_network_variants (migration 0043) instead of remaining only
// in reviewer JSON. Existing drafts must be rebuilt so the child rows exist.
const IMPORT_TRANSFORM_VERSION = '3';

// Resolve env files from the repository, not process.cwd(), so the wrapper
// works the same from a terminal, cron, or the production deploy directory.
// Already-exported variables always win; root .env is the production
// compose contract, api/.env is the local-development fallback.
for (const envPath of [path.resolve(__dirname, '../../.env'), path.resolve(__dirname, '../.env')]) {
  if (fs.existsSync(envPath)) require('dotenv').config({ path: envPath, quiet: true });
}

// ───────────────────────────────────────────────────────────────────────
// DB connection — deliberately NOT api/src/db.js. That module pulls in
// api/src/config.js, which fail-fasts if JWT_ACCESS_SECRET (etc.) is
// unset — correct for the live API server, irrelevant noise for a
// standalone ops script that only ever needs a Postgres connection
// string. withAdminClient below mirrors db.js's withUserClient exactly
// (same BEGIN/SET LOCAL app.user_id/COMMIT-or-ROLLBACK shape, same RLS
// session-context mechanism pandapay.uid()/pandapay.is_admin() read) so
// every write here is subject to the identical RLS policy the HTTP admin
// routes are.
// ───────────────────────────────────────────────────────────────────────
function createPool() {
  // Prefer the least-privileged application role. Production's committed
  // env contract calls this API_DATABASE_URL, while local development has
  // historically called it DATABASE_URL. ADMIN_DATABASE_URL remains a
  // deliberate last-resort option for an operator running the job directly
  // on the deploy host.
  const databaseUrl =
    process.env.DATABASE_URL || process.env.API_DATABASE_URL || process.env.ADMIN_DATABASE_URL;
  if (!databaseUrl) {
    throw new Error('DATABASE_URL, API_DATABASE_URL, or ADMIN_DATABASE_URL must be set.');
  }
  return new Pool({
    connectionString: databaseUrl,
    ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  });
}

async function withAdminClient(pool, adminId, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [adminId]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

// ───────────────────────────────────────────────────────────────────────
// CLI args — no dependency added; api/package.json carries none of the
// usual parsers and this only needs four flags.
// ───────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    dryRun: false,
    force: false,
    slugs: [],
    adminId: process.env.CARD_IMPORT_ADMIN_ID || null,
    reportDir: process.env.CARD_IMPORT_REPORT_DIR || null,
  };
  const takeValue = (flag, index) => {
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    return value;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--input') args.input = takeValue(a, i++);
    else if (a === '--slug') args.slugs.push(takeValue(a, i++));
    else if (a === '--admin-id') args.adminId = takeValue(a, i++);
    else if (a === '--report-dir') args.reportDir = takeValue(a, i++);
    else if (a === '--dry-run') args.dryRun = true;
    else if (a === '--force') args.force = true;
    else if (a === '--help' || a === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  return args;
}

// ───────────────────────────────────────────────────────────────────────
// Mapping tables. Every one of these logs its fallback/skip decisions
// into `report` rather than silently guessing — see main()'s report dump.
// ───────────────────────────────────────────────────────────────────────

// CardPipeline category_id -> PandaPay spend_categories.slug. Built from
// reading the actual seeded taxonomy (db/supabase/migrations/0014) against
// real category_id values observed in CardPipeline's output — the two
// vocabularies were never the same thing and don't fully line up.
const CATEGORY_MAP = {
  grocery: 'groceries',
  groceries: 'groceries',
  fuel: 'fuel',
  dining: 'dining',
  restaurant: 'dining',
  travel: 'travel',
  travel_flights: 'travel',
  travel_hotels: 'travel',
  online: 'online',
  ecommerce: 'online',
  utility: 'bills',
  bills: 'bills',
  rent: 'rent',
  insurance: 'insurance',
  education: 'education',
  government: 'government',
  wallet: 'wallet',
  entertainment: 'entertainment',
  movie: 'entertainment',
  health: 'health',
  pharmacy: 'health',
  medical: 'health',
  medical_supplies: 'health',
  hospital: 'health',
  wallet_load: 'wallet',
  property_rental: 'rent',
  rental: 'rent',
  gaming: 'entertainment',
  digital_gaming: 'entertainment',
  fast_food: 'dining',
  telecom: 'bills',
  telecom_cable: 'bills',
  railways: 'travel',
  travel_rail: 'travel',
  travel_train: 'travel',
  travel_train_irctc: 'travel',
  travel_transport: 'travel',
  supermarket_and_convenience: 'groceries',
  supermarket_retail: 'groceries',
};
// Not positive reward categories. Their source conditions are too varied
// (MCC lists, transaction types, merchant sets) to project safely onto one
// broad PandaPay spend category, so they remain in extended_data for review.
const CATEGORY_SKIP = new Set(['excluded_spend', 'cash_advance']);
// PandaPay's own convention for "matches every category" is
// reward_rules.category_id IS NULL (see engine.dart's rule-selection —
// `categoryId == null` is the base/all-spends rate), which is exactly
// what CardPipeline's all_retail means. This is the correct value, not a
// fallback guess.
const CATEGORY_ALL_RETAIL = 'all_retail';

const PERIOD_MAP = {
  day: 'statement_cycle', // no finer-grained PandaPay period exists
  statement_cycle: 'statement_cycle',
  calendar_month: 'calendar_month',
  quarter: 'quarter',
  half_year: 'half_year',
  annual: 'annual',
  card_anniversary_year: 'annual',
  lifetime: 'lifetime',
};
const DEFAULT_PERIOD = 'statement_cycle';

const RAIL_MAP = {
  upi_qr: 'upi_qr',
  swipe: 'swipe',
  pos_terminal: 'swipe',
  online: 'online',
  contactless: 'contactless',
  atm: 'atm',
  emi: 'emi',
  // 'any', 'smartbuy_or_equivalent_portal', 'channel_type: all' etc: no
  // PandaPay txn_rail match — null means "not rail-specific", which is a
  // safe default (broader, not narrower, than the source claims).
};

// card_products.network is a single not-null enum value. Real extractions
// use inconsistent casing ("RuPay", "Visa") and sometimes name two
// networks at once ("American Express / Mastercard" — a genuine co-brand
// ambiguity this importer must not guess between) or "N/A". Anything that
// doesn't resolve to exactly one known network returns null and the card
// is skipped by sanityCheck rather than crashing the INSERT on a bad enum
// value (confirmed to happen against real records, not hypothetical).
const NETWORK_MAP = {
  rupay: 'rupay',
  visa: 'visa',
  mastercard: 'mastercard',
  'master card': 'mastercard',
  amex: 'amex',
  'american express': 'amex',
  diners: 'diners',
  'diners club': 'diners',
};
// Resolves card_product.network to exactly one card_network enum value, or
// to 'unknown'.
//
// 'unknown' is NOT a failure path — see migration 0042. Measured against a
// real 148-record collection, 40 cards (27%) resolved to no single network:
// 35 reported "N/A"/"null", and 5 named several at once
// ("Visa,Mastercard,RuPay", "American Express / Mastercard"). The latter are
// correct readings of genuinely multi-network products, not bad extractions.
//
// Those cards used to be rejected outright, discarding every reward rule
// they carried over a field RecommendationEngine never reads. They now
// import as drafts with network='unknown', which migration 0042's CHECK
// makes unpublishable until a human resolves it.
//
// A multi-network card resolves to 'unknown' rather than to the first
// network named: "Visa,Mastercard,RuPay" is not a Visa card, and rendering a
// definite-but-wrong logo is worse than rendering none.
//
// Returns { network, candidates, ambiguous } — candidates/ambiguous feed
// the report so the reviewer sees what the source said; the raw value is
// already preserved in extended_data.card_product_source.
function resolveNetwork(raw) {
  if (isNA(raw)) return { network: 'unknown', candidates: [], ambiguous: false };
  // One real extraction (hdfc-freedom) emits an ARRAY here rather than a
  // string. Joining explicitly rather than relying on String(array)'s
  // comma-joining, which happens to feed the splitter below correctly today
  // but only by coincidence of JS semantics.
  const text = (Array.isArray(raw) ? raw.join(',') : String(raw)).toLowerCase().trim();

  const exact = NETWORK_MAP[text];
  if (exact) return { network: exact, candidates: [exact], ambiguous: false };

  // Split on the separators real extractions actually use, then map each
  // fragment. Deliberately not a substring scan over the whole string:
  // "mastercard" contains "master card"'s tokens and a naive scan double
  // counts, while "Diners Club" would match both 'diners' and nothing else.
  const fragments = text.split(/[/,;|]|\band\b|\bor\b|\+/).map((f) => f.trim()).filter(Boolean);
  const candidates = [...new Set(fragments.map((f) => NETWORK_MAP[f]).filter(Boolean))];

  if (candidates.length === 1) return { network: candidates[0], candidates, ambiguous: false };
  return { network: 'unknown', candidates, ambiguous: candidates.length > 1 };
}

// Back-compat shape for callers that only need the enum value.
function mapNetwork(raw) {
  return resolveNetwork(raw).network;
}

function extractVerifiedNetworkVariants(record) {
  const items = record?.additional_data?.items;
  if (!Array.isArray(items)) return [];
  const research = items.find((item) => item?.key === 'verified_network_research')?.value;
  const candidates = Array.isArray(research?.candidates) ? research.candidates : [];
  // One candidate on an unresolved finding is not a verified variant set
  // (SBI ELITE Advantage currently has exactly that shape). It must remain a
  // review item rather than becoming publishable by accident.
  if (research?.product_status !== 'active' || candidates.length < 2) return [];

  const seen = new Set();
  const variants = [];
  for (const candidate of candidates) {
    const network = resolveNetwork(candidate?.network).network;
    if (network === 'unknown') continue;
    const networkTier = typeof candidate?.network_tier === 'string' && candidate.network_tier.trim()
      ? candidate.network_tier.trim()
      : 'N/A';
    const key = `${network}\u0000${networkTier}`;
    if (seen.has(key)) continue;
    seen.add(key);
    variants.push({
      network,
      networkTier,
      label: typeof candidate?.label === 'string' ? candidate.label : null,
      sourceUrl: typeof candidate?.source_url === 'string' ? candidate.source_url.trim() : research.source_url?.trim() || null,
      evidence: typeof candidate?.evidence === 'string' ? candidate.evidence : research.evidence || null,
    });
  }
  return variants.length >= 2 ? variants : [];
}

// ───────────────────────────────────────────────────────────────────────
// Rule conditions the importer can actually project onto engine-readable
// columns, and the ones it can't.
// ───────────────────────────────────────────────────────────────────────

// Every spelling of a transaction floor/ceiling seen in real extractions.
// `minimum_transaction_value_inr` is here because it was NOT, and its absence
// silently turned IndiGo 6E Rewards' "no points below ₹100" into "no points,
// ever" — the card scored ₹0 at ₹50, ₹500 and ₹5,000 alike.
const MIN_TXN_KEYS = [
  'minimum_transaction_inr',
  'minimum_transaction_amount_inr',
  'minimum_transaction_value_inr',
  'minimum_single_transaction_inr',
  'transaction_amount_min_inr',
  'min_transaction_inr',
];
const MAX_TXN_KEYS = [
  'maximum_transaction_inr',
  'maximum_transaction_amount_inr',
  'maximum_transaction_value_inr',
  'transaction_amount_max_inr',
  'max_transaction_inr',
];
// Keys whose value this importer reads. Anything threshold-shaped outside
// this set is reported rather than dropped in silence.
// Block-size keys are threshold-shaped but are consumed by ruleUnitAndRate
// as the ₹ accrual block, not as a transaction floor. Listed so they do not
// show up as "not read" when they are, in fact, read.
const BLOCK_SIZE_KEYS = [
  'spend_block_inr', 'accrual_block_inr', 'minimum_block_inr',
  'base_spend_block_inr', 'block_inr', 'reward_block_inr',
];
const CONSUMED_CONDITION_KEYS = new Set([
  ...MIN_TXN_KEYS, ...MAX_TXN_KEYS, ...BLOCK_SIZE_KEYS,
  'merchant_pattern', 'excluded_categories',
]);
// Deliberately narrow: an amount threshold, not merely any key with "min" in
// it. `minimum_block_inr` is a points block size, not a transaction floor,
// and mapping it to min_txn_inr would invent a spend threshold that the
// issuer never published.
const THRESHOLD_KEY_SHAPE = /^(min|max|minimum|maximum)_.*(inr|amount|value)/;

// Purely descriptive keys. Their presence does not narrow a rule, so they
// must not make one look unenforceable.
const DESCRIPTIVE_CONDITION_KEYS = new Set([
  'description', 'reason', 'notes', 'note', 'source', 'comment', 'label',
]);
// channel_type values that mean "no channel restriction".
const CHANNEL_WILDCARDS = new Set(['all', 'any', 'all_channels', '']);

/// Conditions that narrow a rule but have nowhere to go in reward_rules —
/// i.e. things RecommendationEngine.ruleApplies() will never see. Returns a
/// list of human-readable reasons, empty when the rule is fully expressible.
function unmappedNarrowing(rule, sourceConditions, acceptedMerchantPattern) {
  const reasons = [];

  const channel = rule.channel_type;
  if (!isNA(channel) && !CHANNEL_WILDCARDS.has(String(channel).toLowerCase().trim())) {
    reasons.push(`channel_type=${channel}`);
  }

  for (const [key, value] of Object.entries(sourceConditions)) {
    if (DESCRIPTIVE_CONDITION_KEYS.has(key)) continue;
    // A merchant pattern only counts as expressible if it survived
    // usableMerchantPattern; prose that was rejected still narrows the rule.
    if (key === 'merchant_pattern') {
      if (!acceptedMerchantPattern) reasons.push('merchant_pattern (unusable as a pattern)');
      continue;
    }
    if (key === 'excluded_categories') continue;
    // A minimum-transaction floor on a ZERO-rate rule inverts: the source
    // means "earns nothing BELOW ₹X", while min_txn_inr means "this rule
    // applies AT OR ABOVE ₹X". Storing it would zero out every spend above
    // the floor — the exact opposite. reward_rules has no "applies below"
    // form, so it counts as unmappable here rather than being consumed.
    if (MIN_TXN_KEYS.includes(key)) {
      reasons.push(`${key} (a floor on an exclusion inverts to "applies below", which reward_rules cannot express)`);
      continue;
    }
    if (MAX_TXN_KEYS.includes(key)) continue;
    if (value === null || value === undefined) continue;
    reasons.push(key);
  }
  return reasons;
}

/// reward_rules.merchant_pattern is matched as a normalised SUBSTRING of the
/// transaction's merchant name. Extractions sometimes put prose there
/// ("Eligible non-Shoppers Stop spends"), which can never match any real
/// merchant string — so the rule silently stops applying to anything.
/// Accept only values that read like a merchant name.
function usableMerchantPattern(raw, cardProductId, rule, report) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const words = trimmed.split(/\s+/);
  const prose =
    words.length > 3 ||
    /\b(eligible|excluding|except|other|others|all|any|non|spends?|transactions?)\b/i.test(trimmed);
  if (prose) {
    report.unusableMerchantPatterns.push({
      card_product_id: cardProductId,
      rule: rule.id || null,
      value: trimmed,
    });
    return null;
  }
  return trimmed;
}

// The sections a complete extraction carries. A record missing several of
// them is not corrupt — it imports fine and its reward rules are real — but
// it is INCOMPLETE, and that is invisible once it is a row in Postgres.
//
// A truncated extraction (one real case: hdfc-diners-club-privilege stopped
// after 8 of 17 sections) produces a draft with no fees, no benefits, no
// redemption options and no fee waiver. To a reviewer that is indistinguishable
// from a card that genuinely has none of those, and publishing it would ship
// a card whose annual fee silently reads ₹0. Flagged so the reviewer knows to
// re-extract rather than trust the blanks.
const EXPECTED_RECORD_SECTIONS = [
  'card_product', 'accrual_engine', 'reward_rules', 'cap_rules',
  'fees_and_surcharges', 'statement_and_late_fees', 'fee_waiver_and_milestones',
  'lifestyle_and_network_benefits', 'insurance_and_protection',
  'addon_card_rules', 'redemption_matrix',
];
function missingSections(record) {
  return EXPECTED_RECORD_SECTIONS.filter((s) => !(s in record));
}

const CARD_TYPES = ['credit', 'debit', 'prepaid', 'forex'];
// [pattern tested against a lowercased "category/label/benefit_id/cover_type"
// string, benefit_kind]. First match wins; falls through to 'other'.
const BENEFIT_KIND_RULES = [
  [/lounge.*(inter|abroad|overseas|global)/, 'lounge_international'],
  [/lounge/, 'lounge_domestic'],
  [/golf/, 'golf'],
  [/concierge/, 'concierge'],
  [/(air.*accident|overseas.*medical|travel.*insur|baggage)/, 'insurance_travel'],
  [/(purchase.*protect|credit.*shield|insur)/, 'insurance_purchase'],
  [/extended.*warrant/, 'extended_warranty'],
  [/dining/, 'dining_program'],
  [/movie/, 'movie'],
  [/fuel.*surcharge/, 'fuel_surcharge'],
  [/roadside/, 'roadside_assistance'],
];

// Real incident already caught by hand in CardPipeline/EXTRACTION_NOTES.md:
// an off-topic Oracle Cloud config dump saved as a "card". Deliberately
// narrow — every record carries the schema's own boilerplate `_notes` text
// verbatim on some extraction runs ("Universal card-extraction
// **template**..."), so generic words like "template"/"TODO" produced
// false positives against real cards (confirmed against actual pipeline
// output, not assumed) and are not included. The other EXTRACTION_NOTES.md
// incident — an empty draft with no real content — is already caught
// structurally by the "no reward_rules and no accrual_engine base rate"
// check below, which doesn't depend on guessing keywords.
const GARBAGE_DENYLIST = /oracle cloud|lorem ipsum/i;
// Schema boilerplate keys that can legitimately contain denylist-adjacent
// words (e.g. `_notes` says "template") and must not be searched.
const GARBAGE_CHECK_EXCLUDE_KEYS = new Set(['$schema', 'schema_version', '_notes']);
function garbageCheckText(record) {
  const copy = {};
  for (const [k, v] of Object.entries(record)) {
    if (!GARBAGE_CHECK_EXCLUDE_KEYS.has(k)) copy[k] = v;
  }
  return JSON.stringify(copy);
}

const STOPWORDS = new Set([
  'card', 'credit', 'debit', 'the', 'of', 'in', 'and', 'with', 'a', 'an', 'for',
  'bank', 'state', 'india', 'association',
]);

// ───────────────────────────────────────────────────────────────────────
// Small helpers
// ───────────────────────────────────────────────────────────────────────

// CardPipeline's schema uses the literal string "N/A" wherever a field
// genuinely doesn't apply, distinct from null ("not yet verified"). Both
// mean "nothing usable here" to this importer.
function isNA(v) {
  return v === null || v === undefined || v === 'N/A';
}
function hasExplicitNoRewardProgram(record) {
  const accrual = record?.accrual_engine || {};
  const literalNoRewards = Array.isArray(record?.reward_rules)
    && record.reward_rules.length === 0
    && accrual.base_points_per_block === 'N/A'
    && accrual.base_cashback_percent === 'N/A'
    && accrual.effective_base_return_percent === 0;
  if (literalNoRewards) return true;

  // Two issuer-audited records use null for the absent point fields but carry
  // explicit product evidence that no base programme exists: Kotak Travel
  // Agent says automatic base incentive accrual was discontinued, and RBL
  // Play says no base schedule is published because its value is delivered as
  // BookMyShow discounts. Keep this evidence-driven and require an official
  // issuer source tier plus an explicit 0% result; a merely incomplete record
  // with null rates still fails closed.
  if (!Array.isArray(record?.reward_rules) || record.reward_rules.length !== 0
      || accrual.effective_base_return_percent !== 0
      || !String(record?.card_product?.data_source_tier || '').startsWith('issuer_')) return false;
  const items = Array.isArray(record?.additional_data?.items) ? record.additional_data.items : [];
  return items.some((item) =>
    item?.key === 'reward_accrual_discontinuation'
    || (item?.key === 'reward_program_status'
      && /no active|not officially published|rather than a published base/i.test(JSON.stringify(item.value || item.description || '')))
  );
}
function asNumber(v) {
  if (isNA(v)) return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}
function firstDefined(...vals) {
  for (const v of vals) if (!isNA(v)) return v;
  return null;
}

// Standard mod-10 check. Applied to every 13-19 digit run found anywhere
// in a record's JSON text, belt-and-braces alongside R1 ("no card number
// column exists here, or anywhere, by design") even though CardPipeline's
// own schema was never meant to capture PANs.
function luhnValid(digits) {
  let sum = 0;
  let alt = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 === 0;
}
function containsCardNumber(record) {
  const text = JSON.stringify(record);
  const runs = text.match(/\d{13,19}/g) || [];
  return runs.some(luhnValid);
}

// ───────────────────────────────────────────────────────────────────────
// Source hashing — the mechanism behind "skip cards that haven't changed".
//
// Keys are sorted recursively before serialising because JSON object key
// order is not semantically meaningful, but IS preserved by
// JSON.stringify. Without canonicalising, an extraction re-serialised with
// its keys in a different order would hash differently and be treated as
// changed, which would put us straight back to refreshing every card on
// every run — the exact churn migration 0041 exists to stop.
//
// Arrays are NOT sorted: order carries meaning there (reward_rules
// priority, redemption_matrix options), so a reordered array is a real
// change.
// ───────────────────────────────────────────────────────────────────────
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value).sort()) out[k] = canonicalize(value[k]);
    return out;
  }
  return value;
}
function sourceHash(record) {
  return crypto.createHash('sha256').update(JSON.stringify(canonicalize(record))).digest('hex');
}

function pointsUnitAndRate(points, block, report) {
  if (block === 100) return { unit: 'points_per_100', rate: points };
  if (block === 150) return { unit: 'points_per_150', rate: points };
  if (block === 200) return { unit: 'points_per_200', rate: points };
  if (block !== null && block > 0) {
    report.unusualBlockSizes[block] = (report.unusualBlockSizes[block] || 0) + 1;
    // The database has enums for only 100/150/200-rupee blocks. Normalise
    // every other positive block to a mathematically equivalent per-₹100
    // rate instead of relabelling (and thereby changing) the reward.
    return { unit: 'points_per_100', rate: (points * 100) / block };
  }
  report.warnings.push('A points rate had no usable spend block; treated as points_per_100.');
  return { unit: 'points_per_100', rate: points };
}

function mappedCategorySlugs(values) {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.map((value) => CATEGORY_MAP[value]).filter(Boolean))];
}

function deriveCardEconomics(record, report) {
  const cp = record.card_product || {};
  const accrual = record.accrual_engine || {};
  const cashback = asNumber(accrual.base_cashback_percent);
  const points = asNumber(accrual.base_points_per_block);
  const block = asNumber(accrual.base_block_inr);

  let baseRewardUnit = null;
  let baseRewardRate = null;
  if (cashback !== null) {
    baseRewardUnit = 'cashback_percent';
    baseRewardRate = cashback;
  } else if (points !== null) {
    const mapped = pointsUnitAndRate(points, block, report);
    baseRewardUnit = mapped.unit;
    baseRewardRate = mapped.rate;
  }

  // Base/all-retail exclusions must be card-level. A rule-level exclusion
  // on the catch-all rule would simply make the engine fall through to this
  // same base rate and pay it anyway.
  const excluded = new Set();
  for (const rule of record.reward_rules || []) {
    if (rule.category_id !== CATEGORY_ALL_RETAIL && rule.category_id !== 'excluded_spend') continue;
    for (const slug of mappedCategorySlugs(rule.conditions?.excluded_categories)) excluded.add(slug);
  }

  return {
    baseRewardUnit,
    baseRewardRate,
    pointValueInr: asNumber(cp.point_value_inr_baseline),
    pointValueBasis: isNA(cp.point_value_baseline_basis) ? null : cp.point_value_baseline_basis,
    excludedCategorySlugs: [...excluded],
  };
}

function normalizeTokens(str) {
  if (!str) return new Set();
  const tokens = String(str)
      .toLowerCase()
      // FIRST EA₹N is IDFC's official stylisation of FIRST EARN.
      .replace(/₹/g, 'r')
      .replace(/[^a-z0-9\s]/g, ' ')
      .split(/\s+/)
      .filter((t) => t && !STOPWORDS.has(t));
  const out = new Set(tokens);
  // Preserve ordinary token matching, but also recognise a brand word that
  // official artwork writes without spaces (DreamDifferent vs Dream
  // Different). The concatenated form is used only as another equality
  // token; unrelated names still have no overlap.
  if (tokens.length > 1) out.add(tokens.join(''));
  return out;
}

// Compares a record's own card_product.name against the name CardPipeline's
// own index (all-collected-index.json, keyed by array position — see
// loadIndex) says that record SHOULD be. Stopwords are stripped first
// because two paraphrases of the same real card ("SBI Card ELITE" vs
// "SBI ELITE Credit Card") share only generic tokens otherwise, which
// would make a naive overlap score meaningless. What's left after
// stripping is the actual distinguishing product name — and this is
// exactly the check that catches "SBI Card PULSE" saved under
// "SBI Card PRIME"'s expected name: after stripping, {pulse} vs {prime}
// share nothing.
function nameLooksMismatched(recordName, expectedName) {
  const a = normalizeTokens(recordName);
  const b = normalizeTokens(expectedName);
  if (a.size === 0 || b.size === 0) return false; // can't judge, don't block
  let overlap = 0;
  for (const t of a) if (b.has(t)) overlap++;
  return overlap === 0;
}

function mapCategory(cpCategoryId, report, contextLabel) {
  if (isNA(cpCategoryId)) return { skip: false, categoryId: null };
  if (cpCategoryId === CATEGORY_ALL_RETAIL) return { skip: false, categoryId: null };
  if (CATEGORY_SKIP.has(cpCategoryId)) {
    report.skippedCategories.push({ value: cpCategoryId, context: contextLabel });
    return { skip: true, categoryId: null };
  }
  const mapped = CATEGORY_MAP[cpCategoryId];
  if (mapped) return { skip: false, categoryId: mapped };
  report.unmappedCategories[cpCategoryId] = (report.unmappedCategories[cpCategoryId] || 0) + 1;
  // An unknown source category is not equivalent to PandaPay's broad
  // "other" bucket. Mapping a Flipkart-only or EMI-only accelerator to
  // "other" would promise that rate across every uncategorised purchase.
  // Keep the raw rule in extended_data and skip only its structured form;
  // a reviewer can add an explicit mapping later.
  return { skip: true, categoryId: null };
}

function mapPeriod(cpPeriod, report) {
  if (isNA(cpPeriod)) return DEFAULT_PERIOD;
  const mapped = PERIOD_MAP[cpPeriod];
  if (mapped) return mapped;
  report.unmappedPeriods[cpPeriod] = (report.unmappedPeriods[cpPeriod] || 0) + 1;
  return DEFAULT_PERIOD;
}

function mapRail(cpRail, report) {
  if (isNA(cpRail)) return null;
  const mapped = RAIL_MAP[cpRail];
  if (mapped !== undefined) return mapped;
  report.unmappedRails[cpRail] = (report.unmappedRails[cpRail] || 0) + 1;
  return null;
}

function guessBenefitKind(...fields) {
  const hay = fields.filter((f) => !isNA(f)).join(' ').toLowerCase();
  for (const [pattern, kind] of BENEFIT_KIND_RULES) {
    if (pattern.test(hay)) return kind;
  }
  return 'other';
}

// ───────────────────────────────────────────────────────────────────────
// Loading CardPipeline's output
// ───────────────────────────────────────────────────────────────────────

// all-collected-index.json sits alongside all-collected.json (same run of
// `node src/cli.js export`) and is written in the same array order, one
// entry per record: {id, card_name, issuer, runId, finishedAt}. `id` is
// the checklist row id (ALL_CARDS_LIST.md's stable identity for a named
// card) and `card_name`/`issuer` are what the checklist EXPECTS this
// record to be — independent of whatever the extraction actually
// produced. That independence is exactly what makes it useful as a
// sanity check.
function loadIndex(inputPath, report) {
  const indexPath = path.join(path.dirname(inputPath), 'all-collected-index.json');
  if (!fs.existsSync(indexPath)) {
    report.warnings.push(`No all-collected-index.json next to ${inputPath} — name-mismatch check disabled.`);
    return null;
  }
  return JSON.parse(fs.readFileSync(indexPath, 'utf8'));
}

// ───────────────────────────────────────────────────────────────────────
// Sanity checks — fail here means SKIP, never a partial write.
// ───────────────────────────────────────────────────────────────────────
function sanityCheck(record, indexEntry, report) {
  const name = record?.card_product?.name;
  const slug = record?.card_product?.slug;
  const issuerSlug = record?.card_product?.issuer_slug;

  if (typeof name !== 'string' || name.trim().length < 3 || name.trim().length > 120) {
    return 'card_product.name missing or implausible';
  }
  if (GARBAGE_DENYLIST.test(garbageCheckText(record))) {
    return 'record matches known-garbage denylist (off-topic content unrelated to card data)';
  }
  if (typeof slug !== 'string' || !slug.trim()) {
    return 'card_product.slug missing';
  }
  if (typeof issuerSlug !== 'string' || !issuerSlug.trim()) {
    return 'card_product.issuer_slug missing';
  }
  // network is NO LONGER a rejection reason. It resolves to 'unknown' when
  // the source is missing or names several networks, and migration 0042's
  // CHECK stops such a card being published. Rejecting here instead threw
  // away 27% of a real collection over a display-only field — see
  // resolveNetwork.
  const gaps = missingSections(record);
  if (gaps.length) {
    report.incompleteRecords.push({ slug, missing: gaps });
  }

  const net = resolveNetwork(record?.card_product?.network);
  if (net.network === 'unknown') {
    const variants = extractVerifiedNetworkVariants(record);
    if (variants.length > 1) {
      report.networkVariantCards.push({
        slug,
        variants: variants.map(({ network, networkTier }) => ({ network, network_tier: networkTier })),
      });
    } else {
      report.unresolvedNetworks.push({
        slug,
        raw: record?.card_product?.network ?? null,
        candidates: net.candidates,
        reason: net.ambiguous ? 'names several networks' : 'no verified network variant set',
      });
    }
  }
  const hasRewardRule = Array.isArray(record.reward_rules) && record.reward_rules.length > 0;
  const hasBaseRate =
    !isNA(record?.accrual_engine?.base_cashback_percent) ||
    !isNA(record?.accrual_engine?.base_points_per_block);
  if (!hasRewardRule && !hasBaseRate && !hasExplicitNoRewardProgram(record)) {
    return 'no reward_rules and no accrual_engine base rate — nothing for the ranking engine to use';
  }
  if (containsCardNumber(record)) {
    return 'record contains a Luhn-valid digit run (possible card number) — refusing to import';
  }
  if (indexEntry && nameLooksMismatched(name, indexEntry.card_name)) {
    return `name mismatch vs CardPipeline's own index: record says "${name}", checklist expected "${indexEntry.card_name}" (id: ${indexEntry.id})`;
  }
  return null;
}

// ───────────────────────────────────────────────────────────────────────
// Per-card import
// ───────────────────────────────────────────────────────────────────────

async function resolveIssuer(client, issuerSlug, report) {
  // Try an exact slug hit first (cheap, and correct once enough cards have
  // been imported that CardPipeline's own slugs are already seeded).
  const bySlug = await client.query('SELECT id, slug, name FROM issuers WHERE slug = $1', [issuerSlug]);
  if (bySlug.rows.length) return bySlug.rows[0].id;

  // CardPipeline slugs (`sbi-card`) and this catalogue's seeded slugs
  // (`sbi`) were never the same vocabulary — fuzzy-match by name instead
  // of creating a duplicate issuer. `sbi-card` -> tokens {sbi} after
  // dropping 'card' as a stopword, matched loosely against every seeded
  // issuer's own name tokens.
  const humanGuess = issuerSlug.replace(/[-_]/g, ' ');
  const guessTokens = normalizeTokens(humanGuess);
  const all = await client.query('SELECT id, slug, name FROM issuers');
  for (const row of all.rows) {
    const rowTokens = normalizeTokens(row.name);
    let overlap = 0;
    for (const t of guessTokens) if (rowTokens.has(t)) overlap++;
    if (guessTokens.size > 0 && overlap === guessTokens.size) {
      report.issuerResolutions.push({ cardPipelineSlug: issuerSlug, resolvedTo: row.slug, method: 'fuzzy_name' });
      return row.id;
    }
  }

  // Genuinely new issuer — create it, log it so a human can confirm this
  // wasn't actually a near-duplicate the fuzzy match missed.
  const created = await client.query(
    `INSERT INTO issuers (slug, name) VALUES ($1, $2)
     ON CONFLICT (slug) DO UPDATE SET slug = EXCLUDED.slug
     RETURNING id, slug, name`,
    [issuerSlug, humanGuess.replace(/\b\w/g, (c) => c.toUpperCase())]
  );
  report.issuersCreated.push({ slug: created.rows[0].slug, name: created.rows[0].name });
  return created.rows[0].id;
}

// Returns { cardProductId, action, existingStatus?, sourceChanged? } where
// action is 'created' | 'refreshed' | 'refreshed_forced' | 'unchanged' |
// 'skipped_reviewed'.
async function upsertCardProduct(
  client,
  issuerId,
  cp,
  extendedData,
  economics,
  force,
  hash,
  runId
) {
  const existing = await client.query(
    `SELECT id, status, import_source_hash, import_transform_version
       FROM card_products WHERE slug = $1`,
    [cp.slug]
  );

  const baseValues = {
    issuer_id: issuerId,
    name: cp.name,
    network: mapNetwork(cp.network),
    card_type: CARD_TYPES.includes(cp.card_type) ? cp.card_type : 'credit',
    joining_fee_inr: asNumber(cp.joining_fee_inr) ?? 0,
    annual_fee_inr: asNumber(cp.annual_fee_inr) ?? 0,
    is_upi_linkable: cp.is_upi_linkable === true,
    source_url: isNA(cp.source_url) ? null : cp.source_url,
    extended_data: JSON.stringify(extendedData),
    base_reward_unit: economics.baseRewardUnit,
    base_reward_rate: economics.baseRewardRate,
    point_value_inr: economics.pointValueInr,
    point_value_basis: economics.pointValueBasis,
    excluded_category_slugs: economics.excludedCategorySlugs,
  };

  if (existing.rows.length === 0) {
    const inserted = await client.query(
      `INSERT INTO card_products (slug, status, issuer_id, name, network, card_type,
         joining_fee_inr, annual_fee_inr, is_upi_linkable, source_url, extended_data,
         base_reward_unit, base_reward_rate, point_value_inr, point_value_basis,
         excluded_categories, import_source_hash, import_source_run_id,
         import_transform_version, imported_at)
       VALUES ($1, 'draft', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
         ARRAY(select id from spend_categories where slug = any($15::text[])), $16, $17, $18, now())
       RETURNING id`,
      [
        cp.slug, baseValues.issuer_id, baseValues.name, baseValues.network, baseValues.card_type,
        baseValues.joining_fee_inr, baseValues.annual_fee_inr, baseValues.is_upi_linkable,
        baseValues.source_url, baseValues.extended_data, baseValues.base_reward_unit,
        baseValues.base_reward_rate, baseValues.point_value_inr, baseValues.point_value_basis,
        baseValues.excluded_category_slugs, hash, runId, IMPORT_TRANSFORM_VERSION,
      ]
    );
    return { cardProductId: inserted.rows[0].id, action: 'created' };
  }

  const row = existing.rows[0];

  // Nothing about this card's source record has changed since it was last
  // imported, so there is nothing to write. Checked BEFORE the review-status
  // check on purpose: a published card whose extraction is unchanged is a
  // genuine no-op, and reporting it as "skipped, use --force to override"
  // would put a warning in front of the operator on every single run for
  // every card they have already approved.
  //
  // This is not just an optimisation. Refreshing a card delete-and-reinserts
  // all nine child rule tables, each write firing
  // pandapay.bump_card_data_version() — so a no-op re-import of the full
  // catalogue would move every card's sync version and make every installed
  // device re-download data it already has. See migration 0041.
  if (
    hash &&
    row.import_source_hash === hash &&
    row.import_transform_version === IMPORT_TRANSFORM_VERSION &&
    !force
  ) {
    return { cardProductId: row.id, action: 'unchanged', existingStatus: row.status };
  }

  // Idempotency is tied to REVIEW STATE, not just presence: a human who
  // has already started reviewing (in_review) or approved (published) a
  // card must not have that silently overwritten by a re-run just because
  // more of CardPipeline's 392 cards finished extracting. --force exists
  // for the deliberate "re-import anyway" case; without it this is a
  // no-op, reported so it's visible rather than silently doing nothing.
  //
  // Reaching here means the source or the mapping version changed (the
  // combined no-op check above already returned otherwise), which is worth
  // surfacing separately: newer extraction data or a mapping correction on
  // a published card is a review task, not automation noise.
  if (row.status !== 'draft' && !force) {
    return {
      cardProductId: row.id,
      action: 'skipped_reviewed',
      existingStatus: row.status,
      sourceChanged: row.import_source_hash !== null && row.import_source_hash !== hash,
      transformChanged: row.import_transform_version !== IMPORT_TRANSFORM_VERSION,
    };
  }

  await client.query(
    `UPDATE card_products SET
       issuer_id = $2, name = $3, network = $4, card_type = $5,
       joining_fee_inr = $6, annual_fee_inr = $7, is_upi_linkable = $8,
       source_url = $9, extended_data = $10,
       base_reward_unit = $11, base_reward_rate = $12,
       point_value_inr = $13, point_value_basis = $14,
       excluded_categories = ARRAY(select id from spend_categories where slug = any($15::text[])),
       import_source_hash = $16, import_source_run_id = $17,
       import_transform_version = $18, imported_at = now()
     WHERE id = $1`,
    [
      row.id, baseValues.issuer_id, baseValues.name, baseValues.network, baseValues.card_type,
      baseValues.joining_fee_inr, baseValues.annual_fee_inr, baseValues.is_upi_linkable,
      baseValues.source_url, baseValues.extended_data, baseValues.base_reward_unit,
      baseValues.base_reward_rate, baseValues.point_value_inr, baseValues.point_value_basis,
      baseValues.excluded_category_slugs, hash, runId, IMPORT_TRANSFORM_VERSION,
    ]
  );
  // The JSON is the source of truth until a human starts reviewing, so a
  // refresh is delete-and-reinsert for the list-shaped children rather
  // than trying to diff/patch rows that have no stable key from
  // CardPipeline's side (its local reward-rule "id" strings are only
  // unique within one extraction, not a real primary key we can match
  // against on a re-run).
  for (const table of [
    'card_product_network_variants',
    'reward_rules',
    'cap_rules',
    'milestone_rules',
    'fee_waiver_rules',
    'card_benefits',
    'redemption_options',
    'forex_rules',
    'fuel_surcharge_rules',
    'billing_cycle_rules',
  ]) {
    await client.query(`DELETE FROM ${table} WHERE card_product_id = $1`, [row.id]);
  }
  return { cardProductId: row.id, action: row.status === 'draft' ? 'refreshed' : 'refreshed_forced', existingStatus: row.status };
}

/// The unit+rate a source rule projects onto. Shared by the collision pre-pass
/// and the import loop so the two can never disagree about which rules are
/// zero-rate.
function ruleUnitAndRate(r, cardBaseBlockInr, report) {
  const cashback = asNumber(r.action?.cashback_percent);
  if (cashback !== null) return { unit: 'cashback_percent', rate: cashback };

  const pointsPerBlock = asNumber(r.action?.points_per_block);
  if (pointsPerBlock !== null) {
    const conditions = r.conditions || {};
    const block = asNumber(firstDefined(
      conditions.spend_block_inr,
      conditions.accrual_block_inr,
      conditions.minimum_block_inr,
      conditions.base_spend_block_inr,
      conditions.block_inr,
      conditions.reward_block_inr,
      cardBaseBlockInr
    ));
    return pointsUnitAndRate(pointsPerBlock, block, report);
  }

  // Exclusion rules (multiplier: 0) commonly have both "N/A" — a zero rate in
  // any unit is equivalent, and this row still matters: it's what makes the
  // engine correctly return ₹0 for this category instead of silently falling
  // through to the card's base rate.
  return { unit: 'cashback_percent', rate: 0 };
}
function ruleRate(r, cardBaseBlockInr, report) {
  return ruleUnitAndRate(r, cardBaseBlockInr, report).rate;
}

/// Zero-rate rules that would SHADOW a real earning rule.
///
/// The engine picks the applicable rule with the lowest priority number. Two
/// rules with the same (category, rail) have the same match surface as far as
/// ruleApplies() is concerned, so if the zero-rate one sorts first it wins
/// every time and the category reads as earning nothing.
///
/// This is deliberately a COLLISION test, not a "does the rule have
/// conditions the engine can't read" test. Most zero-rate rules carry an MCC
/// list that merely enumerates the category they already target — redundant,
/// not narrowing — and they are the card's genuine exclusions ("rent earns
/// nothing", "wallet loads earn nothing"). An earlier, broader version of
/// this dropped 537 of them and would have made cards promise rewards their
/// issuers do not pay. Only a rule that actually collides with an earning
/// rule is a problem worth solving.
function shadowingZeroRateRules(projected) {
  const shadowing = new Set();
  for (const z of projected) {
    if (z.rate !== 0) continue;
    const shadowed = projected.some(
      (e) => e !== z && e.rate > 0 && e.categoryId === z.categoryId && e.rail === z.rail && e.priority > z.priority
    );
    if (shadowed) shadowing.add(z.source);
  }
  return shadowing;
}

async function importRewardRules(client, cardProductId, rules, cardBaseBlockInr, report) {
  const localIdToUuid = {};
  const capReferenceToRewardIds = {};

  // First pass: project every rule onto the fields the engine matches on, so
  // the loop below can tell a colliding zero-rate rule from a standalone one.
  // Uses a throwaway report so this pass cannot double-count the warnings the
  // real pass emits.
  const scratch = newReport();
  const projected = [];
  for (const r of rules || []) {
    const { skip, categoryId } = mapCategory(r.category_id, scratch, '');
    if (skip) continue;
    projected.push({
      source: r,
      categoryId,
      rail: mapRail(r.rail, scratch),
      rate: ruleRate(r, cardBaseBlockInr, scratch),
      priority: Number.isInteger(r.priority) ? r.priority : 100,
    });
  }
  const shadowing = shadowingZeroRateRules(projected);

  for (const r of rules || []) {
    const { skip, categoryId } = mapCategory(r.category_id, report, `reward_rule ${r.id || ''}`);
    if (skip) continue;

    const { unit, rate } = ruleUnitAndRate(r, cardBaseBlockInr, report);

    const conditions = {
      source_local_id: r.id || null,
      evaluation_type: r.evaluation_type || null,
      channel_type: r.channel_type || null,
      cap_reference: r.action?.cap_reference || null,
      source_conditions: r.conditions || null,
    };

    const sourceConditions = r.conditions || {};
    const merchantPattern = usableMerchantPattern(
      sourceConditions.merchant_pattern, cardProductId, r, report
    );
    const minTxn = asNumber(firstDefined(...MIN_TXN_KEYS.map((k) => sourceConditions[k])));
    const maxTxn = asNumber(firstDefined(...MAX_TXN_KEYS.map((k) => sourceConditions[k])));
    const excludedSlugs = mappedCategorySlugs(sourceConditions.excluded_categories);

    // Surface threshold-shaped condition keys this importer does not read, so
    // the next new spelling shows up in the report instead of silently
    // vanishing. `minimum_transaction_value_inr` reached production exactly
    // that way: unrecognised, dropped, and the rule it belonged to became a
    // blanket exclusion that scored one whole card at ₹0 for every spend.
    for (const key of Object.keys(sourceConditions)) {
      if (THRESHOLD_KEY_SHAPE.test(key) && !CONSUMED_CONDITION_KEYS.has(key)) {
        report.unmappedConditionKeys[key] = (report.unmappedConditionKeys[key] || 0) + 1;
      }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Drop a zero-rate rule ONLY when it both shadows a real earning rule and
    // is narrowed by something the engine cannot evaluate.
    //
    // RecommendationEngine.ruleApplies() evaluates category, merchant
    // pattern, rail, min/max txn and effective dates — and nothing else. The
    // extraction routinely narrows a rule by things outside that set:
    // channel_type ("third_party_aggregator" vs "direct_school_college"), or
    // a conditions.category sub-type ("supermarket" vs "grocery").
    //
    // When such a rule collides with an earning rule on the same (category,
    // rail) and sorts first, the engine picks the zero every time and the
    // category reads as earning nothing. On a real 148-record collection
    // that hit 13 cards — four SBI SimplySave variants whose 10%
    // entertainment rate scored 0%, and one card that scored ₹0 on every
    // spend at every amount.
    //
    // BOTH conditions are required. Gating on narrowing alone dropped 537
    // rules, because most zero-rate rules carry an MCC list that just
    // enumerates the category they already target — those are the card's
    // genuine exclusions, and removing them would make cards promise rewards
    // their issuers do not pay. That is the worse direction to be wrong in.
    //
    // Dropping a colliding rule means the category falls through to the
    // card's real rate: wrong in the narrow sub-case the exclusion described,
    // right everywhere else. Keeping it is wrong everywhere. Reported so a
    // reviewer can see what could not be modelled.
    if (rate === 0 && shadowing.has(r)) {
      const narrowing = unmappedNarrowing(r, sourceConditions, merchantPattern);
      if (narrowing.length) {
        report.unenforceableExclusions.push({
          card_product_id: cardProductId,
          rule: r.id || null,
          category: r.category_id ?? null,
          narrowed_by: narrowing,
          source_reason: r.action?.reason || sourceConditions.description || null,
        });
        continue;
      }
    }

    const inserted = await client.query(
      `INSERT INTO reward_rules
         (card_product_id, category_id, merchant_pattern, rail, unit, rate, min_txn_inr,
          max_txn_inr, priority, conditions, effective_from, effective_to, excluded_categories)
       VALUES ($1, (select id from spend_categories where slug = $2), $3, $4, $5, $6, $7,
         $8, $9, $10, $11, $12,
         ARRAY(select id from spend_categories where slug = any($13::text[])))
       RETURNING id`,
      [
        cardProductId,
        categoryId,
        merchantPattern,
        mapRail(r.rail, report),
        unit,
        rate,
        minTxn,
        maxTxn,
        Number.isInteger(r.priority) ? r.priority : 100,
        JSON.stringify(conditions),
        isNA(r.effective_from) ? null : r.effective_from,
        isNA(r.effective_to) ? null : r.effective_to,
        excludedSlugs,
      ]
    );
    if (r.id) localIdToUuid[r.id] = inserted.rows[0].id;
    const capReference = r.action?.cap_reference;
    if (!isNA(capReference)) {
      if (!capReferenceToRewardIds[capReference]) capReferenceToRewardIds[capReference] = [];
      capReferenceToRewardIds[capReference].push(inserted.rows[0].id);
    }
  }
  return { localIdToUuid, capReferenceToRewardIds };
}

// cap_rules' REAL shape ({cap_id, scope, target_rule_ids, cap_type,
// cap_limit, capping_period, description}) differs from the documented
// template ({id, category_id, metric, limit_value_inr, period,
// post_limit_behavior, ...}) — confirmed by reading actual extracted
// records, not assumed from the schema file. firstDefined() below reads
// whichever shape (or mix) a given record actually used.
async function importCapRules(
  client,
  cardProductId,
  caps,
  localIdToUuid,
  capReferenceToRewardIds,
  categoryByLocalRewardId,
  pointValueInr,
  cardBaseBlockInr,
  report
) {
  for (const c of caps || []) {
    let capValue = asNumber(firstDefined(c.cap_limit, c.limit_value_inr, c.limit_value));
    if (capValue === null) {
      report.skippedCapRules.push({ card_product_id: cardProductId, reason: 'no usable cap value', raw: c });
      continue;
    }
    const capType = (firstDefined(c.cap_type, c.metric) || '').toLowerCase();
    if (/points/.test(capType)) {
      if (pointValueInr === null) {
        report.skippedCapRules.push({
          card_product_id: cardProductId,
          reason: 'points cap has no card point_value_inr for conversion to reward value',
          raw: c,
        });
        continue;
      }
      capValue *= pointValueInr;
    }
    const measure = /count/.test(capType)
      ? 'txn_count'
      : /spend|amount/.test(capType)
        ? 'spend_amount'
        : 'reward_value';
    const label = firstDefined(c.description, c.label) || `${capType || 'Spend'} cap`;
    const period = mapPeriod(firstDefined(c.capping_period, c.period), report);

    const targetIds = Array.isArray(c.target_rule_ids)
      ? c.target_rule_ids
      : c.reward_rule_id
        ? [c.reward_rule_id]
        : [];
    const capLocalId = firstDefined(c.cap_id, c.id);
    const referencedRewardIds = capLocalId ? capReferenceToRewardIds[capLocalId] || [] : [];
    const scope =
      c.scope ||
      (targetIds.length === 1 || referencedRewardIds.length === 1
        ? 'rule_specific'
        : 'aggregate_card');
    // Aggregate-scope caps can still be enforced when their source category
    // maps cleanly: the engine matches caps by reward_rule_id OR category_id.
    // A cap with neither key is reference-only and is reported separately.
    const rewardRuleId =
      scope === 'rule_specific'
        ? targetIds.length === 1
          ? localIdToUuid[targetIds[0]] || null
          : referencedRewardIds.length === 1
            ? referencedRewardIds[0]
            : null
        : null;
    if (scope === 'aggregate_card' || targetIds.length > 1 || referencedRewardIds.length > 1) {
      report.aggregateScopeCaps.push({ card_product_id: cardProductId, label });
    }

    const categoryId =
      firstDefined(c.category_id) && CATEGORY_MAP[c.category_id]
        ? CATEGORY_MAP[c.category_id]
        : rewardRuleId
          ? categoryByLocalRewardId[targetIds[0]] || null
          : null;
    if (!rewardRuleId && !categoryId) {
      report.unenforcedCaps.push({ card_product_id: cardProductId, label, source_cap_id: capLocalId });
    }

    const post = c.post_limit_behavior || {};
    let postCapUnit = null;
    let postCapRate = null;
    if (post.action === 'zero_accrual') {
      postCapUnit = 'cashback_percent';
      postCapRate = 0;
    } else if (asNumber(post.cashback_percent) !== null) {
      postCapUnit = 'cashback_percent';
      postCapRate = asNumber(post.cashback_percent);
    } else if (asNumber(post.points_per_block) !== null && post.action !== 'downgrade_to_base_rate') {
      const mapped = pointsUnitAndRate(
        asNumber(post.points_per_block),
        asNumber(cardBaseBlockInr),
        report
      );
      postCapUnit = mapped.unit;
      postCapRate = mapped.rate;
    }

    await client.query(
      `INSERT INTO cap_rules
         (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value,
          post_cap_unit, post_cap_rate, resets_on_day)
       VALUES ($1, $2, (select id from spend_categories where slug = $3), $4, $5, $6, $7,
         $8, $9, $10)`,
      [
        cardProductId,
        rewardRuleId,
        categoryId,
        label,
        measure,
        period,
        capValue,
        postCapUnit,
        postCapRate,
        Number.isInteger(c.reset_day) ? c.reset_day : null,
      ]
    );
  }
}

async function importMilestoneRules(client, cardProductId, milestones, report) {
  for (const m of milestones || []) {
    const threshold = asNumber(m.threshold_spend_inr);
    const rewardValue = asNumber(m.reward_value_inr);
    if (threshold === null || rewardValue === null) continue; // not-null columns; nothing safe to insert
    const cpPeriod = m.period;
    const period = mapPeriod(cpPeriod, report);
    // CardPipeline conflates period+anchor into one field
    // ('card_anniversary_year' etc.); PandaPay keeps them separate.
    const anchor = cpPeriod === 'card_anniversary_year' ? 'card_anniversary' : 'card_anniversary';
    await client.query(
      `INSERT INTO milestone_rules
         (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable, anchor)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        cardProductId,
        m.label || `₹${rewardValue} at ₹${threshold} spend`,
        period,
        threshold,
        m.label || `Reward worth ₹${rewardValue}`,
        rewardValue,
        m.is_repeatable === true,
        anchor,
      ]
    );
  }
}

async function importFeeWaiverRule(client, cardProductId, waiver, report) {
  if (!waiver) return;
  const threshold = asNumber(waiver.threshold_spend_inr);
  const waivesFee = asNumber(waiver.waives_fee_inr);
  if (threshold === null || waivesFee === null) return; // e.g. lifetime-free cards: N/A by design
  const excludedIds = Array.isArray(waiver.excluded_category_ids) ? waiver.excluded_category_ids : [];
  const excludedSlugs = excludedIds.map((id) => CATEGORY_MAP[id]).filter(Boolean);

  await client.query(
    `INSERT INTO fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr, excluded_categories, notes)
     VALUES ($1, $2, $3, $4,
       (select coalesce(array_agg(id), '{}') from spend_categories where slug = any($5::text[])),
       $6)`,
    [
      cardProductId,
      threshold,
      mapPeriod(waiver.period, report),
      waivesFee,
      excludedSlugs,
      isNA(waiver.evaluation_condition) ? null : waiver.evaluation_condition,
    ]
  );
}

async function importBenefits(client, cardProductId, lifestyle, insurance) {
  for (const b of lifestyle || []) {
    const kind = guessBenefitKind(b.category_id, b.label, b.benefit_id, b.network_program);
    await client.query(
      `INSERT INTO card_benefits (card_product_id, kind, label, description, quota_count, quota_period, network_program, value_estimate_inr, conditions)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [
        cardProductId,
        kind,
        b.label || b.benefit_id || 'Benefit',
        isNA(b.sponsor) ? null : `Sponsor: ${b.sponsor}`,
        Number.isInteger(b.quota_count) ? b.quota_count : null,
        PERIOD_MAP[b.quota_period] || null,
        isNA(b.network_program) ? null : b.network_program,
        asNumber(b.value_estimate_inr),
        JSON.stringify({ source_category_id: b.category_id || null, evaluation_engine: b.evaluation_engine || null }),
      ]
    );
  }
  for (const ins of insurance || []) {
    const kind = guessBenefitKind(ins.cover_type);
    const label = String(ins.cover_type || 'insurance_cover')
      .replace(/_/g, ' ')
      .replace(/\b\w/g, (c) => c.toUpperCase());
    await client.query(
      `INSERT INTO card_benefits (card_product_id, kind, label, description, value_estimate_inr, conditions)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        cardProductId,
        kind,
        label,
        isNA(ins.claim_condition) ? null : ins.claim_condition,
        asNumber(ins.coverage_inr),
        JSON.stringify({ coverage_usd: isNA(ins.coverage_usd) ? null : ins.coverage_usd }),
      ]
    );
  }
}

async function importForexAndFuel(client, cardProductId, fees, report) {
  const forex = fees?.forex_markup;
  if (forex && !isNA(forex.markup_percent)) {
    await client.query(
      `INSERT INTO forex_rules (card_product_id, markup_percent, gst_on_markup)
       VALUES ($1, $2, $3)
       ON CONFLICT (card_product_id) DO UPDATE SET markup_percent = EXCLUDED.markup_percent, gst_on_markup = EXCLUDED.gst_on_markup`,
      [cardProductId, asNumber(forex.markup_percent), forex.gst_applicable !== false]
    );
  }
  const fuel = fees?.fuel_surcharge;
  if (fuel && (!isNA(fuel.surcharge_percent) || !isNA(fuel.waiver_percent))) {
    const surchargePercent = asNumber(fuel.surcharge_percent) ?? 1.0;
    let waiverPercent = asNumber(fuel.waiver_percent) ?? 0;
    if (waiverPercent === 100) {
      // Most pipeline records express a full 1% surcharge waiver as `1`.
      // A few use `100` to mean 100% OF the surcharge; normalise those to
      // the same one-percentage-point database representation. Besides
      // being semantically equivalent, numeric(6,4) cannot store 100.
      waiverPercent = surchargePercent;
      report.warnings.push(
        `Normalised fuel waiver_percent=100 to ${surchargePercent} percentage point(s) for card ${cardProductId}.`
      );
    }
    await client.query(
      `INSERT INTO fuel_surcharge_rules (card_product_id, surcharge_percent, waiver_percent, min_txn_inr, max_txn_inr, monthly_waiver_cap)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (card_product_id) DO UPDATE SET
         surcharge_percent = EXCLUDED.surcharge_percent, waiver_percent = EXCLUDED.waiver_percent,
         min_txn_inr = EXCLUDED.min_txn_inr, max_txn_inr = EXCLUDED.max_txn_inr,
         monthly_waiver_cap = EXCLUDED.monthly_waiver_cap`,
      [
        cardProductId,
        surchargePercent,
        waiverPercent,
        asNumber(fuel.min_txn_inr),
        asNumber(fuel.max_txn_inr),
        asNumber(fuel.monthly_waiver_cap_inr),
      ]
    );
  }
}

async function importBillingCycle(client, cardProductId, statementAndLateFees) {
  const grace = asNumber(statementAndLateFees?.grace_period_days);
  if (grace === null) return;
  await client.query(
    `INSERT INTO billing_cycle_rules (card_product_id, grace_period_days)
     VALUES ($1, $2)
     ON CONFLICT (card_product_id) DO UPDATE SET grace_period_days = EXCLUDED.grace_period_days`,
    [cardProductId, grace]
  );
}

async function importRedemptionOptions(client, cardProductId, redemption, report) {
  for (const opt of redemption?.direct_options || []) {
    let value = asNumber(opt.inr_value_per_point);
    if (value === null) {
      if (opt.redemption_type === 'statement_credit') value = 1.0; // ₹1 credit = ₹1 value, by definition
      else {
        report.skippedRedemptionOptions.push({ card_product_id: cardProductId, reason: 'no inr_value_per_point', raw: opt });
        continue;
      }
    }
    await client.query(
      `INSERT INTO redemption_options (card_product_id, program_name, method, value_per_point_inr, min_points, notes)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        cardProductId,
        opt.channel || 'Direct redemption',
        opt.redemption_type || 'other',
        value,
        Number.isInteger(opt.min_points_per_txn) ? opt.min_points_per_txn : null,
        isNA(opt.redemption_fee_inr) ? null : `Redemption fee: ₹${opt.redemption_fee_inr}`,
      ]
    );
  }
  // partner_transfers[] give a points<->miles ratio, never a ₹ value —
  // value_per_point_inr is NOT NULL, and fabricating a rupee value from a
  // transfer ratio alone (without the partner program's own valuation)
  // would be a made-up number presented as fact. Skipped, not guessed.
  for (const partner of redemption?.partner_transfers || []) {
    report.skippedRedemptionOptions.push({
      card_product_id: cardProductId,
      reason: 'partner_transfer has no direct ₹/point value',
      raw: { partner_code: partner.partner_code, program_name: partner.program_name },
    });
  }
}

async function importNetworkVariants(client, cardProductId, record, report) {
  const variants = extractVerifiedNetworkVariants(record);
  for (const variant of variants) {
    await client.query(
      `INSERT INTO card_product_network_variants
         (card_product_id, network, network_tier, label, source_url, evidence)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (card_product_id, network, network_tier) DO UPDATE SET
         label = EXCLUDED.label,
         source_url = EXCLUDED.source_url,
         evidence = EXCLUDED.evidence,
         is_active = true`,
      [
        cardProductId,
        variant.network,
        variant.networkTier,
        variant.label,
        variant.sourceUrl,
        variant.evidence,
      ]
    );
  }
  report.networkVariantsImported += variants.length;
}

function buildExtendedData(record) {
  const { card_product, reward_rules, cap_rules, fees_and_surcharges, ...rest } = record;
  const unsupportedRewardRules = (reward_rules || []).filter((rule) => {
    const category = rule.category_id;
    return !isNA(category) && category !== CATEGORY_ALL_RETAIL && !CATEGORY_MAP[category];
  });
  const sectionGaps = missingSections(record);
  return {
    schema_version: record.schema_version,
    // Non-empty means the extraction was truncated: the blanks below are
    // "not extracted", NOT "this card has none". See EXPECTED_RECORD_SECTIONS.
    incomplete_extraction_sections: sectionGaps.length ? sectionGaps : undefined,

    // Full source product metadata is reviewer context. The structured
    // columns remain the runtime source of truth; this preserves schema
    // fields PandaPay does not model yet without losing them on import.
    card_product_source: card_product,
    unmapped_reward_rules: unsupportedRewardRules,
    // Cap rows have no generic JSON conditions column, so retain the exact
    // source shapes (including MCC lists and effective windows) alongside
    // their structured projections.
    source_cap_rules: cap_rules,
    eligibility_engine: rest.eligibility_engine,
    fees_and_surcharges_extra: fees_and_surcharges
      ? { ...fees_and_surcharges, forex_markup: undefined, fuel_surcharge: undefined }
      : undefined,
    statement_and_late_fees: rest.statement_and_late_fees,
    addon_card_rules: rest.addon_card_rules,
    brand_specific_voucher_caps: rest.brand_specific_voucher_caps,
    dynamic_promotions_registry: rest.dynamic_promotions_registry,
    additional_data: rest.additional_data,
  };
}

async function importOneCard(client, adminId, record, indexEntry, force, report) {
  const cp = record.card_product;
  const issuerId = await resolveIssuer(client, cp.issuer_slug, report);
  const hash = sourceHash(record);
  const economics = deriveCardEconomics(record, report);

  const { cardProductId, action, existingStatus, sourceChanged, transformChanged } =
    await upsertCardProduct(
      client,
      issuerId,
      cp,
      buildExtendedData(record),
      economics,
      force,
      hash,
      indexEntry?.runId || null
    );

  if (action === 'unchanged') {
    report.unchanged.push({ slug: cp.slug, name: cp.name, cardProductId, status: existingStatus });
    return;
  }

  if (action === 'skipped_reviewed') {
    report.skipped.push({
      slug: cp.slug,
      reason: sourceChanged
        ? `source changed but card is already ${existingStatus}; review and use --force to override`
        : transformChanged
          ? `import mapping changed but card is already ${existingStatus}; review and use --force to rebuild`
          : `already ${existingStatus} and has no prior source fingerprint; use --force to override`,
    });
    return;
  }

  await importNetworkVariants(client, cardProductId, record, report);

  const { localIdToUuid, capReferenceToRewardIds } = await importRewardRules(
    client, cardProductId, record.reward_rules, asNumber(record.accrual_engine?.base_block_inr), report
  );
  const categoryByLocalRewardId = {};
  for (const r of record.reward_rules || []) {
    if (r.id) categoryByLocalRewardId[r.id] = CATEGORY_MAP[r.category_id] || null;
  }
  await importCapRules(
    client,
    cardProductId,
    record.cap_rules,
    localIdToUuid,
    capReferenceToRewardIds,
    categoryByLocalRewardId,
    economics.pointValueInr,
    asNumber(record.accrual_engine?.base_block_inr),
    report
  );
  await importMilestoneRules(client, cardProductId, record.fee_waiver_and_milestones?.spend_milestones, report);
  await importFeeWaiverRule(client, cardProductId, record.fee_waiver_and_milestones?.annual_fee_waiver, report);
  await importBenefits(client, cardProductId, record.lifestyle_and_network_benefits, record.insurance_and_protection);
  await importForexAndFuel(client, cardProductId, record.fees_and_surcharges, report);
  await importBillingCycle(client, cardProductId, record.statement_and_late_fees);
  await importRedemptionOptions(client, cardProductId, record.redemption_matrix, report);

  await client.query(
    `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, reason)
     VALUES ($1, $2, 'card_products', $3, $4)`,
    [
      adminId,
      action === 'created' ? 'import_card_product' : 'import_refresh_card_product',
      cardProductId,
      `CardPipeline import: ${cp.slug}${indexEntry ? ` (checklist id: ${indexEntry.id}, run: ${indexEntry.runId || 'unknown'})` : ''}; source sha256 ${hash}; transform ${IMPORT_TRANSFORM_VERSION}`,
    ]
  );

  (action === 'created' ? report.created : report.updated).push({ slug: cp.slug, name: cp.name, cardProductId });
}

// ───────────────────────────────────────────────────────────────────────
// Main
// ───────────────────────────────────────────────────────────────────────
function newReport() {
  return {
    transformVersion: IMPORT_TRANSFORM_VERSION,
    created: [], updated: [], unchanged: [], skipped: [], skippedGarbage: [], failed: [],
    issuersCreated: [], issuerResolutions: [],
    unmappedCategories: {}, skippedCategories: [], unmappedPeriods: {}, unmappedRails: {},
    unusualBlockSizes: {}, aggregateScopeCaps: [], unenforcedCaps: [],
    skippedCapRules: [], skippedRedemptionOptions: [],
    // Cards that imported with network='unknown' and cannot be published
    // until a human sets one, plus verified variant sets that migration 0043
    // makes publishable without inventing a scalar network.
    unresolvedNetworks: [], incompleteRecords: [],
    networkVariantCards: [], networkVariantsImported: 0,
    // Zero-rate rules dropped because the engine cannot see what narrows
    // them, and unrecognised condition keys that might be the next such gap.
    unenforceableExclusions: [], unmappedConditionKeys: {},
    unusableMerchantPatterns: [],
    warnings: [],
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(
      'Usage: node import_card_pipeline.js --input <all-collected.json> ' +
        '[--admin-id <uuid>] [--report-dir <dir>] [--slug <card-slug>] ' +
        '[--dry-run] [--force]\n' +
        'CARD_IMPORT_ADMIN_ID may be used instead of --admin-id.'
    );
    return;
  }
  if (!args.input) {
    throw new Error('--input is required (the collected all-collected.json file).');
  }
  if (!args.adminId) {
    throw new Error(
      '--admin-id or CARD_IMPORT_ADMIN_ID is required (a real, active admin_users.id).'
    );
  }

  const report = newReport();
  const records = JSON.parse(fs.readFileSync(args.input, 'utf8'));
  if (!Array.isArray(records)) throw new Error(`${args.input} must contain a JSON array.`);
  const index = loadIndex(args.input, report);
  if (index && index.length !== records.length) {
    throw new Error(
      `all-collected-index.json has ${index.length} row(s), but the input has ${records.length}; ` +
        'refusing a positionally misaligned import.'
    );
  }
  const requestedSlugs = new Set(args.slugs);
  const selectedIndexes = records
    .map((record, i) => ({ i, slug: record?.card_product?.slug }))
    .filter(({ slug }) => requestedSlugs.size === 0 || requestedSlugs.has(slug))
    .map(({ i }) => i);
  if (requestedSlugs.size > 0) {
    const found = new Set(selectedIndexes.map((i) => records[i]?.card_product?.slug));
    const missing = [...requestedSlugs].filter((slug) => !found.has(slug));
    if (missing.length) throw new Error(`--slug not found in input: ${missing.join(', ')}`);
  }

  const pool = createPool();
  const lockClient = await pool.connect().catch(async (error) => {
    await pool.end();
    throw error;
  });
  let lockAcquired = false;
  let hadDatabaseFailure = false;
  try {
    const lockResult = await lockClient.query(
      "select pg_try_advisory_lock(hashtextextended('pandapay.card_catalogue_import', 0)) as acquired"
    );
    lockAcquired = lockResult.rows[0]?.acquired === true;
    if (!lockAcquired) {
      throw new Error('another card catalogue import is already running; try again after it finishes.');
    }

    // Fail once, before touching any card, when the deploy has not applied
    // migration 0041. Otherwise every row would report the same missing
    // column error and the automation could misleadingly exit successfully.
    const requiredColumns = [
      'import_source_hash',
      'import_source_run_id',
      'import_transform_version',
      'imported_at',
    ];
    const columns = await pool.query(
      `select column_name from information_schema.columns
        where table_schema = 'public' and table_name = 'card_products'
          and column_name = any($1::text[])`,
      [requiredColumns]
    );
    const present = new Set(columns.rows.map((row) => row.column_name));
    const missing = requiredColumns.filter((column) => !present.has(column));
    if (missing.length) {
      throw new Error(
        `database is missing ${missing.join(', ')}; apply migration 0041_card_import_provenance.sql first.`
      );
    }
    const variantsTable = await pool.query(
      `select to_regclass('public.card_product_network_variants') as table_name`
    );
    if (!variantsTable.rows[0]?.table_name) {
      throw new Error(
        'database is missing card_product_network_variants; apply migration ' +
        '0043_card_product_network_variants.sql first.'
      );
    }

    // Set app.user_id even for the preflight read. admin_users has FORCE RLS,
    // so a naked SELECT with the app role can never see the row it is trying
    // to validate.
    const adminCheck = await withAdminClient(pool, args.adminId, (client) =>
      client.query('SELECT is_active FROM admin_users WHERE id = $1', [args.adminId])
    );
    if (adminCheck.rows.length === 0 || !adminCheck.rows[0].is_active) {
      throw new Error(
        `--admin-id ${args.adminId} is not an active row in admin_users. ` +
          'Every write here needs pandapay.is_admin() to be true for this id.'
      );
    }

    console.log(
      `Importing ${selectedIndexes.length} record(s) from ${args.input}${args.dryRun ? ' (DRY RUN)' : ''}`
    );
    if (args.dryRun) {
      console.log(
        'Note: each card runs in its own transaction that is rolled back, so ' +
          'counts like "issuers created" will overcount vs. a real run — an ' +
          'issuer created for card #1 is rolled back before card #2 runs, so ' +
          'it looks newly-created again instead of being reused.'
      );
    }

    const seenImportSlugs = new Set();
    for (const i of selectedIndexes) {
      const record = records[i];
      const indexEntry = index ? index[i] : null;
      const failReason = sanityCheck(record, indexEntry, report);
      if (failReason) {
        report.skippedGarbage.push({ slug: record?.card_product?.slug || '(no slug)', reason: failReason });
        continue;
      }
      const slug = record.card_product.slug;
      if (seenImportSlugs.has(slug)) {
        report.skippedGarbage.push({
          slug,
          reason: 'duplicate usable slug in this input; first checklist occurrence won',
        });
        continue;
      }
      seenImportSlugs.add(slug);

      try {
        await withAdminClient(pool, args.adminId, async (client) => {
          await importOneCard(client, args.adminId, record, indexEntry, args.force, report);
          if (args.dryRun) throw new Error('__DRY_RUN_ROLLBACK__');
        });
      } catch (err) {
        // Report entries (report.created/updated/etc.) are pushed by
        // importOneCard BEFORE this throw fires, so dry-run still shows what
        // WOULD have happened even though the transaction below rolls back.
        if (err.message === '__DRY_RUN_ROLLBACK__') continue;
        hadDatabaseFailure = true;
        report.failed.push({ slug, reason: `DB error: ${err.message}` });
      }
    }

    const reportDir = path.resolve(args.reportDir || path.dirname(args.input));
    fs.mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, `import-report-${Date.now()}.json`);
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    console.log('\n─── Import report ───');
    console.log(`created:            ${report.created.length}`);
    console.log(`updated (refreshed): ${report.updated.length}`);
    console.log(`unchanged (no-op):  ${report.unchanged.length}`);
    console.log(`skipped (reviewed): ${report.skipped.length}`);
    console.log(`skipped (garbage/invalid): ${report.skippedGarbage.length}`);
    console.log(`failed (database):  ${report.failed.length}`);
    console.log(`issuers created:    ${report.issuersCreated.length}`);
    if (Object.keys(report.unmappedCategories).length) {
      console.log('unmapped categories:', report.unmappedCategories);
    }
    if (report.unenforcedCaps.length) {
      console.log(
        `caps retained for review but not enforced (no rule/category link): ${report.unenforcedCaps.length}`
      );
    }
    // These three are review work, not errors — each one is a place the
    // source said something the catalogue schema cannot hold exactly.
    if (report.unresolvedNetworks.length) {
      console.log(
        `network unresolved (imported as 'unknown', BLOCKS publishing until set): ${report.unresolvedNetworks.length}`
      );
    }
    if (report.networkVariantCards.length) {
      console.log(
        `verified multi-network products: ${report.networkVariantCards.length} ` +
        `(${report.networkVariantsImported} variant rows written)`
      );
    }
    if (report.incompleteRecords.length) {
      console.log(`\nIncomplete extractions (imported, but sections are MISSING not empty):`);
      for (const r of report.incompleteRecords) {
        console.log(`  - ${r.slug}: missing ${r.missing.join(', ')}`);
      }
    }
    if (report.unenforceableExclusions.length) {
      console.log(
        `zero-rate rules dropped as unenforceable (would have shadowed a real rate): ${report.unenforceableExclusions.length}`
      );
    }
    if (report.unusableMerchantPatterns.length) {
      console.log(
        `merchant patterns rejected as prose: ${report.unusableMerchantPatterns.length}`
      );
    }
    if (Object.keys(report.unmappedConditionKeys).length) {
      console.log('threshold-shaped condition keys NOT read:', report.unmappedConditionKeys);
    }
    if (report.skippedGarbage.length) {
      console.log('\nSkipped (garbage/invalid):');
      for (const s of report.skippedGarbage) console.log(`  - ${s.slug}: ${s.reason}`);
    }
    if (report.failed.length) {
      console.log('\nDatabase failures:');
      for (const failure of report.failed) console.log(`  - ${failure.slug}: ${failure.reason}`);
    }
    console.log(`\nFull report written to ${reportPath}`);

    if (hadDatabaseFailure) process.exitCode = 1;
  } finally {
    if (lockAcquired) {
      await lockClient
        .query("select pg_advisory_unlock(hashtextextended('pandapay.card_catalogue_import', 0))")
        .catch(() => {});
    }
    lockClient.release();
    await pool.end();
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error('Fatal error:', err.message || err);
    process.exitCode = 1;
  });
}

module.exports = {
  canonicalize,
  missingSections,
  resolveNetwork,
  shadowingZeroRateRules,
  unmappedNarrowing,
  usableMerchantPattern,
  MIN_TXN_KEYS,
  deriveCardEconomics,
  extractVerifiedNetworkVariants,
  hasExplicitNoRewardProgram,
  IMPORT_TRANSFORM_VERSION,
  importCapRules,
  importNetworkVariants,
  importRewardRules,
  importOneCard,
  mapCategory,
  parseArgs,
  pointsUnitAndRate,
  sanityCheck,
  sourceHash,
  upsertCardProduct,
};
