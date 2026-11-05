'use strict';

// Plan C7.9 — card_benefits rows, and spend-gated benefits as structured
// benefit_unlock_rules ("lounge visit if you spent ₹50,000 last quarter").
//
// CardPipeline stores the gate under 10+ key names (spend_threshold_inr,
// previous_quarter_spend_inr, eligible_spend_milestones_inr[],
// tiers.Gold.monthly_spend_inr, a prose spend_condition, ...). This module
// reads them all into one shape: threshold + window. A benefit that talks
// about spend but can't be read is flagged `unparsed_unlock`.

const { asNumber, isNA, uniq } = require('./util');
const { mapCategorySlug } = require('./category_tokens');

const BENEFIT_KIND_RULES = [
  [/lounge.*(inter|abroad|overseas|global|priority pass)|priority.?pass/, 'lounge_international'],
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
const QUOTA_PERIOD = {
  statement_cycle: 'statement_cycle', calendar_month: 'calendar_month', month: 'calendar_month',
  monthly: 'calendar_month', quarter: 'quarter', quarterly: 'quarter', calendar_quarter: 'quarter',
  half_year: 'half_year', annual: 'annual', year: 'annual', yearly: 'annual',
  card_anniversary_year: 'annual', calendar_year: 'annual', enrollment_year: 'annual', lifetime: 'lifetime',
};

function guessBenefitKind(...fields) {
  const hay = fields.filter((f) => !isNA(f)).join(' ').toLowerCase();
  for (const [pattern, kind] of BENEFIT_KIND_RULES) if (pattern.test(hay)) return kind;
  return 'other';
}

// Which key paths hold a spend threshold, and which don't.
const THRESHOLD_PATH = /(spend|threshold)/;
const NOT_THRESHOLD = /(exclu|max|_cap|cap_|fee|usd|fum|pin_free|limit|per_transaction|transaction_min|transaction_max|transaction_amount|waiver|order_value|minimum_order|fuel_spend|bpcl|emirates|international)/;
const WINDOW_KEYS = new Set([
  'spend_period', 'period', 'evaluation_period', 'spend_window', 'spend_basis', 'membership_spend_basis',
  'spend_reference_period', 'prior_spend_period', 'preceding_spend_period', 'qualifying_period',
  'spend_measurement', 'minimum_spend_period', 'qualifying_spend_period', 'spend_evaluation',
  'eligible_spend_basis', 'net_spend_basis', 'spend_criteria', 'frequency', 'unlock_period',
  'access_period', 'spend_gate',
]);
const EXCLUSION_KEYS = /(excluded_spend|eligible_spend_exclusions|excluded_spend_categories|excluded_spends|excluded_from_spend_calculation|threshold_exclusions)/;

// Text (a key path or a period string) -> spend window.
function windowFromText(text) {
  const s = String(text || '').toLowerCase().replace(/[_-]+/g, ' ');
  if (!s.trim()) return null;
  let m = s.match(/(?:within|first|in)\s+(\d{1,3})\s*days?/) || s.match(/(\d{1,3})\s*days?\s*(?:of|from|after)\s*(?:card\s*)?(?:issu|open|activation|receipt|setup)/);
  if (m) return { window: 'first_days_after_issue', days: Number(m[1]) };
  if (/(previous|preceding|prior|last)\s*(3|three)\s*(calendar\s*)?months/.test(s)) return { window: 'rolling_days', days: 90 };
  m = s.match(/(\d{1,3})\s*day\s*period/);
  if (m) return { window: 'rolling_days', days: Number(m[1]) };
  if (/(previous|preceding|prior|last)\s*(calendar\s*)?quarter|preceding spends? quarter|preceding spend quarter/.test(s)) return { window: 'previous_calendar_quarter' };
  if (/(previous|preceding|prior|last)\s*(calendar\s*)?month/.test(s)) return { window: 'previous_calendar_month' };
  if (/(previous|preceding|prior|last)\s*(monthly\s*)?(statement|billing)/.test(s)) return { window: 'previous_calendar_month', approx: 'statement_cycle' };
  if (/(current|this|same|in (a|the))\s*(calendar\s*)?quarter|calendar quarter|quarterly|per quarter|\bquarter\b/.test(s)) return { window: 'current_calendar_quarter' };
  if (/calendar month|monthly|per month|in (a|the) month|\bmonth\b|statement cycle|billing cycle/.test(s)) return { window: 'calendar_month' };
  if (/calendar year/.test(s)) return { window: 'calendar_year' };
  if (/annual|yearly|\byear\b|anniversary|membership year|cardmembership|renewal|retention|card year/.test(s)) return { window: 'card_year' };
  return null;
}

function* leaves(value, path = []) {
  if (Array.isArray(value)) {
    for (const v of value) yield* leaves(v, [...path, '[]']);
  } else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) yield* leaves(v, [...path, k]);
  } else {
    yield { path, value };
  }
}

function amountsInText(text) {
  const out = [];
  const re = /(?:₹|rs\.?|inr)\s*([\d,]+(?:\.\d+)?)\s*(lakh|lac|l\b|crore)?/gi;
  let m;
  while ((m = re.exec(String(text)))) {
    let n = Number(m[1].replace(/,/g, ''));
    if (/lakh|lac|^l$/i.test(m[2] || '')) n *= 100000;
    if (/crore/i.test(m[2] || '')) n *= 10000000;
    if (Number.isFinite(n) && n >= 1000) out.push(n);
  }
  return out;
}

/** Spend gates found in one benefit's conditions. */
function extractGates(conditions) {
  const gates = [];
  const windowTexts = [];
  const excluded = [];
  let mentionsSpend = false;
  if (typeof conditions === 'string') {
    if (/spen[dt]/i.test(conditions)) {
      mentionsSpend = true;
      for (const n of amountsInText(conditions)) gates.push({ threshold: n, pathText: conditions, tier: null });
      windowTexts.push(conditions);
    }
    return { gates, windowTexts, excluded, mentionsSpend };
  }
  if (!conditions || typeof conditions !== 'object') return { gates, windowTexts, excluded, mentionsSpend };
  const tierValue = typeof conditions.tier === 'string' ? conditions.tier : null;
  for (const { path, value } of leaves(conditions)) {
    const keys = path.filter((p) => p !== '[]');
    const pathText = keys.join('.').toLowerCase();
    const last = (keys[keys.length - 1] || '').toLowerCase();
    if (EXCLUSION_KEYS.test(pathText)) {
      if (typeof value === 'string') excluded.push(value);
      continue;
    }
    const emptyValue = typeof value === 'string' && /^(none|n\/a|no|nil|not applicable|no spend.*|false)$/i.test(value.trim());
    if (!emptyValue && value !== false && value !== null &&
        (/spen[dt]/.test(pathText) || (typeof value === 'string' && /spen[dt]/i.test(value)))) mentionsSpend = true;
    if (WINDOW_KEYS.has(last) && typeof value === 'string') windowTexts.push(value);
    const n = asNumber(value);
    const numericLeaf = typeof value === 'number' || (typeof value === 'string' && n !== null);
    if (numericLeaf) {
      const holder = (keys.length >= 2 && ['value', 'minimum', '>=', 'gte', 'amount_inr', 'min'].includes(last))
        ? keys.slice(0, -1).join('.').toLowerCase()
        : pathText;
      if (!THRESHOLD_PATH.test(holder) || NOT_THRESHOLD.test(holder)) continue;
      if (/cashback_percent|percent|count|visits|days|hours/.test(last)) continue;
      if (n === null || n < 1000) continue;
      let tier = null;
      const tierIdx = keys.findIndex((k) => k.toLowerCase() === 'tiers');
      if (tierIdx >= 0 && keys[tierIdx + 1]) tier = keys[tierIdx + 1];
      else if (tierValue) tier = tierValue;
      gates.push({ threshold: n, pathText: holder, tier });
      windowTexts.push(holder);
    } else if (typeof value === 'string' && /(spend_condition|spend_requirement|spend_required|published_spend_condition|new_card_spend_condition|spend_criteria)$/.test(last)) {
      for (const amount of amountsInText(value)) gates.push({ threshold: amount, pathText: value, tier: tierValue });
      windowTexts.push(value);
    }
  }
  return { gates, windowTexts, excluded, mentionsSpend };
}

function unlockKind(benefitKind, label, tier) {
  if (tier) return 'tier';
  const l = String(label || '').toLowerCase();
  if (/rail/.test(l) && /lounge/.test(l)) return 'lounge_railway';
  if (benefitKind === 'lounge_international') return 'lounge_international';
  if (benefitKind === 'lounge_domestic') return 'lounge_domestic';
  if (/fee/.test(l) && /waiv|revers/.test(l)) return 'fee_waiver';
  if (/welcome/.test(l)) return 'welcome';
  if (/\bmembership\b(?!\s*year)/.test(l)) return 'membership';
  return 'other';
}

function transformBenefits(record) {
  const benefits = [];
  const unlockRules = [];
  const flags = [];
  const usedKeys = new Set();
  const keyFor = (base) => {
    let k = base;
    let n = 2;
    while (usedKeys.has(k)) k = `${base}~${n++}`;
    usedKeys.add(k);
    return k;
  };

  (record?.lifestyle_and_network_benefits || []).forEach((b, idx) => {
    const sourceId = isNA(b?.benefit_id) ? `benefit-${idx + 1}` : String(b.benefit_id);
    const key = keyFor(sourceId);
    const kind = guessBenefitKind(b?.category_id, b?.label, b?.benefit_id, b?.network_program);
    benefits.push({
      key,
      source_local_id: sourceId,
      kind,
      label: b?.label || b?.benefit_id || 'Benefit',
      description: isNA(b?.sponsor) ? null : `Sponsor: ${b.sponsor}`,
      quota_count: Number.isInteger(b?.quota_count) ? b.quota_count : null,
      quota_period: QUOTA_PERIOD[String(b?.quota_period || '').toLowerCase()] || null,
      network_program: isNA(b?.network_program) ? null : b.network_program,
      value_estimate_inr: asNumber(b?.value_estimate_inr),
      conditions: { source_category_id: b?.category_id || null, evaluation_engine: b?.evaluation_engine || null },
    });

    const cond = b?.evaluation_engine?.conditions;
    const { gates, windowTexts, excluded, mentionsSpend } = extractGates(cond);
    if (!gates.length) {
      if (mentionsSpend && /lounge|membership|voucher|waiver|tier/i.test(`${b?.label} ${b?.category_id}`)) {
        flags.push({ code: 'unparsed_unlock', source_local_id: sourceId, detail: 'mentions spend, no threshold read' });
      }
      return;
    }
    const thresholds = uniq(gates.map((g) => `${g.threshold}|${g.tier || ''}`)).map((s) => {
      const [t, tier] = s.split('|');
      return { threshold: Number(t), tier: tier || null, gate: gates.find((g) => String(g.threshold) === t && (g.tier || '') === tier) };
    });
    let windowSpec = null;
    for (const t of [...thresholds.map((t) => t.gate.pathText), ...windowTexts]) {
      windowSpec = windowFromText(t);
      if (windowSpec) break;
    }
    if (!windowSpec) {
      flags.push({ code: 'unparsed_unlock', source_local_id: sourceId, detail: 'threshold read, window not' });
      return;
    }
    const excludedSlugs = uniq(excluded.map(mapCategorySlug).filter(Boolean)).sort();
    const perThresholdQuota = thresholds.length > 1 && Number.isInteger(b?.quota_count) && b.quota_count === thresholds.length
      ? 1
      : thresholds.length === 1 && Number.isInteger(b?.quota_count) ? b.quota_count : null;
    const unlocksPeriod = QUOTA_PERIOD[String(b?.quota_period || '').toLowerCase()] || null;
    thresholds.sort((a, z) => a.threshold - z.threshold).forEach((t, n) => {
      const kindOut = unlockKind(kind, b?.label, t.tier);
      unlockRules.push({
        key: `${key}@${n + 1}`,
        benefit_key: key,
        source_local_id: sourceId,
        kind: kindOut,
        label: thresholds.length > 1 ? `${b?.label || sourceId} (₹${t.threshold.toLocaleString('en-IN')})` : (b?.label || sourceId),
        spend_threshold_inr: t.threshold,
        spend_window: windowSpec.window,
        window_days: windowSpec.days || null,
        unlocks_quota: perThresholdQuota,
        unlocks_period: unlocksPeriod,
        tier_label: t.tier ? String(t.tier).replace(/^\w/, (c) => c.toUpperCase()) : null,
        excluded_category_slugs: excludedSlugs,
        notes: windowSpec.approx ? `window approximated from ${windowSpec.approx}` : null,
      });
    });
  });

  for (const ins of record?.insurance_and_protection || []) {
    const kind = guessBenefitKind(ins?.cover_type);
    const label = String(ins?.cover_type || 'insurance_cover').replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    benefits.push({
      key: keyFor(`insurance:${ins?.cover_type || 'cover'}`),
      source_local_id: null,
      kind,
      label,
      description: isNA(ins?.claim_condition) ? null : ins.claim_condition,
      quota_count: null,
      quota_period: null,
      network_program: null,
      value_estimate_inr: asNumber(ins?.coverage_inr),
      conditions: { coverage_usd: isNA(ins?.coverage_usd) ? null : ins.coverage_usd },
    });
  }
  return { benefits, unlockRules, flags };
}

module.exports = { extractGates, guessBenefitKind, transformBenefits, windowFromText };
