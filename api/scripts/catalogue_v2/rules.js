'use strict';

// Plan C7.3–C7.6 — CardPipeline reward rules -> v2 reward_rules rows.
//
// One source rule can become several rows ("parts"): a composite token
// (dining_movies), a category list on the rule (PhonePe: recharges, utilities,
// insurance, travel), `any` alternatives, or an exclusion that names both a
// category and an MCC list. Parts share the source id, rate and cap links.
//
// The guiding rule is plan H2: a restriction we can't express turns the rule
// into `info` (shown, never ranked, hidden from v1). It is never dropped and
// never widened into an unrestricted rule. For an earning rule, mapping only
// part of a list narrows it (hides some bonus), which H2 allows; for an
// exclusion, narrowing would let excluded spend earn, so exclusions need an
// exact mapping or become `info`.

const { asNumber, isNA, normalizeText, uniq } = require('./util');
const {
  APP_CATEGORIES,
  ISSUER_PORTAL,
  resolveCategoryToken,
} = require('./category_tokens');
const { isWildcard, mapRuleConditions, rewardRuleHasUnsupportedTrigger } = require('./conditions');

const SOURCE_RAIL = {
  upi_qr: { rail: 'upi_qr' },
  upi: { rail: 'upi_qr' },
  swipe: { rail: 'swipe' },
  pos_terminal: { rail: 'swipe' },
  online: { rail: 'online' },
  contactless: { rail: 'contactless' },
  atm: { rail: 'atm' },
  emi: { rail: 'emi' },
};

const V1_POINT_BLOCKS = { 100: 'points_per_100', 150: 'points_per_150', 200: 'points_per_200' };
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const USER_ATTRIBUTE_KEY = /(membership|tier|prime|neon|selected_plan|plan$|pack|variant|relationship|customer_segment|salary|premier)/i;
const ROLES = new Set(['base', 'earn', 'exclusion', 'info']);
const BRANDISH = /(paytm|amazon|flipkart|smartbuy|phonepe|swiggy|zomato|tata|reliance|samsung|apple|kiwi|myntra|irctc|indigo|uber|ola|lic|hpcl|bpcl|indianoil|iocl|jio|airtel|partner|select|preferred|exclusive|promoted|accelerated|brand)/;

function categoryKey(s) {
  return String(s || '').trim().toLowerCase().replace(/[\s\-/.]+/g, '_');
}

// D8(a): whole points per block are points, even when a cashback % is also
// given. Without a ₹ value per point, points would be worth nothing in v1, so
// the cashback reading is kept and the conflict is flagged.
function unitAndRate(src, condBlock, card) {
  const flags = [];
  const cb = asNumber(src?.action?.cashback_percent);
  const pts = asNumber(src?.action?.points_per_block);
  let usePoints = pts !== null && (cb === null || pts > 0 && !(cb > 0));
  if (pts !== null && pts > 0 && cb !== null && cb > 0) {
    flags.push('points_and_cashback_both');
    usePoints = card.pointValueInr !== null;
  }
  if (usePoints) {
    const block = condBlock ?? card.baseBlockInr;
    if (block !== null && V1_POINT_BLOCKS[block]) {
      return { unit: V1_POINT_BLOCKS[block], rate: pts, blockInr: null, currency: 'points', flags };
    }
    if (block !== null && block > 0) {
      return { unit: 'points_per_100', rate: pts, blockInr: Math.round(block), currency: 'points', flags };
    }
    flags.push('assumed_block_100');
    return { unit: 'points_per_100', rate: pts, blockInr: null, currency: 'points', flags };
  }
  if (cb !== null) return { unit: 'cashback_percent', rate: cb, blockInr: null, currency: 'cashback', flags };
  return { unit: null, rate: null, blockInr: null, currency: null, flags };
}

function sourceRail(src, ctx) {
  const raw = src?.rail;
  if (isNA(raw) || raw === 'any' || raw === '') return {};
  const key = String(raw).trim().toLowerCase();
  if (SOURCE_RAIL[key]) return SOURCE_RAIL[key];
  if (key === 'smartbuy_or_equivalent_portal') {
    const portal = ISSUER_PORTAL[ctx.issuerSlug];
    return portal ? { platform: portal } : { blocked: raw };
  }
  return { blocked: raw };
}

function hasRestriction(p) {
  return Boolean(
    p.categorySlug || p.merchantSlugs?.length || p.platformSlugs?.length || p.mccInclude?.length ||
      p.mccExclude?.length || p.rail || p.minTxn !== null && p.minTxn !== undefined ||
      p.maxTxn !== null && p.maxTxn !== undefined
  );
}

function mergeSlugs(current, incoming) {
  if (!incoming?.length) return { slugs: current || [] };
  if (!current?.length) return { slugs: incoming };
  const cur = new Set(current);
  const inc = new Set(incoming);
  if ([...inc].every((s) => cur.has(s))) return { slugs: incoming };
  if ([...cur].every((s) => inc.has(s))) return { slugs: current };
  return { conflict: true, slugs: current };
}

// AND-combines a restriction into a part. Returns null on a conflict the
// row can't express (two different categories, disjoint merchant sets).
function andPart(part, extra) {
  const out = { ...part };
  if (extra.categorySlug) {
    if (out.categorySlug && out.categorySlug !== extra.categorySlug) return null;
    out.categorySlug = extra.categorySlug;
    if (extra.broad) out.broad = true;
  }
  if (extra.merchantSlugs?.length) {
    const r = mergeSlugs(out.merchantSlugs, extra.merchantSlugs);
    if (r.conflict) return null;
    out.merchantSlugs = r.slugs;
  }
  if (extra.platformSlugs?.length) {
    const r = mergeSlugs(out.platformSlugs, extra.platformSlugs);
    if (r.conflict) return null;
    out.platformSlugs = r.slugs;
  }
  if (extra.mccInclude?.length) {
    if (out.mccInclude?.length) {
      const inter = out.mccInclude.filter((m) => extra.mccInclude.includes(m));
      if (!inter.length) return null;
      out.mccInclude = inter;
    } else {
      out.mccInclude = extra.mccInclude;
    }
  }
  if (extra.mccExclude?.length) out.mccExclude = uniq([...(out.mccExclude || []), ...extra.mccExclude]).sort();
  if (extra.rail) {
    if (out.rail && out.rail !== extra.rail) return null;
    out.rail = extra.rail;
  }
  return out;
}

function partFromMapping(sub) {
  return {
    mccInclude: sub.mccInclude,
    mccExclude: sub.mccExclude,
    merchantSlugs: sub.merchantSlugs,
    platformSlugs: sub.platformSlugs,
    rail: sub.rails.length === 1 ? sub.rails[0].rail : null,
  };
}

function distinctiveAlias(slug, index) {
  const m = index?.merchants.get(slug);
  if (!m) return slug.replace(/_/g, ' ');
  const aliases = (m.aliases || []).map((a) => normalizeText(a)).filter(Boolean);
  const long = aliases.filter((a) => a.length >= 4).sort((a, b) => a.length - b.length || a.localeCompare(b));
  if (long.length) return long[0];
  if (aliases.length) return aliases.sort((a, b) => b.length - a.length)[0];
  return normalizeText(m.name) || slug.replace(/_/g, ' ');
}

/**
 * Transforms one source rule into one or more v2 rows.
 * @returns {{rows: object[], infoReasons: string[], flags: string[], unmappedTokens: string[], needsDirectory: string[]}}
 */
function transformRule(src, idx, ctx) {
  const info = [];
  const flags = [];
  const unmappedTokens = [];
  const needsDirectory = [];
  const evaluationType = String(src?.evaluation_type || '').toLowerCase();
  const isExclusion = evaluationType === 'exclusion';
  const isAccelerator = evaluationType === 'accelerator';
  const rawToken = isNA(src?.category_id) ? '' : String(src.category_id);

  const token = resolveCategoryToken(categoryKey(rawToken), ctx);
  flags.push(...token.flags);
  const cond = mapRuleConditions(src, ctx);
  flags.push(...cond.flags);

  const ur = isExclusion
    ? { unit: ctx.card.baseUnit && ctx.card.baseUnit.startsWith('points') ? ctx.card.baseUnit : 'cashback_percent', rate: 0, blockInr: null, currency: null, flags: [] }
    : unitAndRate(src, cond.block, ctx.card);
  flags.push(...ur.flags);
  if (!isExclusion && ur.rate === null) info.push('missing_rate');

  if (!isExclusion && rewardRuleHasUnsupportedTrigger(src)) info.push('unsupported_trigger');
  if (!isExclusion && /up[\s_-]*to\b/i.test(`${src?.id || ''} ${src?.action?.reason || ''}`) &&
      /\d+\s*x\b|\bx\d|multiplier|%/i.test(`${src?.id || ''} ${src?.action?.reason || ''}`)) {
    // D8(b): "up to 10X" is several rates folded into one.
    info.push('up_to_rate');
  }

  // D13(d): an override may set rule_role on the source rule. `info` always
  // wins; another role is honoured only if the rule maps cleanly (forcing
  // `earn` onto a rule we couldn't restrict would widen it).
  const forcedRole = ROLES.has(String(src?.rule_role || '')) ? String(src.rule_role) : null;
  if (forcedRole === 'info') info.push('override_rule_role');

  // 1. Start from the token's parts.
  let parts;
  if (token.kind === 'non_purchase') {
    info.push('non_purchase_category');
    unmappedTokens.push(rawToken);
    parts = [{}];
  } else if (token.kind === 'unknown') {
    if (cond.mccInclude.length && !BRANDISH.test(rawToken)) {
      // The rule names its own MCCs; the token is just a label for them.
      flags.push('token_replaced_by_mcc');
      parts = [{}];
    } else {
      info.push('unmapped_category_token');
      unmappedTokens.push(rawToken);
      parts = [{}];
    }
  } else {
    parts = token.parts.map((p) => ({ ...p }));
    if (token.kind === 'composite' && token.unmapped.length) {
      unmappedTokens.push(rawToken);
      if (isExclusion) info.push('composite_partially_mapped');
      else flags.push('composite_partial');
    }
    if (token.kind === 'merchant') {
      for (const p of parts) for (const s of p.merchantSlugs || []) if (!ctx.index.merchants.has(s)) needsDirectory.push(s);
    }
    if (token.kind === 'platform') {
      for (const p of parts) for (const s of p.platformSlugs || []) if (!ctx.index.platforms.has(s)) needsDirectory.push(`platform:${s}`);
    }
  }
  const tokenHasCategory = parts.some((p) => p.categorySlug);
  const tokenHasBrand = parts.some((p) => p.merchantSlugs?.length || p.platformSlugs?.length);

  // 2. Category restatements in conditions ("category": "fuel").
  for (const { key, value } of cond.restatedCategories) {
    if (isWildcard(value)) continue;
    const t2 = resolveCategoryToken(categoryKey(value), ctx);
    if (t2.kind === 'unrestricted') continue;
    if (t2.kind === 'non_purchase') {
      info.push(`non_purchase_condition:${key}`);
      continue;
    }
    if (t2.kind === 'category') {
      const slug = t2.parts[0].categorySlug;
      if (tokenHasCategory) {
        if (!parts.every((p) => p.categorySlug === slug)) {
          // A different label for the same thing is common ("supermarket" on
          // a grocery rule); a genuinely different category is a conflict.
          if (!parts.some((p) => p.categorySlug === slug)) info.push(`category_conflict:${key}`);
        }
      } else if (!tokenHasBrand) {
        parts = parts.map((p) => ({ ...p, categorySlug: slug, broad: t2.parts[0].broad }));
        if (t2.flags.includes('broad_category')) flags.push('broad_category');
      }
      continue;
    }
    // Merchant/platform/unknown label. Harmless when the rule is already
    // restricted to a category or brand; otherwise it narrows in a way we
    // can't express.
    if (!tokenHasCategory && !tokenHasBrand) {
      if (['merchant', 'platform'].includes(t2.kind)) {
        parts = parts.map((p) => andPart(p, t2.parts[0]) || p);
      } else if (!cond.mccInclude.length) {
        info.push(`unmapped_condition_category:${key}`);
        unmappedTokens.push(String(value));
      }
    }
  }

  // 3. Transaction types (merchant_emi, balance_transfer, ...).
  if (cond.restatedTransactionTypes?.length) {
    const emiOnly = cond.restatedTransactionTypes.every((v) => /emi|flexipay/i.test(String(v)));
    const emiRule = parts.some((p) => p.categorySlug === 'emi') || String(src?.rail) === 'emi';
    if (!(emiOnly && emiRule)) info.push('transaction_type');
  }

  // 4. channel_type naming a brand, platform, rail or category.
  if (cond.channelTokenParts) {
    for (const ctp of cond.channelTokenParts) {
      if (ctp.rail) {
        parts = parts.map((p) => andPart(p, { rail: ctp.rail }) || { ...p, conflict: true });
      } else if (ctp.merchantSlugs?.length) {
        if (!tokenHasBrand) parts = parts.map((p) => andPart(p, { merchantSlugs: ctp.merchantSlugs }) || { ...p, conflict: true });
      } else if (ctp.platformSlugs?.length) {
        const sameBrand = parts.some((p) => p.platformSlugs?.some((s) => ctp.platformSlugs.includes(s)));
        if (!sameBrand && !parts.some((p) => p.merchantSlugs?.length)) {
          parts = parts.map((p) => andPart(p, { platformSlugs: ctp.platformSlugs }) || { ...p, conflict: true });
        }
      }
    }
  }
  if (cond.channelCategoryToken) {
    const ct = cond.channelCategoryToken;
    if (ct.kind === 'category') {
      const slug = ct.parts[0].categorySlug;
      if (tokenHasCategory) {
        if (!parts.some((p) => p.categorySlug === slug)) info.push('channel_category_conflict');
      } else if (!tokenHasBrand) {
        parts = parts.map((p) => ({ ...p, categorySlug: slug }));
      }
    } else if (ct.kind === 'composite') {
      if (!tokenHasCategory && !tokenHasBrand) info.push('channel_type');
    }
  }

  // 5. Category list on the rule (PhonePe's eligible categories).
  if (cond.categoryList?.length) {
    const listParts = [];
    const listUnmapped = [];
    for (const item of cond.categoryList) {
      const t = resolveCategoryToken(categoryKey(item), ctx);
      if (['category', 'merchant', 'platform'].includes(t.kind) || t.kind === 'composite') {
        listParts.push(...t.parts);
        if (t.kind === 'composite' && t.unmapped.length) listUnmapped.push(...t.unmapped);
      } else if (t.kind === 'unrestricted') {
        listParts.push({});
      } else {
        listUnmapped.push(item);
      }
    }
    const listIsUnrestricted = listParts.some((p) => !p.categorySlug && !p.merchantSlugs && !p.platformSlugs);
    if (listIsUnrestricted && !listUnmapped.length) {
      // "all eligible categories" — no narrowing.
    } else if (!listParts.length) {
      info.push(`unmapped_category_list:${cond.categoryListKey}`);
      unmappedTokens.push(...listUnmapped);
    } else {
      if (listUnmapped.length) {
        unmappedTokens.push(...listUnmapped);
        if (isExclusion) info.push('category_list_partially_mapped');
        else flags.push('partial_category_list');
      }
      const crossed = [];
      for (const p of parts) {
        for (const lp of listParts) {
          const merged = andPart(p, lp);
          if (merged) crossed.push(merged);
        }
      }
      if (crossed.length) parts = dedupeParts(crossed);
      else info.push('category_list_conflict');
    }
  }

  // 6. `any` alternatives.
  if (cond.alternatives?.length) {
    const alts = [];
    let unmappable = 0;
    for (const sub of cond.alternatives) {
      if (sub.blockers.length || sub.merchantProse.length) {
        unmappable += 1;
        continue;
      }
      let altParts = [partFromMapping(sub)];
      if (sub.categoryList?.length) {
        const cats = sub.categoryList.map((c) => resolveCategoryToken(categoryKey(c), ctx));
        if (cats.every((c) => c.kind === 'category')) {
          altParts = cats.flatMap((c) => altParts.map((ap) => ({ ...ap, categorySlug: c.parts[0].categorySlug })));
        }
      }
      alts.push(...altParts);
    }
    if (!alts.length) info.push('unmappable_alternatives');
    else {
      if (unmappable) {
        if (isExclusion) info.push('alternatives_partially_mapped');
        else flags.push('partial_alternatives');
      }
      const crossed = [];
      for (const p of parts) for (const a of alts) {
        const merged = andPart(p, a);
        if (merged) crossed.push(merged);
      }
      parts = crossed.length ? dedupeParts(mergeMccAlternatives(crossed)) : parts;
      if (!crossed.length) info.push('alternatives_conflict');
    }
  }

  // 7. Merchants / platforms named in conditions.
  if (cond.merchantSlugs.length || cond.platformSlugs.length) {
    parts = parts.map((p) => {
      let out = p;
      if (cond.merchantSlugs.length) {
        const r = mergeSlugs(out.merchantSlugs, cond.merchantSlugs);
        out = r.conflict ? { ...out, conflict: true } : { ...out, merchantSlugs: r.slugs };
      }
      if (cond.platformSlugs.length) {
        // A merchant rule whose condition names a payment app ("Swiggy, via
        // PhonePe") is AND-ed; the merchant's own app is not a separate
        // restriction.
        const r = mergeSlugs(out.platformSlugs, cond.platformSlugs);
        out = r.conflict ? { ...out, conflict: true } : { ...out, platformSlugs: r.slugs };
      }
      return out;
    });
  }
  for (const prose of cond.merchantProse) {
    const anyPlatform = parts.some((p) => p.platformSlugs?.length);
    const anyMerchant = parts.some((p) => p.merchantSlugs?.length);
    const text = String(prose.text);
    if (prose.partial) {
      if (isExclusion) info.push(`partial_merchant_list:${prose.key}`);
      else flags.push('partial_merchant_list');
      continue;
    }
    if (anyPlatform && /(participating|partner|select|eligible|brands|merchants|\d+\s*\+|leading|catalogue)/i.test(text)) {
      flags.push('merchant_prose_platform_scoped');
      continue;
    }
    if (anyMerchant) {
      const mentions = parts.some((p) => (p.merchantSlugs || []).some((s) => {
        const m = ctx.index.merchants.get(s);
        const names = [s.replace(/_/g, ' '), ...(m?.aliases || []), m?.name].filter(Boolean);
        return names.some((n) => new RegExp(`\\b${normalizeText(n).replace(/ /g, '\\s+')}\\b`).test(normalizeText(text)));
      }));
      if (mentions && !isExclusion) {
        flags.push('merchant_prose_restates');
        continue;
      }
    }
    info.push(`unresolved_merchant:${prose.key}`);
    needsDirectory.push(text.slice(0, 60));
  }

  // 8. Rails.
  const sr = sourceRail(src, ctx);
  const rails = [];
  if (sr.rail) rails.push({ rail: sr.rail });
  if (sr.platform) parts = parts.map((p) => andPart(p, { platformSlugs: [sr.platform] }) || { ...p, conflict: true });
  if (sr.blocked) info.push(`rail:${sr.blocked}`);
  rails.push(...cond.rails);
  const anyPlatform = parts.some((p) => p.platformSlugs?.length);
  let railSet = uniq(rails.map((r) => r.rail));
  // A portal or app is itself online; an "online" rail on top would make the
  // rule miss every transaction whose rail is unknown.
  if (anyPlatform && railSet.length && railSet.every((r) => r === 'online')) railSet = [];
  if (railSet.length > 1) info.push('rail_conflict');
  if (isExclusion && rails.some((r) => r.inexact)) info.push('inexact_rail_on_exclusion');
  if (railSet.length === 1) parts = parts.map((p) => andPart(p, { rail: railSet[0] }) || { ...p, conflict: true });

  // 9. Blockers.
  for (const b of cond.blockers) {
    if (b.key === 'channel_type' && (parts.some((p) => p.merchantSlugs?.length || p.platformSlugs?.length))) {
      // channel_type prose on an already brand-restricted rule is a restatement.
      flags.push('channel_type_restates_brand');
      continue;
    }
    info.push(`condition:${b.key}`);
    // D13(b): terms that depend on who the cardholder is (tier, paid
    // membership) are deferred, never guessed.
    if (USER_ATTRIBUTE_KEY.test(b.key)) flags.push('depends_on_user_attribute');
  }

  // 10. Amounts, MCCs, excluded categories.
  let minTxn = cond.minTxn;
  let maxTxn = cond.maxTxn;
  if (isExclusion && (minTxn !== null || maxTxn !== null)) {
    // "No reward below ₹100" inverts to "applies at/above ₹100" if stored as
    // min_txn_inr on a zero-rate rule.
    info.push('amount_bound_on_exclusion');
    minTxn = null;
    maxTxn = null;
  }
  if (cond.mccInclude.length) parts = parts.map((p) => andPart(p, { mccInclude: cond.mccInclude }) || { ...p, conflict: true });
  if (cond.mccExclude.length) parts = parts.map((p) => andPart(p, { mccExclude: cond.mccExclude }) || p);
  if (cond.unmappedExcluded.length) flags.push('unmapped_excluded_category');

  if (parts.some((p) => p.conflict)) info.push('restriction_conflict');
  for (const p of parts) {
    if (p.categorySlug && !APP_CATEGORIES.has(p.categorySlug)) info.push(`invalid_category:${p.categorySlug}`);
  }

  // 11. Exclusions with a category AND an MCC list: one row per restriction,
  // because an exclusion applies to the union (the category, or any listed
  // MCC). The category row stays v1-visible; the MCC row is v2-only.
  if (isExclusion && !info.length) {
    const split = [];
    for (const p of parts) {
      if (p.categorySlug && p.mccInclude?.length && !p.merchantSlugs?.length && !p.platformSlugs?.length) {
        if (!p.broad) split.push({ ...p, mccInclude: [] });
        split.push({ ...p, categorySlug: null, broad: false });
      } else {
        split.push(p);
      }
    }
    parts = split;
  }

  const effectiveFrom = !isNA(src?.effective_from) && DATE.test(String(src.effective_from)) ? String(src.effective_from) : null;
  const effectiveTo = !isNA(src?.effective_to) && DATE.test(String(src.effective_to)) ? String(src.effective_to) : null;
  if (!isNA(src?.effective_from) && !effectiveFrom) flags.push('unreadable_effective_date');

  const isInfo = info.length > 0;
  const priority = Number.isInteger(src?.priority) ? src.priority : 100;
  const sourceId = isNA(src?.id) ? null : String(src.id);
  const capRefs = uniq([src?.action?.cap_reference, ...cond.capRefs].filter((v) => !isNA(v)).map(String));
  const displayNote = typeof src?.action?.reason === 'string' && src.action.reason.trim()
    ? src.action.reason.trim().slice(0, 300)
    : null;

  const rows = parts.map((p, partIdx) => {
    const merchantSlugs = uniq(p.merchantSlugs || []).sort();
    const platformSlugs = uniq(p.platformSlugs || []).sort();
    const mccInclude = uniq(p.mccInclude || []).sort();
    const mccExclude = uniq(p.mccExclude || []).sort();
    const restricted = hasRestriction({ ...p, minTxn, maxTxn });
    const rowInfo = [...info];
    if (isExclusion && !isInfo && !p.categorySlug && !merchantSlugs.length && !platformSlugs.length &&
        !mccInclude.length && !p.rail) {
      // An exclusion with nothing to match on would exclude every spend.
      rowInfo.push('unrestricted_exclusion');
    }
    const rowIsInfo = rowInfo.length > 0;
    let role;
    if (forcedRole && forcedRole !== 'info' && !rowIsInfo) role = forcedRole;
    else if (rowIsInfo) role = 'info';
    else if (isExclusion) role = 'exclusion';
    else if (!isAccelerator && !restricted) role = 'base';
    else role = 'earn';
    const rowFlags = [];
    if (role === 'earn' && isAccelerator && !restricted) rowFlags.push('unrestricted_accelerator');
    if (p.broad && role !== 'info') rowFlags.push('broad_category');

    const v2Reasons = [];
    if (role === 'info') v2Reasons.push('info');
    if (platformSlugs.length) v2Reasons.push('platform');
    if (mccInclude.length || mccExclude.length) v2Reasons.push('mcc');
    if (merchantSlugs.length > 1) v2Reasons.push('merchants');
    if (ur.blockInr !== null) v2Reasons.push('block_inr');
    if (role === 'exclusion' && !p.categorySlug && !merchantSlugs.length && !platformSlugs.length && !mccInclude.length && p.rail) {
      // v1 treats an unknown rail as a match, so a rail-only exclusion would
      // exclude almost every imported transaction.
      v2Reasons.push('rail_only_exclusion');
    }
    if (ur.unit === null) v2Reasons.push('no_unit');
    const minEngineVersion = v2Reasons.length ? 2 : 1;

    return {
      key: null, // assigned by transformRewardRules
      source_local_id: sourceId,
      part: parts.length > 1 ? partIdx + 1 : null,
      source_category_token: rawToken || null,
      evaluation_type: evaluationType || null,
      category_slug: p.categorySlug || null,
      merchant_pattern: merchantSlugs.length === 1 ? distinctiveAlias(merchantSlugs[0], ctx.index) : null,
      rail: p.rail || null,
      unit: ur.unit || 'cashback_percent',
      rate: ur.rate === null ? 0 : ur.rate,
      min_txn_inr: minTxn,
      max_txn_inr: maxTxn,
      priority,
      effective_from: effectiveFrom,
      effective_to: effectiveTo,
      excluded_category_slugs: cond.excludedCategorySlugs,
      rule_role: role,
      merchant_slugs: merchantSlugs,
      platform_slugs: platformSlugs,
      mcc_include: mccInclude,
      mcc_exclude: mccExclude,
      block_inr: ur.blockInr,
      min_engine_version: minEngineVersion,
      display_note: displayNote,
      currency: isExclusion ? null : ur.currency,
      cap_refs: capRefs,
      info_reasons: uniq(rowInfo),
      flags: uniq([...flags, ...rowFlags]),
      v2_reasons: v2Reasons,
    };
  });

  for (const row of rows) {
    for (const s of row.merchant_slugs) if (!ctx.index.merchants.has(s)) needsDirectory.push(s);
    for (const s of row.platform_slugs) if (!ctx.index.platforms.has(s)) needsDirectory.push(`platform:${s}`);
  }

  return {
    rows,
    infoReasons: uniq(info),
    flags: uniq(flags),
    unmappedTokens: uniq(unmappedTokens.filter(Boolean)),
    needsDirectory: uniq(needsDirectory),
  };
}

function dedupeParts(parts) {
  const seen = new Set();
  const out = [];
  for (const p of parts) {
    const sig = JSON.stringify([p.categorySlug, p.merchantSlugs, p.platformSlugs, p.mccInclude, p.mccExclude, p.rail]);
    if (seen.has(sig)) continue;
    seen.add(sig);
    out.push(p);
  }
  return out;
}

// Alternatives that differ only in their MCC list become one row with the
// union of MCCs (Atlas: airline MCCs or hotel MCCs).
function mergeMccAlternatives(parts) {
  const groups = new Map();
  const out = [];
  for (const p of parts) {
    if (!p.mccInclude?.length) {
      out.push(p);
      continue;
    }
    const sig = JSON.stringify([p.categorySlug, p.merchantSlugs, p.platformSlugs, p.mccExclude, p.rail]);
    if (!groups.has(sig)) {
      groups.set(sig, { ...p, mccInclude: [...p.mccInclude] });
      out.push(groups.get(sig));
    } else {
      const g = groups.get(sig);
      g.mccInclude = uniq([...g.mccInclude, ...p.mccInclude]).sort();
    }
  }
  return out;
}

/**
 * All of a record's reward rules.
 * @returns {{rows, perSource: object[]}}
 */
function transformRewardRules(record, ctx) {
  const rows = [];
  const perSource = [];
  const usedKeys = new Set();
  (record?.reward_rules || []).forEach((src, idx) => {
    const result = transformRule(src, idx, ctx);
    const baseKey = isNA(src?.id) ? `rule-${idx + 1}` : String(src.id);
    for (const row of result.rows) {
      let key = row.part ? `${baseKey}#${row.part}` : baseKey;
      while (usedKeys.has(key)) key = `${key}~${idx + 1}`;
      usedKeys.add(key);
      row.key = key;
      rows.push(row);
    }
    perSource.push({
      source_local_id: isNA(src?.id) ? null : String(src.id),
      evaluation_type: src?.evaluation_type || null,
      category_token: isNA(src?.category_id) ? null : String(src.category_id),
      keys: result.rows.map((r) => r.key),
      roles: uniq(result.rows.map((r) => r.rule_role)),
      info_reasons: uniq([...result.infoReasons, ...result.rows.flatMap((r) => r.info_reasons)]),
      flags: result.flags,
      unmapped_tokens: result.unmappedTokens,
      needs_directory: result.needsDirectory,
    });
  });
  return { rows, perSource };
}

module.exports = {
  distinctiveAlias,
  transformRewardRules,
  transformRule,
  unitAndRate,
};
