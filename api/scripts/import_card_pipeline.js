#!/usr/bin/env node
/**
 * Bulk-imports CardPipeline's LLM-extracted card records
 * (../../../CardPipeline/results/all-collected.json — a sibling project,
 * see its README) into this database's card catalogue tables.
 *
 * Usage:
 *   node api/scripts/import_card_pipeline.js \
 *     --input /path/to/CardPipeline/results/all-collected.json \
 *     --admin-id <admin_users.id> \
 *     [--dry-run] [--force]
 *
 * Before running: inside CardPipeline, run `node src/cli.js export` to
 * rebuild all-collected.json from every completed run — the file on disk
 * is only refreshed on demand, not automatically after each card.
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
 * still goes through the exact same validated-field discipline as the
 * admin API (imports `validateField` from admin_rule_families.js) and
 * writes its own admin_audit_log row per write, in the same DB
 * transaction as the data — so nothing loses the audit trail just because
 * the transport is direct-to-Postgres instead of HTTP.
 *
 * Every card lands as status='draft', full stop. This script never sets
 * status='published' or touches verified_at/verified_by — the only way a
 * card reaches 'published' is a human going through
 * POST /admin/cards/:id/status (or the console's equivalent button),
 * matching this codebase's "AI extracts, human verifies, never
 * auto-published" rule everywhere else card data is written.
 */

'use strict';

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const { validateField } = require('../src/admin_rule_families');

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
const DATABASE_URL = process.env.DATABASE_URL || process.env.ADMIN_DATABASE_URL;
if (!DATABASE_URL) {
  console.error('DATABASE_URL (or ADMIN_DATABASE_URL) must be set.');
  process.exit(1);
}
const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
});

async function withAdminClient(adminId, fn) {
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
  const args = { dryRun: false, force: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--input') args.input = argv[++i];
    else if (a === '--admin-id') args.adminId = argv[++i];
    else if (a === '--dry-run') args.dryRun = true;
    else if (a === '--force') args.force = true;
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
  gift_vouchers: 'other',
};
// Not a positive reward category at all — importing a "5% cashback on
// cash_advance" row would be actively wrong (cash advances don't earn
// rewards on any real card), and excluded_spend already gets expressed
// as a rate=0 rule on the category IT excludes (see the real "utility"
// exclusion example), not as its own category.
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
function mapNetwork(raw) {
  if (isNA(raw)) return null;
  return NETWORK_MAP[String(raw).toLowerCase().trim()] || null;
}

const CARD_TYPES = ['credit', 'debit', 'prepaid', 'forex'];
const REWARD_UNITS = [
  'cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200',
  'miles_per_100', 'flat_points', 'discount_percent',
];
const CAP_MEASURES = ['reward_value', 'spend_amount', 'txn_count'];
const BENEFIT_KINDS = [
  'lounge_domestic', 'lounge_international', 'golf', 'concierge', 'insurance_travel',
  'insurance_purchase', 'extended_warranty', 'dining_program', 'movie', 'fuel_surcharge',
  'roadside_assistance', 'other',
];

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

function normalizeTokens(str) {
  if (!str) return new Set();
  return new Set(
    String(str)
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, ' ')
      .split(/\s+/)
      .filter((t) => t && !STOPWORDS.has(t))
  );
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
  return { skip: false, categoryId: 'other' };
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
  if (!mapNetwork(record?.card_product?.network)) {
    return `card_product.network missing, unrecognized, or ambiguous ("${record?.card_product?.network}")`;
  }
  const hasRewardRule = Array.isArray(record.reward_rules) && record.reward_rules.length > 0;
  const hasBaseRate =
    !isNA(record?.accrual_engine?.base_cashback_percent) ||
    !isNA(record?.accrual_engine?.base_points_per_block);
  if (!hasRewardRule && !hasBaseRate) {
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

// Returns { cardProductId, action: 'created'|'refreshed'|'skipped_reviewed', existingStatus? }
async function upsertCardProduct(client, issuerId, cp, extendedData, force) {
  const existing = await client.query(
    'SELECT id, status FROM card_products WHERE slug = $1',
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
  };

  if (existing.rows.length === 0) {
    const inserted = await client.query(
      `INSERT INTO card_products (slug, status, issuer_id, name, network, card_type,
         joining_fee_inr, annual_fee_inr, is_upi_linkable, source_url, extended_data)
       VALUES ($1, 'draft', $2, $3, $4, $5, $6, $7, $8, $9, $10)
       RETURNING id`,
      [
        cp.slug, baseValues.issuer_id, baseValues.name, baseValues.network, baseValues.card_type,
        baseValues.joining_fee_inr, baseValues.annual_fee_inr, baseValues.is_upi_linkable,
        baseValues.source_url, baseValues.extended_data,
      ]
    );
    return { cardProductId: inserted.rows[0].id, action: 'created' };
  }

  const row = existing.rows[0];
  // Idempotency is tied to REVIEW STATE, not just presence: a human who
  // has already started reviewing (in_review) or approved (published) a
  // card must not have that silently overwritten by a re-run just because
  // more of CardPipeline's 392 cards finished extracting. --force exists
  // for the deliberate "re-import anyway" case; without it this is a
  // no-op, reported so it's visible rather than silently doing nothing.
  if (row.status !== 'draft' && !force) {
    return { cardProductId: row.id, action: 'skipped_reviewed', existingStatus: row.status };
  }

  await client.query(
    `UPDATE card_products SET
       issuer_id = $2, name = $3, network = $4, card_type = $5,
       joining_fee_inr = $6, annual_fee_inr = $7, is_upi_linkable = $8,
       source_url = $9, extended_data = $10
     WHERE id = $1`,
    [
      row.id, baseValues.issuer_id, baseValues.name, baseValues.network, baseValues.card_type,
      baseValues.joining_fee_inr, baseValues.annual_fee_inr, baseValues.is_upi_linkable,
      baseValues.source_url, baseValues.extended_data,
    ]
  );
  // The JSON is the source of truth until a human starts reviewing, so a
  // refresh is delete-and-reinsert for the list-shaped children rather
  // than trying to diff/patch rows that have no stable key from
  // CardPipeline's side (its local reward-rule "id" strings are only
  // unique within one extraction, not a real primary key we can match
  // against on a re-run).
  for (const table of ['reward_rules', 'cap_rules', 'milestone_rules', 'fee_waiver_rules', 'card_benefits', 'redemption_options']) {
    await client.query(`DELETE FROM ${table} WHERE card_product_id = $1`, [row.id]);
  }
  return { cardProductId: row.id, action: row.status === 'draft' ? 'refreshed' : 'refreshed_forced', existingStatus: row.status };
}

async function importRewardRules(client, cardProductId, rules, cardBaseBlockInr, report) {
  const localIdToUuid = {};
  for (const r of rules || []) {
    const { skip, categoryId } = mapCategory(r.category_id, report, `reward_rule ${r.id || ''}`);
    if (skip) continue;

    const cashback = asNumber(r.action?.cashback_percent);
    const pointsPerBlock = asNumber(r.action?.points_per_block);
    let unit = 'cashback_percent';
    let rate = 0;
    if (cashback !== null) {
      unit = 'cashback_percent';
      rate = cashback;
    } else if (pointsPerBlock !== null) {
      // block size is a card-level constant (accrual_engine.base_block_inr),
      // not a per-rule field — every points-earning rule on one card shares
      // the same ₹ block.
      const block = cardBaseBlockInr;
      if (block === 100) unit = 'points_per_100';
      else if (block === 150) unit = 'points_per_150';
      else if (block === 200) unit = 'points_per_200';
      else {
        unit = 'points_per_100';
        if (block !== null) report.unusualBlockSizes[block] = (report.unusualBlockSizes[block] || 0) + 1;
      }
      rate = pointsPerBlock;
    } else {
      // Exclusion rules (multiplier: 0) commonly have both "N/A" — a zero
      // rate in any unit is equivalent, and this row still matters: it's
      // what makes the engine correctly return ₹0 for this category
      // instead of silently falling through to the card's base rate.
      unit = 'cashback_percent';
      rate = 0;
    }

    const conditions = {
      source_local_id: r.id || null,
      evaluation_type: r.evaluation_type || null,
      channel_type: r.channel_type || null,
      cap_reference: r.action?.cap_reference || null,
      source_conditions: r.conditions || null,
    };

    const inserted = await client.query(
      `INSERT INTO reward_rules
         (card_product_id, category_id, rail, unit, rate, priority, conditions, effective_from, effective_to)
       VALUES ($1, (select id from spend_categories where slug = $2), $3, $4, $5, $6, $7, $8, $9)
       RETURNING id`,
      [
        cardProductId,
        categoryId,
        mapRail(r.rail, report),
        unit,
        rate,
        Number.isInteger(r.priority) ? r.priority : 100,
        JSON.stringify(conditions),
        isNA(r.effective_from) ? null : r.effective_from,
        isNA(r.effective_to) ? null : r.effective_to,
      ]
    );
    if (r.id) localIdToUuid[r.id] = inserted.rows[0].id;
  }
  return localIdToUuid;
}

// cap_rules' REAL shape ({cap_id, scope, target_rule_ids, cap_type,
// cap_limit, capping_period, description}) differs from the documented
// template ({id, category_id, metric, limit_value_inr, period,
// post_limit_behavior, ...}) — confirmed by reading actual extracted
// records, not assumed from the schema file. firstDefined() below reads
// whichever shape (or mix) a given record actually used.
async function importCapRules(client, cardProductId, caps, localIdToUuid, categoryByLocalRewardId, report) {
  for (const c of caps || []) {
    const capValue = asNumber(firstDefined(c.cap_limit, c.limit_value_inr, c.limit_value));
    if (capValue === null) {
      report.skippedCapRules.push({ card_product_id: cardProductId, reason: 'no usable cap value', raw: c });
      continue;
    }
    const capType = (firstDefined(c.cap_type, c.metric) || '').toLowerCase();
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
    const scope = c.scope || (targetIds.length === 1 ? 'rule_specific' : 'aggregate_card');
    // Aggregate-scope caps (span multiple reward rules, e.g. "combined
    // cashback capped at ₹4,000/cycle") import with reward_rule_id=null —
    // visible in the console and export views, but NOT enforced by
    // RecommendationEngine._evaluate() today, which only matches a cap via
    // capRules.where(c => c.rewardRuleId == rule.id). That's a real,
    // separate engine gap; recorded, not silently worked around here.
    const rewardRuleId =
      scope === 'rule_specific' && targetIds.length === 1 ? localIdToUuid[targetIds[0]] || null : null;
    if (scope === 'aggregate_card' || (targetIds.length > 1)) {
      report.aggregateScopeCaps.push({ card_product_id: cardProductId, label });
    }

    const categoryId =
      firstDefined(c.category_id) && CATEGORY_MAP[c.category_id]
        ? CATEGORY_MAP[c.category_id]
        : rewardRuleId
          ? categoryByLocalRewardId[targetIds[0]] || null
          : null;

    await client.query(
      `INSERT INTO cap_rules
         (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_rate)
       VALUES ($1, $2, (select id from spend_categories where slug = $3), $4, $5, $6, $7, 0)`,
      [cardProductId, rewardRuleId, categoryId, label, measure, period, capValue]
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

async function importForexAndFuel(client, cardProductId, fees) {
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
    await client.query(
      `INSERT INTO fuel_surcharge_rules (card_product_id, surcharge_percent, waiver_percent, min_txn_inr, max_txn_inr, monthly_waiver_cap)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (card_product_id) DO UPDATE SET
         surcharge_percent = EXCLUDED.surcharge_percent, waiver_percent = EXCLUDED.waiver_percent,
         min_txn_inr = EXCLUDED.min_txn_inr, max_txn_inr = EXCLUDED.max_txn_inr,
         monthly_waiver_cap = EXCLUDED.monthly_waiver_cap`,
      [
        cardProductId,
        asNumber(fuel.surcharge_percent) ?? 1.0,
        asNumber(fuel.waiver_percent) ?? 0,
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

function buildExtendedData(record) {
  const { card_product, reward_rules, cap_rules, fees_and_surcharges, ...rest } = record;
  const { network_tier, card_tier, bin_ranges, application_mode, form_factors, tokenization_support, data_source_tier, ...cpRest } =
    card_product || {};
  return {
    schema_version: record.schema_version,
    card_product_extras: { network_tier, card_tier, bin_ranges, application_mode, form_factors, tokenization_support, data_source_tier },
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

  const { cardProductId, action, existingStatus } = await upsertCardProduct(
    client, issuerId, cp, buildExtendedData(record), force
  );

  if (action === 'skipped_reviewed') {
    report.skipped.push({ slug: cp.slug, reason: `already ${existingStatus}, use --force to override` });
    return;
  }

  const localIdToUuid = await importRewardRules(
    client, cardProductId, record.reward_rules, asNumber(record.accrual_engine?.base_block_inr), report
  );
  const categoryByLocalRewardId = {};
  for (const r of record.reward_rules || []) {
    if (r.id) categoryByLocalRewardId[r.id] = CATEGORY_MAP[r.category_id] || null;
  }
  await importCapRules(client, cardProductId, record.cap_rules, localIdToUuid, categoryByLocalRewardId, report);
  await importMilestoneRules(client, cardProductId, record.fee_waiver_and_milestones?.spend_milestones, report);
  await importFeeWaiverRule(client, cardProductId, record.fee_waiver_and_milestones?.annual_fee_waiver, report);
  await importBenefits(client, cardProductId, record.lifestyle_and_network_benefits, record.insurance_and_protection);
  await importForexAndFuel(client, cardProductId, record.fees_and_surcharges);
  await importBillingCycle(client, cardProductId, record.statement_and_late_fees);
  await importRedemptionOptions(client, cardProductId, record.redemption_matrix, report);

  await client.query(
    `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, reason)
     VALUES ($1, $2, 'card_products', $3, $4)`,
    [
      adminId,
      action === 'created' ? 'import_card_product' : 'import_refresh_card_product',
      cardProductId,
      `CardPipeline import: ${cp.slug}${indexEntry ? ` (checklist id: ${indexEntry.id})` : ''}`,
    ]
  );

  (action === 'created' ? report.created : report.updated).push({ slug: cp.slug, name: cp.name, cardProductId });
}

// ───────────────────────────────────────────────────────────────────────
// Main
// ───────────────────────────────────────────────────────────────────────
function newReport() {
  return {
    created: [], updated: [], skipped: [], skippedGarbage: [],
    issuersCreated: [], issuerResolutions: [],
    unmappedCategories: {}, skippedCategories: [], unmappedPeriods: {}, unmappedRails: {},
    unusualBlockSizes: {}, aggregateScopeCaps: [], skippedCapRules: [], skippedRedemptionOptions: [],
    warnings: [],
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.input) {
    console.error('Usage: node import_card_pipeline.js --input <all-collected.json> --admin-id <uuid> [--dry-run] [--force]');
    process.exit(1);
  }
  if (!args.adminId) {
    console.error('--admin-id is required (a real, active admin_users.id — see this file\'s header comment).');
    process.exit(1);
  }

  const report = newReport();
  const records = JSON.parse(fs.readFileSync(args.input, 'utf8'));
  const index = loadIndex(args.input, report);

  // Fail fast with one clear message instead of N confusing RLS errors.
  const adminCheck = await pool.query('SELECT is_active FROM admin_users WHERE id = $1', [args.adminId]);
  if (adminCheck.rows.length === 0 || !adminCheck.rows[0].is_active) {
    console.error(`--admin-id ${args.adminId} is not an active row in admin_users. Every write here needs pandapay.is_admin() to be true for this id.`);
    process.exit(1);
  }

  console.log(`Importing ${records.length} record(s) from ${args.input}${args.dryRun ? ' (DRY RUN)' : ''}`);
  if (args.dryRun) {
    console.log(
      'Note: each card runs in its own transaction that is rolled back, so ' +
      'counts like "issuers created" will overcount vs. a real run — an ' +
      'issuer created for card #1 is rolled back before card #2 runs, so ' +
      'it looks newly-created again instead of being reused.'
    );
  }

  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    const indexEntry = index ? index[i] : null;
    const failReason = sanityCheck(record, indexEntry, report);
    if (failReason) {
      report.skippedGarbage.push({ slug: record?.card_product?.slug || '(no slug)', reason: failReason });
      continue;
    }

    try {
      await withAdminClient(args.adminId, async (client) => {
        await importOneCard(client, args.adminId, record, indexEntry, args.force, report);
        if (args.dryRun) throw new Error('__DRY_RUN_ROLLBACK__');
      });
    } catch (err) {
      // Report entries (report.created/updated/etc.) are pushed by
      // importOneCard BEFORE this throw fires, so dry-run still shows what
      // WOULD have happened even though the transaction below rolls back.
      if (err.message === '__DRY_RUN_ROLLBACK__') continue;
      report.skippedGarbage.push({ slug: record?.card_product?.slug || '(no slug)', reason: `DB error: ${err.message}` });
    }
  }

  const reportPath = path.join(__dirname, `import-report-${Date.now()}.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

  console.log('\n─── Import report ───');
  console.log(`created:            ${report.created.length}`);
  console.log(`updated (refreshed): ${report.updated.length}`);
  console.log(`skipped (reviewed): ${report.skipped.length}`);
  console.log(`skipped (garbage/invalid): ${report.skippedGarbage.length}`);
  console.log(`issuers created:    ${report.issuersCreated.length}`);
  if (Object.keys(report.unmappedCategories).length) {
    console.log('unmapped categories:', report.unmappedCategories);
  }
  if (report.aggregateScopeCaps.length) {
    console.log(`aggregate-scope caps imported but NOT enforced by the engine: ${report.aggregateScopeCaps.length} (see header comment)`);
  }
  if (report.skippedGarbage.length) {
    console.log('\nSkipped (garbage/invalid):');
    for (const s of report.skippedGarbage) console.log(`  - ${s.slug}: ${s.reason}`);
  }
  console.log(`\nFull report written to ${reportPath}`);

  await pool.end();
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
