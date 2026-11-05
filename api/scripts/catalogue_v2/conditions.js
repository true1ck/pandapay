'use strict';

// Plan C7.4 — a CardPipeline rule's `conditions` object (plus its
// `channel_type`) mapped onto v2 rule columns.
//
// Every key is put in exactly one bucket:
//   - descriptive: prose or flags that don't narrow the rule (ignored);
//   - mapped: becomes mcc_include / mcc_exclude / merchant_slugs /
//     platform_slugs / rail / min/max / excluded categories / category list;
//   - blocker: narrows the rule in a way the catalogue can't express. The
//     caller turns the rule into `info` (plan H2: never widen).
//
// This module never decides the rule's role; it reports what it found.

const { asNumber, isNA, normalizeMccList, normalizeText, uniq } = require('./util');
const { findContainedNames, resolveMerchantText, resolvePlatformText, splitNames } = require('./directory');
const { mapCategorySlugs, resolveCategoryToken } = require('./category_tokens');

const MIN_TXN_KEYS = [
  'minimum_transaction_inr', 'minimum_transaction_amount_inr', 'minimum_transaction_value_inr',
  'minimum_single_transaction_inr', 'transaction_amount_min_inr', 'min_transaction_inr',
  'min_txn_inr', 'minimum_order_value_inr', 'minimum_spend_per_transaction_inr',
];
const MAX_TXN_KEYS = [
  'maximum_transaction_inr', 'maximum_transaction_amount_inr', 'maximum_transaction_value_inr',
  'transaction_amount_max_inr', 'max_transaction_inr', 'max_single_transaction_inr', 'max_txn_inr',
];
const BLOCK_KEYS = [
  'spend_block_inr', 'accrual_block_inr', 'minimum_block_inr', 'base_spend_block_inr',
  'block_inr', 'reward_block_inr', 'transaction_amount_accrual_unit_inr', 'transaction_amount_block_inr',
];
const MCC_INCLUDE_KEYS = new Set([
  'mcc', 'mcc_list', 'mcc_in', 'mccs', 'merchant_category_codes', 'merchant_category_code',
  'mcc_target_list', 'mcc_codes', 'mcc_ranges', 'eligible_mccs', 'eligible_mcc', 'mcc_code',
]);
const MCC_EXCLUDE_KEYS = new Set([
  'mcc_exclude', 'excluded_mcc', 'excluded_mccs', 'mcc_exclusions', 'exclude_mcc', 'exclude_mccs',
  'mcc_not_in', 'excluded_mcc_list', 'mcc_excluded',
]);
const MERCHANT_KEYS = new Set([
  'merchant_pattern', 'merchant', 'merchants', 'merchant_names', 'merchant_name', 'eligible_merchants',
  'merchant_platform', 'merchant_list', 'merchant_brands', 'brands', 'partner_merchants',
  'merchant_or_platform', 'merchant_patterns', 'eligible_brands', 'partner_brands',
  'merchant_domain', 'merchant_platforms', 'merchant_partner_list', 'partner_list',
  'merchant_eligibility', 'eligible_merchant', 'eligible_partner_brands', 'merchant_group',
  'merchant_groups', 'merchant_brand', 'preferred_merchants', 'partner_merchant_list',
  'merchant_identifier', 'merchant_requirement',
]);
const PLATFORM_KEYS = new Set([
  'platform', 'platforms', 'app', 'apps', 'portal', 'program', 'programme', 'booking_channel',
  'booking_channels', 'payment_app', 'channel', 'channels', 'transaction_channel', 'eligible_channels',
  'merchant_channel', 'payment_channel', 'payment_mode', 'payment_method',
]);
// Single-value restatements of the rule's own category.
const RESTATING_KEYS = new Set([
  'category', 'category_id', 'merchant_category', 'spend_category', 'excluded_category',
  'transaction_category', 'merchant_type', 'spend_type',
]);
const CATEGORY_LIST_KEYS = new Set([
  'eligible_categories', 'categories', 'category_ids', 'eligible_spend_categories', 'spend_categories',
  'merchant_categories', 'transaction_categories', 'eligible_spend', 'selected_categories',
]);
const EXCLUDED_CATEGORY_KEYS = new Set([
  'excluded_merchants', 'except_merchants', 'except_at', 'excluding', 'except', 'excluded_platforms',
  'excluded_accelerated_merchants', 'excluded_wholesale_merchants', 'excluded_brands',
  'excluded_categories', 'exclude_categories', 'exclusions', 'excludes', 'exclude',
  'excluded_spend_categories', 'excluded_spends', 'merchant_exclusions', 'category_exclusions',
]);
const DESCRIPTIVE_KEYS = new Set([
  'description', 'reason', 'notes', 'note', 'source', 'comment', 'label', 'examples',
  'eligible_examples', 'source_text', 'source_note', 'source_text_exclusion', 'merchant_identification',
  'identification', 'mcc_identification', 'mcc_basis', 'effective_policy', 'explanation',
  'covered_services', 'provider_scope', 'fuel_definition', 'settled_transactions_only',
  'settled_transaction', 'settlement_required', 'transaction_amount_rounding', 'calculation_basis',
  'eligibility', 'explicit_exclusion', 'excluded', 'category_excluded_from_reward_earn',
  'period', 'merchant_mapping', 'retail_only', 'purpose', 'qualifying', 'eligible',
  'effective_date', 'eligible_services', 'eligible_purchase', 'eligible_transaction',
  'transaction_amount_basis', 'rounding', 'rounding_mode', 'accrual_rounding',
  'merchant_id_basis', 'points_basis', 'reward_basis_note',
]);
const DESCRIPTIVE_SUFFIX = /_(definition|description|note|notes|text|explanation|basis|rationale|identification|examples|source)$/;
// Boolean flags that only restate that a rule is an exclusion.
const EXCLUSION_FLAG = /^(excluded|exclusion|excluded_from_.*|.*_excluded_from_.*|is_excluded)$/;

const WILDCARD_VALUES = new Set([
  'all', 'any', 'all channels', 'all channel', 'retail', 'eligible retail', 'all merchants',
  'domestic and international', 'domestic international', 'online and retail', 'online or offline',
  'retail or online', 'pos or ecommerce', 'pos and ecommerce', 'online and pos', 'e commerce and pos',
  'pos e commerce', 'pos ecom', 'online offline international', 'online and offline', 'all spends',
  'all eligible spends', 'all eligible retail', 'purchase', 'purchases', 'retail purchase',
  'retail purchases', 'eligible spend', 'eligible spends', 'other eligible retail', 'all purchases',
  'pos and online retail', 'domestic and international purchases', 'online domestic and international retail',
  'offline pos and contactless domestic and international', 'eligible retail spend', 'none', 'n a',
  'online or pos merchant', 'merchant website or terminal', 'online or pos',
]);

// Exact rail words. `inexact` rails narrow the source (offline also means
// contactless): fine for an earning rule (hides a bonus), not for an
// exclusion (would let excluded spend earn).
const RAIL_WORDS = {
  online: { rail: 'online' },
  ecommerce: { rail: 'online' },
  'e commerce': { rail: 'online' },
  ecom: { rail: 'online' },
  'online transaction': { rail: 'online' },
  'online transactions': { rail: 'online' },
  'online spends': { rail: 'online' },
  'online shopping': { rail: 'online' },
  'online stores': { rail: 'online' },
  'online store': { rail: 'online' },
  'eligible online': { rail: 'online' },
  pos: { rail: 'swipe', inexact: true },
  'pos terminal': { rail: 'swipe', inexact: true },
  offline: { rail: 'swipe', inexact: true },
  'in store': { rail: 'swipe', inexact: true },
  'card swipe': { rail: 'swipe' },
  swipe: { rail: 'swipe' },
  'point of sale': { rail: 'swipe', inexact: true },
  'offline stores': { rail: 'swipe', inexact: true },
  'offline pos': { rail: 'swipe', inexact: true },
  upi: { rail: 'upi_qr' },
  'upi qr': { rail: 'upi_qr' },
  'scan and pay': { rail: 'upi_qr' },
  'scan pay': { rail: 'upi_qr' },
  'merchant upi': { rail: 'upi_qr' },
  'merchant scan and pay': { rail: 'upi_qr' },
  'upi on credit card': { rail: 'upi_qr' },
  'rupay upi': { rail: 'upi_qr' },
  'rupay credit card upi': { rail: 'upi_qr' },
  'upi scan pay': { rail: 'upi_qr' },
  'online merchant': { rail: 'online' },
  'online merchants': { rail: 'online' },
  'online transaction flag': { rail: 'online' },
  'online ecom': { rail: 'online' },
  'eligible online spends': { rail: 'online' },
  'online purchases': { rail: 'online' },
  'e commerce transactions': { rail: 'online' },
  'in person': { rail: 'swipe', inexact: true },
  'offline pos contactless': { rail: 'swipe', inexact: true },
  'pos and contactless': { rail: 'swipe', inexact: true },
  contactless: { rail: 'contactless' },
  emi: { rail: 'emi' },
  atm: { rail: 'atm' },
};

// D14b: things a transaction context can't carry.
const TXN_ATTRIBUTE_VALUE = /^(international|international transactions?|international spends?|international transaction flag|foreign currency|foreign currency transactions?|overseas|overseas spends?|domestic|domestic transactions?|domestic spends?|cross border|dcc)$/;
const TXN_ATTRIBUTE_KEY = /^(birthday_window|date_window|transaction_day|day_of_week|weekday|travel_dates|booking_type|booking_types|transaction_date|transaction_region|geography|transaction_scope|transaction_currency|currency|international_transaction|international_transaction_flag|ticket_class|classes|passenger)$/;
const NEGATION_INSIDE = /\b(outside|except|excluding|other than|not via|not through|unless)\b/;
const NEGATION_SPLIT = /^(.*?)\b(?:not via|not through|not at|not on|not|non|outside of|outside|except at|except via|except|excluding|other than|unless paid via|unless)\s+(.+)$/;
const NEGATION = /^(not|non|outside|except|excluding|other than)\b/;

// Lifecycle / accumulated-state triggers (moved here from the v1 importer so
// both paths share one definition). A positive reward gated by these is not
// a per-transaction rate.
const UNSUPPORTED_REWARD_TRIGGER_KEYS = new Set([
  'transaction_count', 'transaction_sequence', 'first_transaction', 'first_spend',
  'within_days_of_card_receipt', 'within_days_of_card_issuance', 'days_from_card_issuance',
  'days_from_card_receipt', 'deadline_days_from_receipt', 'deadline_days_from_issuance',
  'days', 'frequency', 'consecutive_months',
]);
const ACCUMULATED_SPEND_TRIGGER_KEY =
  /(?:^|_)(?:minimum_|maximum_)?(?:statement(?:_cycle|_month)?|calendar_(?:month|quarter|year)|quarter(?:ly)?|annual|lifetime|cumulative).*spend.*(?:threshold|target|qualification|net)?(?:_inr)?$/;
const ACCUMULATED_SPEND_FIELD =
  /(?:^|_)(?:statement|calendar|quarter|annual|lifetime|cumulative).*(?:cumulative_)?spend(?:_inr)?$/;

function rewardRuleHasUnsupportedTrigger(rule) {
  const hasPositiveRate =
    (asNumber(rule?.action?.cashback_percent) ?? 0) > 0 ||
    (asNumber(rule?.action?.points_per_block) ?? 0) > 0;
  if (!hasPositiveRate) return false;

  const visit = (value, key = '') => {
    const normalizedKey = String(key).toLowerCase();
    if (UNSUPPORTED_REWARD_TRIGGER_KEYS.has(normalizedKey)) return true;
    if (ACCUMULATED_SPEND_TRIGGER_KEY.test(normalizedKey)) return true;
    if (normalizedKey === 'trigger' && !isNA(value) && String(value).trim()) return true;
    if (
      normalizedKey === 'field' &&
      (UNSUPPORTED_REWARD_TRIGGER_KEYS.has(String(value).toLowerCase()) ||
        ACCUMULATED_SPEND_FIELD.test(String(value).toLowerCase()))
    ) {
      return true;
    }
    if (Array.isArray(value)) return value.some((entry) => visit(entry));
    if (value && typeof value === 'object') {
      return Object.entries(value).some(([childKey, child]) => visit(child, childKey));
    }
    if (typeof value !== 'string') return false;
    return /\b(first (?:qualifying )?(?:transaction|spend|purchase)|after (?:\w+|\d+) transactions?|within \d+ days? of (?:card )?(?:receipt|issuance))\b/i.test(value);
  };

  if (visit(rule?.conditions)) return true;
  const id = String(rule?.id || '');
  return rule?.evaluation_type === 'accelerator' && /(?:welcome|activation)[_-]/i.test(id);
}

function isWildcard(value) {
  const n = normalizeText(value);
  if (WILDCARD_VALUES.has(n)) return true;
  if (/^all\b/.test(n)) return true;
  // "online and offline", "pos/ecommerce": both channels named = no channel restriction.
  const online = /\b(online|ecommerce|e commerce|ecom)\b/.test(n);
  const offline = /\b(offline|pos|retail|in store|in person|swipe)\b/.test(n);
  return online && offline;
}

// A merchant or platform named in free text. The merchant wins over the
// merchant's own app ("IRCTC app" -> merchant irctc, via the generic-word
// trim in the directory lookup): a co-brand rule restricted to a platform the
// engine never infers would never apply. A text that only matches a
// merchant_app platform ("Swiggy Minis" is an alias of swiggy_app) is left
// unresolved — it names a sub-product, and mapping it to the whole brand
// would let a narrow exclusion swallow the brand's main rule.
function resolveName(text, index) {
  const merchant = resolveMerchantText(text, index);
  if (merchant) return { merchant };
  const platform = resolvePlatformText(text, index);
  if (!platform) return null;
  if (index.platforms.get(platform)?.kind === 'merchant_app') {
    const own = platform.replace(/_(app|portal|website)$/, '');
    if (index.merchants.has(own)) return null;
  }
  return { platform };
}

function emptyMapping() {
  return {
    mccInclude: [],
    mccExclude: [],
    exceptMerchantSlugs: [],
    exceptPlatformSlugs: [],
    listedExcludedMerchants: [],
    listedExcludedPlatforms: [],
    mentions: [],
    merchantSlugs: [],
    platformSlugs: [],
    rails: [],
    minTxn: null,
    maxTxn: null,
    block: null,
    excludedCategorySlugs: [],
    unmappedExcluded: [],
    restatedCategories: [],
    categoryList: null,
    alternatives: null,
    capRefs: [],
    merchantProse: [],
    blockers: [],
    flags: [],
    effectiveFrom: null,
  };
}

function block(m, key, detail) {
  m.blockers.push({ key, detail: detail === undefined ? null : String(JSON.stringify(detail)).slice(0, 160) });
  if (TXN_ATTRIBUTE_KEY.test(String(key).replace(/^clause:/, ''))) m.flags.push('depends_on_txn_attribute');
}

function flattenMccValue(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    if (Array.isArray(value.in)) return value.in;
    // {"dining": [5812], "movies": [7832]}: one list per sub-category.
    return Object.values(value).flatMap((v) => (Array.isArray(v) ? v : [v]));
  }
  // [[3000, 3350], [3501, 3853]]: pairs are ranges.
  if (Array.isArray(value)) {
    return value.flatMap((v) => (Array.isArray(v) && v.length === 2 ? [`${v[0]}-${v[1]}`] : [v]));
  }
  return value;
}

function addMccs(m, key, value, target) {
  const { mccs, invalid, malformed } = normalizeMccList(flattenMccValue(value));
  if (malformed.length) m.flags.push('malformed_mcc');
  if (invalid.length) {
    m.flags.push('unreadable_mcc');
    block(m, key, invalid);
  }
  m[target].push(...mccs);
}

function mapNameValue(m, key, value, index, { allowRail }) {
  // A list of names: resolve each; unresolved names make it a partial list.
  if (Array.isArray(value) && value.length > 1 && value.every((v) => typeof v === 'string')) {
    const sub = { ...emptyMapping(), merchantSlugs: [], platformSlugs: [], merchantProse: [], rails: [], blockers: [], flags: [] };
    for (const v of value) mapNameValue(sub, key, v, index, { allowRail });
    m.merchantSlugs.push(...sub.merchantSlugs);
    m.platformSlugs.push(...sub.platformSlugs);
    m.rails.push(...sub.rails);
    m.blockers.push(...sub.blockers);
    m.flags.push(...sub.flags);
    m.exceptMerchantSlugs.push(...sub.exceptMerchantSlugs);
    m.exceptPlatformSlugs.push(...sub.exceptPlatformSlugs);
    if (sub.merchantProse.length) {
      const resolvedAny = sub.merchantSlugs.length || sub.platformSlugs.length;
      m.merchantProse.push({ key, text: sub.merchantProse.map((p) => p.text).join(', '), partial: Boolean(resolvedAny) });
    }
    return;
  }
  const values = Array.isArray(value) ? value : [value];
  for (const raw of values) {
    if (raw === null || raw === undefined || raw === '' || typeof raw === 'boolean') continue;
    if (typeof raw !== 'string') {
      block(m, key, raw);
      continue;
    }
    const n = normalizeText(raw);
    if (!n) continue;
    if (NEGATION.test(n) || NEGATION_INSIDE.test(n) || /^not_/.test(raw.trim().toLowerCase())) {
      // D16: "not via PhonePe", "non-HPCL fuel", "UPI outside PhonePe" ->
      // an exception list, when what follows the negation resolves.
      const neg = n.match(NEGATION_SPLIT);
      const before = neg ? neg[1].trim() : '';
      const after = neg ? neg[2].trim() : '';
      const hit = after ? resolveName(after, index) : null;
      if (hit) {
        if (hit.merchant) m.exceptMerchantSlugs.push(hit.merchant);
        if (hit.platform) m.exceptPlatformSlugs.push(hit.platform);
        if (before && allowRail && RAIL_WORDS[before]) m.rails.push({ ...RAIL_WORDS[before], key });
        continue;
      }
      block(m, key, raw);
      m.flags.push('negated_condition');
      continue;
    }
    if (/\bmccs?\b|merchant category|^mcc \d/.test(n)) continue;
    if (/^(website|app|apps|web|mobile app|mobile application|website or app|website and app|website app|online website|websites and apps)$/.test(n)) continue; // "MCC-scoped": the rule's own MCC/category says it
    if (TXN_ATTRIBUTE_VALUE.test(n)) {
      block(m, key, raw);
      m.flags.push('depends_on_txn_attribute');
      continue;
    }
    if (allowRail && RAIL_WORDS[n]) {
      m.rails.push({ ...RAIL_WORDS[n], key });
      continue;
    }
    // "all", "online and offline": no channel restriction. Only for channel
    // style keys and short values — a merchant list that happens to say
    // "online and retail Landmark stores: ..." is not a wildcard.
    if (allowRail && n.split(' ').length <= 6 && isWildcard(raw)) continue;
    if (/\b(mid|tid|mids|tids|merchant ids?|terminal ids?)\b/.test(n) && !resolveName(raw, index)) {
      // D17(c): "identified by MID/TID" says how merchants are identified.
      // Skipped only when it names no brand; a named brand is the restriction.
      const named = findContainedNames(raw, index);
      if (named.merchants.length || named.platforms.length) {
        m.merchantSlugs.push(...named.merchants);
        m.platformSlugs.push(...named.platforms);
        m.flags.push('brand_from_identification_text');
      }
      // D18g: brands are found by directory alias only; with none named the
      // text just says how merchants are identified.
      continue;
    }
    const push = (hit) => {
      if (hit.merchant) m.merchantSlugs.push(hit.merchant);
      if (hit.platform) m.platformSlugs.push(hit.platform);
    };
    // The whole phrase first ("Scan & Pay via Kiwi App", "Swiggy Liquor").
    const whole = resolveName(raw, index);
    if (whole) {
      push(whole);
      continue;
    }
    // Then a list of names ("Amazon, Flipkart and Myntra").
    const pieces = splitNames(raw.replace(/_/g, ' '));
    if (pieces.length > 1) {
      const hits = pieces.map((piece) => resolveName(piece, index));
      const resolved = hits.filter(Boolean);
      const leftover = pieces.filter((piece, i) => !hits[i] && !(allowRail && (RAIL_WORDS[normalizeText(piece)] || isWildcard(piece))));
      if (allowRail) {
        for (const piece of pieces) if (RAIL_WORDS[normalizeText(piece)]) m.rails.push({ ...RAIL_WORDS[normalizeText(piece)], key });
      }
      resolved.forEach(push);
      if (!leftover.length) continue;
      if (resolved.length > 0) {
        if (allowRail) {
          // D17e: on a channel/app key the rest of the phrase ("RuPay credit
          // card on UPI") is a further condition, not another option.
          block(m, key, raw);
          continue;
        }
        m.merchantProse.push({ key, text: raw, partial: true });
        continue;
      }
    }
    m.merchantProse.push({ key, text: raw, partial: false });
  }
}

function mapCategoryListValue(m, key, value) {
  const list = Array.isArray(value) ? value : typeof value === 'string' ? splitNames(value) : [];
  const items = list.filter((v) => typeof v === 'string' && v.trim());
  if (!items.length) return;
  m.categoryList = [...(m.categoryList || []), ...items.map((s) => s.trim().toLowerCase().replace(/[\s-]+/g, '_'))];
  m.categoryListKey = key;
}

// Source exclusion lists. On an earning rule they narrow it (excluded
// categories; excluded merchants/apps become except lists, D16). On an
// exclusion rule they are the exclusion's own scope (D17d) — the caller
// decides, so they are kept apart from "not via X" exceptions.
function mapExcludedCategories(m, value, index) {
  const list = Array.isArray(value) ? value : typeof value === 'string' ? splitNames(value) : [];
  for (const item of list) {
    if (typeof item !== 'string') continue;
    const slugs = mapCategorySlugs(item);
    if (slugs.length) {
      m.excludedCategorySlugs.push(...slugs);
      continue;
    }
    const hit = index ? resolveName(item, index) : null;
    if (hit?.merchant) m.listedExcludedMerchants.push(hit.merchant);
    else if (hit?.platform) m.listedExcludedPlatforms.push(hit.platform);
    else m.unmappedExcluded.push(item);
  }
}

// One `{field, operator, value}` clause.
function mapClause(m, clause, ctx) {
  const field = String(clause?.field || '').toLowerCase();
  const op = String(clause?.operator || '==').toLowerCase().replace(/\s+/g, '');
  const value = clause?.value;
  const isIn = ['==', '=', 'in', 'eq', 'equals', 'is'].includes(op);
  const notIn = ['not_in', 'notin', '!=', 'not', 'nin', 'not_equals'].includes(op);
  if (['mcc', 'merchant_category_code', 'mcc_code', 'mccs'].includes(field)) {
    if (isIn) return addMccs(m, field, value, 'mccInclude');
    if (notIn) return addMccs(m, field, value, 'mccExclude');
  }
  if (['transaction_category', 'category', 'merchant_category', 'spend_category', 'category_id'].includes(field)) {
    if (notIn) return mapExcludedCategories(m, Array.isArray(value) ? value : [value], ctx.index);
    if (isIn) return mapCategoryListValue(m, field, Array.isArray(value) ? value : [value]);
  }
  if (['merchant', 'merchant_name', 'merchant_brand'].includes(field) && isIn) {
    return mapNameValue(m, field, value, ctx.index, { allowRail: false });
  }
  if (['platform', 'app', 'channel', 'transaction_channel'].includes(field) && isIn) {
    return mapNameValue(m, field, value, ctx.index, { allowRail: true });
  }
  if (['transaction_amount', 'transaction_amount_inr', 'amount', 'amount_inr'].includes(field)) {
    const n = asNumber(value);
    if (n !== null && ['>=', '>', 'gte', 'gt'].includes(op)) {
      m.minTxn = Math.max(m.minTxn ?? 0, n);
      return;
    }
    if (n !== null && ['<=', '<', 'lte', 'lt'].includes(op)) {
      m.maxTxn = m.maxTxn === null ? n : Math.min(m.maxTxn, n);
      return;
    }
  }
  if (['transaction_type'].includes(field) && isIn && isPurchaseType(value)) return;
  block(m, `clause:${field || '?'}`, clause);
}

function isPurchaseType(value) {
  const values = Array.isArray(value) ? value : [value];
  return values.every((v) => typeof v === 'string' && /^(retail )?(purchase|purchases|retail|all|any|all purchases|retail purchases|domestic and international purchases|spend|spends)$/.test(normalizeText(v)));
}

function mapOne(m, key, value, ctx) {
  const k = String(key);
  const lower = k.toLowerCase();
  if (value === null || value === undefined || value === 'N/A' || value === '') return;

  if (DESCRIPTIVE_KEYS.has(lower) || (DESCRIPTIVE_SUFFIX.test(lower) && typeof value !== 'object')) return;
  if (EXCLUSION_FLAG.test(lower) && typeof value === 'boolean') return;
  // D18e: an explicit "other than X" / "except X" / "excluding X" naming a
  // brand is an exception, whatever the key (checked before any key-specific handling).
  if (typeof value === 'string') {
    const neg = normalizeText(value).match(/\b(?:other than|except(?: at| via| for)?|excluding|apart from)\s+(.+)$/);
    if (neg) {
      const named = findContainedNames(neg[1], ctx.index);
      if (named.merchants.length || named.platforms.length) {
        m.exceptMerchantSlugs.push(...named.merchants);
        m.exceptPlatformSlugs.push(...named.platforms);
        m.flags.push('exception_from_prose');
        return;
      }
    }
  }
  if (/^cap(_|$)|_cap$|_cap_ref|cap_reference/.test(lower) && typeof value === 'string') {
    m.capRefs.push(value);
    return;
  }
  if (MCC_INCLUDE_KEYS.has(lower)) return addMccs(m, k, value, 'mccInclude');
  if (MCC_EXCLUDE_KEYS.has(lower)) return addMccs(m, k, value, 'mccExclude');
  if (MIN_TXN_KEYS.includes(lower)) {
    const n = asNumber(value);
    if (n === null) return block(m, k, value);
    m.minTxn = Math.max(m.minTxn ?? 0, n);
    return;
  }
  if (MAX_TXN_KEYS.includes(lower)) {
    const n = asNumber(value);
    if (n === null) return block(m, k, value);
    m.maxTxn = m.maxTxn === null ? n : Math.min(m.maxTxn, n);
    return;
  }
  if (BLOCK_KEYS.includes(lower)) {
    const n = asNumber(value);
    if (n !== null && n > 0) m.block = n;
    return;
  }
  if (lower === 'transaction_amount_inr' && value && typeof value === 'object') {
    if ('operator' in value) return mapClause(m, { field: 'transaction_amount', ...value }, ctx);
    const min = asNumber(value.min ?? value.minimum ?? value.gte ?? value['>=']);
    const max = asNumber(value.max ?? value.maximum ?? value.lte ?? value['<=']);
    if (min === null && max === null) return block(m, k, value);
    if (min !== null) m.minTxn = Math.max(m.minTxn ?? 0, min);
    if (max !== null) m.maxTxn = m.maxTxn === null ? max : Math.min(m.maxTxn, max);
    return;
  }
  if (EXCLUDED_CATEGORY_KEYS.has(lower)) return mapExcludedCategories(m, value, ctx.index);
  if (lower === 'non_emi' && value === true) {
    m.excludedCategorySlugs.push('emi');
    return;
  }
  if (MERCHANT_KEYS.has(lower)) return mapNameValue(m, k, value, ctx.index, { allowRail: false });
  if (PLATFORM_KEYS.has(lower)) return mapNameValue(m, k, value, ctx.index, { allowRail: true });
  if (CATEGORY_LIST_KEYS.has(lower)) {
    if (typeof value === 'string') {
      const pieces = splitNames(value);
      const allResolve = pieces.length && pieces.every((piece) =>
        resolveCategoryToken(piece.trim().toLowerCase().replace(/[\s-]+/g, '_'), ctx).parts.length);
      // Prose such as "All eligible purchases not otherwise excluded." or
      // "Eligible calendar-month spend up to ₹1,50,000" describes, not restricts.
      if (!allResolve && (lower === 'eligible_spend' || /eligible|not otherwise|all /i.test(value))) return;
    }
    return mapCategoryListValue(m, k, value);
  }
  if (RESTATING_KEYS.has(lower)) {
    if (Array.isArray(value)) return mapCategoryListValue(m, k, value);
    if (typeof value === 'string') {
      if (lower === 'transaction_category' || lower === 'spend_type' || lower === 'merchant_type') {
        if (isPurchaseType(value)) return;
      }
      m.restatedCategories.push({ key: k, value });
      return;
    }
    return block(m, k, value);
  }
  if (lower === 'transaction_type' || lower === 'transaction_types' || lower === 'purchase_type') {
    if (isPurchaseType(value)) return;
    // "fuel_purchase" on a fuel rule restates the category.
    const values = Array.isArray(value) ? value : [value];
    if (values.every((v) => typeof v === 'string' && /_(purchase|purchases|spend|spends|transaction|transactions)$/.test(v.trim().toLowerCase()))) {
      m.restatedCategories.push(...values.map((v) => ({ key: k, value: v.trim().toLowerCase().replace(/_(purchase|purchases|spend|spends|transaction|transactions)$/, '') })));
      return;
    }
    m.restatedTransactionTypes = [...(m.restatedTransactionTypes || []), ...(Array.isArray(value) ? value : [value])];
    return;
  }
  if (['transaction_region', 'geography', 'transaction_scope', 'scope', 'eligible_scope', 'merchant_scope', 'transaction_currency', 'currency'].includes(lower)) {
    if (typeof value === 'string' && (isWildcard(value) || /^all\b/i.test(value.trim()))) return;
    if (typeof value === 'string' && /^(inr|domestic and international|any currency)$/i.test(normalizeText(value)) && lower.includes('currency')) return;
    return block(m, k, value);
  }
  if (lower === 'network') {
    if (ctx.cardNetwork && typeof value === 'string' && normalizeText(value) === normalizeText(ctx.cardNetwork)) return;
    return block(m, k, value);
  }
  if (lower === 'all' && Array.isArray(value)) {
    for (const clause of value) {
      if (clause && typeof clause === 'object' && 'field' in clause) mapClause(m, clause, ctx);
      else if (clause && typeof clause === 'object') mapObject(m, clause, ctx);
      else block(m, k, clause);
    }
    return;
  }
  if (lower === 'any' && Array.isArray(value)) {
    m.alternatives = value.map((alt) => {
      const sub = emptyMapping();
      if (alt && typeof alt === 'object' && 'field' in alt) mapClause(sub, alt, ctx);
      else if (alt && typeof alt === 'object') mapObject(sub, alt, ctx);
      else block(sub, 'any', alt);
      return sub;
    });
    return;
  }
  if (value === false || value === 0 || (Array.isArray(value) && !value.length)) return;
  if (/^including_/.test(lower) && value === true) return; // widens the scope; ignoring it narrows
  if (/multiplier/.test(lower) && typeof value === 'number') return; // the rate itself, restated
  // D16: "platform_not": "Google Pay", "not_merchant": "HPCL", "except_app": ...
  const negatedKey = lower.match(/^(?:not|except|excluding|non)_(.+)$|^(.+)_(?:not|except|excluded|exclusions?)$/);
  if (negatedKey && (typeof value === 'string' || Array.isArray(value))) {
    const values = (Array.isArray(value) ? value : [value]).filter((v) => typeof v === 'string');
    for (const v of values) mapNameValue(m, k, `not ${v}`, ctx.index, { allowRail: false });
    return;
  }
  if (/^non_/.test(lower) && value === true && (m.exceptMerchantSlugs.length || m.exceptPlatformSlugs.length)) return;
  // "payzapp_exception": "PayZapp transactions can qualify ..." names the
  // exception in prose: the brands it names are the except list.
  if (/(^|_)(except|exception|exceptions)(_|$)/.test(lower) && !/(note|description|text|definition)/.test(lower) && typeof value === 'string') {
    const named = findContainedNames(value, ctx.index);
    if (named.merchants.length || named.platforms.length) {
      m.exceptMerchantSlugs.push(...named.merchants);
      m.exceptPlatformSlugs.push(...named.platforms);
      m.flags.push('exception_from_prose');
      return;
    }
  }
  // A key whose value just names a merchant ("location": "HPCL petrol pump"):
  // the caller checks it restates the rule's own merchant.
  if (typeof value === 'string') {
    const hit = resolveName(value, ctx.index);
    if (hit) {
      m.mentions.push({ key: k, ...hit });
      return;
    }
  }
  block(m, k, value);
}

function mapObject(m, conditions, ctx) {
  if (!conditions || typeof conditions !== 'object' || Array.isArray(conditions)) {
    if (typeof conditions === 'string' && conditions.trim()) block(m, 'conditions', conditions);
    return m;
  }
  if ('field' in conditions && 'operator' in conditions) {
    mapClause(m, conditions, ctx);
    const rest = { ...conditions };
    delete rest.field;
    delete rest.operator;
    delete rest.value;
    for (const [k, v] of Object.entries(rest)) mapOne(m, k, v, ctx);
    return m;
  }
  for (const [k, v] of Object.entries(conditions)) mapOne(m, k, v, ctx);
  return m;
}

/**
 * Maps a rule's `conditions` and `channel_type`.
 * @param {object} rule CardPipeline reward rule
 * @param {{index, issuerSlug, cardNetwork}} ctx
 */
function mapRuleConditions(rule, ctx) {
  const m = emptyMapping();
  mapObject(m, rule?.conditions, ctx);
  const channel = rule?.channel_type;
  if (!isNA(channel) && typeof channel === 'string' && channel.trim()) {
    const before = m.blockers.length;
    mapNameValue(m, 'channel_type', channel, ctx.index, { allowRail: true });
    // channel_type naming the same thing as the category token (swiggy_app on
    // a swiggy_app rule) is handled by the caller via channelTokenParts.
    if (m.merchantProse.length && m.merchantProse[m.merchantProse.length - 1].key === 'channel_type') {
      const prose = m.merchantProse.pop();
      const channelKey = String(channel).trim().toLowerCase().replace(/[\s\-/.]+/g, '_');
      let token = resolveCategoryToken(channelKey, ctx);
      const trimmed = channelKey.replace(/_(transactions?|premiums?|payments?|spends?|purchases?|bills?)$/, '').replace(/^atm_/, '');
      if (token.kind === 'unknown' && trimmed !== channelKey) token = resolveCategoryToken(trimmed, ctx);
      if (['merchant', 'platform', 'rail'].includes(token.kind)) {
        m.channelTokenParts = token.parts;
      } else if (token.kind === 'unrestricted' || token.kind === 'category' || token.kind === 'composite') {
        m.channelCategoryToken = token;
      } else if (token.kind === 'non_purchase') {
        m.channelNonPurchase = true;
      } else {
        m.blockers.push({ key: 'channel_type', detail: prose.text });
      }
    }
    m.channelBlocked = m.blockers.length > before;
  }
  m.mccInclude = uniq(m.mccInclude).sort();
  m.mccExclude = uniq(m.mccExclude).sort();
  m.merchantSlugs = uniq(m.merchantSlugs).sort();
  m.platformSlugs = uniq(m.platformSlugs).sort();
  m.excludedCategorySlugs = uniq(m.excludedCategorySlugs).sort();
  m.exceptMerchantSlugs = uniq(m.exceptMerchantSlugs).sort();
  m.listedExcludedMerchants = uniq(m.listedExcludedMerchants).sort();
  m.listedExcludedPlatforms = uniq(m.listedExcludedPlatforms).sort();
  m.exceptPlatformSlugs = uniq(m.exceptPlatformSlugs).sort();
  m.capRefs = uniq(m.capRefs);
  return m;
}

module.exports = {
  BLOCK_KEYS,
  MAX_TXN_KEYS,
  MIN_TXN_KEYS,
  RAIL_WORDS,
  isWildcard,
  mapRuleConditions,
  resolveName,
  rewardRuleHasUnsupportedTrigger,
};
