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
  AIRLINE_OR_HOTEL,
  APP_CATEGORIES,
  MCC_CATEGORY,
  ISSUER_PORTAL,
  NARROW_TOKEN_MCC,
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
const USER_ATTRIBUTE_KEY = /(membership|tier|prime|neon|selected|selection|plan$|pack|variant|relationship|customer_segment|salary|premier|eligible_card|card_side|opt_in|enrol)/i;
const ROLES = new Set(['base', 'earn', 'exclusion', 'info']);
const BRANDISH_BRAND = /(paytm|amazon|flipkart|smartbuy|phonepe|swiggy|zomato|tata|neu|reliance|samsung|apple|kiwi|myntra|irctc|indigo|uber|\bola\b|lic|hpcl|bpcl|indianoil|iocl|jio|airtel|marriott|taj|vistara|air_india|makemytrip|yatra|cleartrip|bookmyshow|pvr|landmark|shoppers|lifestyle)/;
const BRANDISH = /(paytm|amazon|flipkart|smartbuy|phonepe|swiggy|zomato|tata|reliance|samsung|apple|kiwi|myntra|irctc|indigo|uber|ola|lic|hpcl|bpcl|indianoil|iocl|jio|airtel|partner|select|preferred|exclusive|promoted|accelerated|brand)/;

// D19c/D20a: true = also emit a v2 category + MCC row (the category stands in
// for an unknown MCC) next to the v2 MCC-only row.
const EXCLUSION_MCC_ROW_KEEPS_CATEGORY = true;

const UNIT_BLOCK = { points_per_100: 100, points_per_150: 150, points_per_200: 200, miles_per_100: 100 };
function valuePerRupee(unit, rate, pointValue, blockInr) {
  if (rate === null || rate === undefined || !unit) return null;
  if (unit === 'cashback_percent' || unit === 'discount_percent') return Number(rate) / 100;
  const block = blockInr || UNIT_BLOCK[unit];
  if (!block) return null;
  return (Number(rate) / block) * (Number(pointValue) || 0);
}

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
    return portal ? { platform: portal, portal: true } : { blocked: raw, portal: true };
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
    const sameExact = out.categorySlug === extra.categorySlug && !out.broad;
    out.categorySlug = extra.categorySlug;
    // D18f: a narrow item stays narrow inside a combined restriction (its
    // MCC pinning comes from its token). An exact match on either side wins.
    if (extra.broad && !sameExact) {
      out.broad = true;
      out.narrowTokens = uniq([...(out.narrowTokens || []), ...(extra.narrowTokens || []), extra.token].filter(Boolean));
      if (!out.token) out.token = extra.token;
    } else if (!extra.broad) {
      out.broad = false;
      out.narrowTokens = [];
    }
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
  // D20b: an "exclusion" whose action states a positive earn rate ("base 1
  // RP", "earns at the standard rate") is a reduced-rate earning rule on the
  // excluded scope — a carve-out from an accelerator — not an exclusion.
  const statedRate = (asNumber(src?.action?.points_per_block) ?? 0) > 0 || (asNumber(src?.action?.cashback_percent) ?? 0) > 0;
  const isCarveOut = evaluationType === 'exclusion' && statedRate;
  const isExclusion = evaluationType === 'exclusion' && !isCarveOut;
  const scopeLists = isExclusion || isCarveOut;
  const isAccelerator = evaluationType === 'accelerator';
  const rawToken = isNA(src?.category_id) ? '' : String(src.category_id);

  const token = resolveCategoryToken(categoryKey(rawToken), ctx);
  // 'broad_category' is a per-row fact (set below), not a per-rule one.
  flags.push(...token.flags.filter((f) => f !== 'broad_category'));
  const cond = mapRuleConditions(src, ctx);
  flags.push(...cond.flags);

  const ur = isExclusion
    ? { unit: ctx.card.baseUnit && ctx.card.baseUnit.startsWith('points') ? ctx.card.baseUnit : 'cashback_percent', rate: 0, blockInr: null, currency: null, flags: [] }
    : unitAndRate(src, cond.block, ctx.card);
  flags.push(...ur.flags);
  if (!isExclusion && ur.rate === null) info.push('missing_rate');
  // D18c: a rule paying less than the card's base (same currency).
  // Compared in the card's own currency per rupee (points per ₹, or % ),
  // so it works when the card has no ₹ value per point.
  const ruleEarn = valuePerRupee(ur.unit, ur.rate, 1, ur.blockInr);
  const isReduced = !isExclusion && ur.rate !== null && ur.currency && ur.currency === ctx.card.baseCurrency &&
    ruleEarn !== null && ctx.card.baseEarnPerRupee != null && ruleEarn < ctx.card.baseEarnPerRupee - 1e-12;

  if (!isExclusion && rewardRuleHasUnsupportedTrigger(src)) info.push('unsupported_trigger');
  if (!isExclusion && /up[\s_-]*to[\s_-]*\d+(?:\.\d+)?\s*(?:x\b|%|(?:bonus\s+|reward\s+)?points?\b|rp\b|miles\b)/i.test(`${src?.id || ''} ${src?.action?.reason || ''}`)) {
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
  let tokenNeedsConditions = null;
  const pendingNonPurchase = [];
  if (token.kind === 'non_purchase') {
    // Cash advances, fees, balance transfers: judged in step 10 — an
    // exclusion pinned to the ATM rail or to MCCs is still expressible.
    pendingNonPurchase.push('non_purchase_category');
    unmappedTokens.push(rawToken);
    parts = [{}];
  } else if (token.kind === 'txn_attribute') {
    info.push('depends_on_txn_attribute');
    unmappedTokens.push(rawToken);
    parts = [{}];
  } else if (token.kind === 'unknown') {
    // A label such as "select_online_merchants" or "preferred_partners": the
    // rule is usable only if its conditions carry the actual restriction (an
    // MCC list, a merchant list, a category list). A label naming a brand
    // ("paytm_select_spends") additionally needs that brand in the
    // conditions. Checked after the conditions are mapped (step 12).
    tokenNeedsConditions = BRANDISH_BRAND.test(rawToken) || token.group ? 'brand' : 'any';
    if (token.group) needsDirectory.push(`group:${token.group}`);
    unmappedTokens.push(rawToken);
    parts = [{}];
  } else {
    parts = token.parts.map((p) => ({ ...p }));
    if (token.kind === 'composite' && token.unmapped.length) {
      unmappedTokens.push(rawToken);
      flags.push('composite_partial');
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
      pendingNonPurchase.push(`non_purchase_condition:${key}`);
      continue;
    }
    if (t2.kind === 'category') {
      const slug = t2.parts[0].categorySlug;
      const narrower = t2.parts[0].broad;
      if (tokenHasCategory) {
        if (!parts.some((p) => p.categorySlug === slug)) {
          // A genuinely different category is a conflict.
          info.push(`category_conflict:${key}`);
        } else if (narrower) {
          // "hotels" on a travel rule narrows it (D17f): the narrow token
          // decides the MCCs below (D17a), never the whole of travel.
          parts = parts.map((p) => (p.categorySlug === slug
            ? { ...p, broad: true, narrowTokens: [t2.parts[0].token] }
            : p));
        }
        // Same category, not narrower ("supermarket" on a grocery rule): a restatement.
      } else if (!tokenHasBrand) {
        parts = parts.map((p) => ({ ...p, categorySlug: slug, broad: narrower, narrowTokens: narrower ? [t2.parts[0].token] : [] }));
      }
      continue;
    }
    // D18d: "utility_bill_payments", "telecom_and_utilities" on a bills rule:
    // every mapped part is the rule's own category — a restatement.
    if (t2.kind === 'composite' && !t2.unmapped.length && t2.parts.length &&
        t2.parts.every((tp) => tp.categorySlug && parts.some((p) => p.categorySlug === tp.categorySlug))) {
      continue;
    }
    // Merchant/platform/unknown label.
    if (!tokenHasCategory && !tokenHasBrand) {
      if (['merchant', 'platform'].includes(t2.kind)) {
        parts = parts.map((p) => andPart(p, t2.parts[0]) || p);
      } else if (!cond.mccInclude.length) {
        info.push(`unmapped_condition_category:${key}`);
        unmappedTokens.push(String(value));
      }
    } else if (tokenHasCategory && !['merchant', 'platform'].includes(t2.kind) && !cond.mccInclude.length) {
      // D17f: an unknown sub-category on a category rule ("flights" vs
      // "hotels" on two travel rules at different rates) narrows it in a way
      // we can't express. An earning rule becomes info; an exclusion may
      // ignore it (it then excludes more).
      if (isExclusion) flags.push('exclusion_scope_broadened');
      else if (isReduced) flags.push('reduced_rate_kept_broad'); // D18c: broad is conservative here
      else {
        info.push(`unmapped_condition_category:${key}`);
        unmappedTokens.push(String(value));
      }
    }
  }

  // 3. Transaction types (merchant_emi, balance_transfer, ...) are judged
  // in step 10, once rails and MCCs are known.

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
        parts = parts.map((p) => ({ ...p, categorySlug: slug, broad: ct.parts[0].broad, narrowTokens: ct.parts[0].narrowTokens || [] }));
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
        flags.push('partial_category_list');
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
        flags.push('partial_alternatives');
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
        if (out.group) {
          // A group token ("tata_neu_partner_brands") with the issuer's own
          // brand list: the explicit list is the restriction.
          out = { ...out, merchantSlugs: cond.merchantSlugs };
          flags.push('group_replaced_by_condition_list');
        } else {
          const r = mergeSlugs(out.merchantSlugs, cond.merchantSlugs);
          out = r.conflict ? { ...out, conflict: true } : { ...out, merchantSlugs: r.slugs };
        }
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
      flags.push('partial_merchant_list');
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
  const namedPlatform = parts.some((p) => p.platformSlugs?.length);
  if (sr.platform && !namedPlatform) parts = parts.map((p) => andPart(p, { platformSlugs: [sr.platform] }) || { ...p, conflict: true });
  // "smartbuy_or_equivalent_portal" means "the issuer's portal"; fine when
  // the rule (or the issuer) names one.
  if (sr.blocked && !(sr.portal && namedPlatform)) info.push(`rail:${sr.blocked}`);
  rails.push(...cond.rails);
  const anyPlatform = parts.some((p) => p.platformSlugs?.length);
  let railSet = uniq(rails.map((r) => r.rail));
  // A portal or app is itself online; an "online" rail on top would make the
  // rule miss every transaction whose rail is unknown.
  if (anyPlatform && railSet.length && railSet.every((r) => r === 'online')) railSet = [];
  if (railSet.length > 1) info.push('rail_conflict');
  if (isExclusion && rails.some((r) => r.inexact)) info.push('inexact_rail_on_exclusion');
  if (railSet.length === 1) parts = parts.map((p) => andPart(p, { rail: railSet[0] }) || { ...p, conflict: true });

  // 8b. Merchants named under other keys ("location": "HPCL petrol pump").
  for (const mention of cond.mentions || []) {
    if (mention.merchant) {
      const has = parts.some((p) => p.merchantSlugs?.includes(mention.merchant));
      if (!has) parts = parts.map((p) => andPart(p, { merchantSlugs: [mention.merchant] }) || { ...p, conflict: true });
    } else if (mention.platform) {
      const has = parts.some((p) => p.platformSlugs?.includes(mention.platform));
      if (!has) parts = parts.map((p) => andPart(p, { platformSlugs: [mention.platform] }) || { ...p, conflict: true });
    }
  }

  // An exclusion still restricted by something we did map (a category, a
  // brand, a rail, MCCs) may ignore extra sub-scope it can't express: it then
  // excludes a little more than the source, which H2 allows (it can only hide
  // reward). Never for amounts, transaction attributes, user attributes or
  // negations — those change who is excluded, not how much.
  const exclusionAnchored = isExclusion && (cond.mccInclude.length > 0 ||
    parts.every((p) => p.categorySlug || p.merchantSlugs?.length || p.platformSlugs?.length || p.rail));
  const SCOPE_KEY = /(types?|scope|services|target|items|origin|location|conversion|channel|channel_type|definition|kind|source|notice|purpose|mode|requirement)$/;

  // 9. Blockers.
  for (const b of cond.blockers) {
    if (b.key === 'channel_type' && (parts.some((p) => p.merchantSlugs?.length || p.platformSlugs?.length) ||
        (scopeLists && (cond.listedExcludedMerchants.length || cond.listedExcludedPlatforms.length)))) {
      // channel_type prose on an already brand-restricted rule is a restatement.
      flags.push('channel_type_restates_brand');
      continue;
    }
    if (/^non_/.test(b.key) && (cond.exceptMerchantSlugs.length || cond.exceptPlatformSlugs.length)) {
      continue; // "non_partner: true" restates the exception list
    }
    if (exclusionAnchored && SCOPE_KEY.test(b.key) && !USER_ATTRIBUTE_KEY.test(b.key) &&
        !/\b(not|non|outside|except|excluding|international|domestic|foreign)\b/i.test(String(b.detail || ''))) {
      flags.push('exclusion_scope_broadened');
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
  if (isExclusion && maxTxn !== null) {
    // "Excluded up to ₹X" has no form here (D16b gives max_txn_inr on an
    // exclusion the opposite meaning).
    info.push('amount_bound_on_exclusion');
    maxTxn = null;
  }
  if (isExclusion && minTxn !== null) {
    // D16b: "no reward below ₹100" on a zero-rate rule is an exclusion that
    // applies while amount < ₹100 — stored as max_txn_inr.
    maxTxn = minTxn;
    minTxn = null;
    flags.push('min_amount_exclusion');
  }
  if (cond.mccInclude.length) parts = parts.map((p) => andPart(p, { mccInclude: cond.mccInclude }) || { ...p, conflict: true });
  if (cond.mccExclude.length) parts = parts.map((p) => andPart(p, { mccExclude: cond.mccExclude }) || p);

  // Transaction types and non-purchase channels (cash withdrawal, merchant
  // EMI, fees). Fine on an exclusion that is otherwise pinned down by a
  // rail (ATM, EMI), MCCs, the EMI category or a brand; otherwise not
  // expressible.
  const pinned = parts.every((p) => p.mccInclude?.length || ['atm', 'emi'].includes(p.rail) ||
    p.categorySlug === 'emi' || p.merchantSlugs?.length || p.platformSlugs?.length);
  if (cond.restatedTransactionTypes?.length) {
    const emiOnly = cond.restatedTransactionTypes.every((v) => /emi|flexipay/i.test(String(v)));
    const emiRule = parts.some((p) => p.categorySlug === 'emi' || p.rail === 'emi');
    if (emiOnly && emiRule) {
      // merchant EMI on an EMI rule: a restatement.
    } else if (isExclusion && pinned) {
      flags.push('exclusion_scope_broadened');
    } else {
      info.push('transaction_type');
    }
  }
  if (cond.channelNonPurchase) pendingNonPurchase.push('non_purchase_channel');
  if (pendingNonPurchase.length) {
    const pinnedNonPurchase = parts.every((p) => p.mccInclude?.length || ['atm', 'emi'].includes(p.rail));
    if (isExclusion && pinnedNonPurchase) flags.push('exclusion_scope_broadened');
    else info.push(...pendingNonPurchase);
  }
  if (cond.unmappedExcluded.length) flags.push('unmapped_excluded_category');

  if (tokenNeedsConditions) {
    const restrictedBy = (p) => (tokenNeedsConditions === 'brand'
      ? p.merchantSlugs?.length || p.platformSlugs?.length
      : p.categorySlug || p.merchantSlugs?.length || p.platformSlugs?.length || p.mccInclude?.length);
    if (parts.every(restrictedBy)) flags.push('token_replaced_by_conditions');
    else info.push('unmapped_category_token');
  }
  if (parts.some((p) => p.conflict)) info.push('restriction_conflict');
  for (const p of parts) {
    if (p.categorySlug && !APP_CATEGORIES.has(p.categorySlug)) info.push(`invalid_category:${p.categorySlug}`);
  }

  // 10b. D17(d): on an exclusion, the source's excluded categories /
  // merchants are the exclusion's own scope ("PayZapp: no accelerator on
  // rent, education, ..."): one exclusion row per listed item, within the
  // rule's other restrictions. Never exception lists.
  // D18e: "non-LIC insurance" with excluded_merchants ["LIC"] — a brand
  // listed against a "non-/other than/except" exclusion is its exception.
  const negatedScope = scopeLists && /(^|[_\s-])non[_\s-]|other than|except|excluding/i.test(`${rawToken} ${src?.action?.reason || ''} ${src?.id || ''}`);
  const listedCats = scopeLists ? cond.excludedCategorySlugs : [];
  const listedMerchants = scopeLists && !negatedScope ? cond.listedExcludedMerchants : [];
  const listedPlatforms = scopeLists && !negatedScope ? cond.listedExcludedPlatforms : [];
  if (listedCats.length || listedMerchants.length || listedPlatforms.length) {
    const expanded = [];
    for (const p of parts) {
      const extras = [
        ...listedCats.map((c) => ({ categorySlug: c })),
        ...listedMerchants.map((m) => ({ merchantSlugs: [m] })),
        ...listedPlatforms.map((pl) => ({ platformSlugs: [pl] })),
      ];
      if (p.categorySlug) expanded.push(p); // its own category stays excluded too
      const base = p.categorySlug ? { ...p, categorySlug: null, broad: false, narrowTokens: [], mccInclude: [] } : p;
      for (const extra of extras) {
        const merged = andPart(base, extra);
        if (merged) expanded.push(merged);
      }
    }
    parts = dedupeParts(expanded);
    flags.push('exclusion_list_expanded');
    if (cond.unmappedExcluded.length) flags.push('partial_category_list');
  }
  const ruleExcludedCategories = scopeLists ? [] : cond.excludedCategorySlugs;
  const exceptMerchants = uniq([...cond.exceptMerchantSlugs, ...(scopeLists && !negatedScope ? [] : cond.listedExcludedMerchants)]).sort();
  const exceptPlatforms = uniq([...cond.exceptPlatformSlugs, ...(scopeLists && !negatedScope ? [] : cond.listedExcludedPlatforms)]).sort();

  // D18e / D19a: an exclusion that only takes away an accelerated/bonus rate
  // (or only counts against a milestone) is not a full exclusion. Only when
  // EVERY excluded benefit is so qualified; any core/base or plain
  // "reward points" mention makes it a full exclusion.
  if (isExclusion) {
    const text = `${src?.action?.reason || ''} ${src?.conditions?.description || ''}`;
    if (classifyExclusionText(text) === 'bonus_only') {
      info.push('bonus_only_exclusion');
      flags.push('bonus_only_exclusion');
    }
  }

  // The categories the rule had before any MCC narrowing (D18c projection).
  const preNarrowCategories = uniq(parts.map((p) => p.categorySlug).filter(Boolean));

  // 10c. D17(a): a narrow token on an earning rule ("pharmacy", "hotels")
  // never widens to its app category. It is restricted to the token's MCCs
  // and the category is dropped (so an unknown MCC can't stand in for it);
  // with no MCC mapping the part is left out, and with no part left the
  // rule is info. An exclusion keeps the broad category (it excludes more).
  //  - D18i: on a merchant rule the merchant is the restriction; no MCCs
  //    (aggregators book under their own MCC).
  //  - D18c: a reduced-rate rule (below the card's base) is the inverse case:
  //    broad is conservative. Its v2 row is narrowed as above, plus a
  //    v1-only broad row at the reduced rate; with no MCC mapping it keeps
  //    the broad category in both feeds.
  if (!isExclusion) {
    const kept = [];
    let dropped = 0;
    for (const p of parts) {
      if (!p.broad || !p.categorySlug) {
        kept.push(p);
        continue;
      }
      const tokens = p.narrowTokens?.length ? p.narrowTokens : [p.token].filter(Boolean);
      if (p.merchantSlugs?.length) {
        kept.push({ ...p, categorySlug: null, broad: false, narrowOnMerchant: tokens.join('+') || 'narrow' });
        continue;
      }
      let mccs = null;
      if (p.mccInclude?.length) mccs = p.mccInclude; // the source's own MCC list pins it
      else if (tokens.length && tokens.every((tk) => NARROW_TOKEN_MCC[tk])) mccs = uniq(tokens.flatMap((tk) => NARROW_TOKEN_MCC[tk])).sort();
      if (mccs) {
        kept.push({ ...p, categorySlug: null, broad: false, mccInclude: mccs, narrowedByMcc: true });
        if (isReduced) kept.push({ ...p, mccInclude: [], maxEngine: 1, v1Projection: true });
      } else if (isReduced) {
        kept.push(p);
        flags.push('reduced_rate_kept_broad');
      } else {
        dropped += 1;
      }
    }
    if (kept.some((p) => p.narrowedByMcc)) flags.push('narrow_token_to_mcc');
    if (kept.some((p) => p.narrowOnMerchant)) flags.push('narrow_token_on_merchant');
    if (kept.some((p) => p.v1Projection)) flags.push('reduced_rate_v1_projection');
    if (dropped && kept.length) flags.push('composite_partial');
    if (dropped && !kept.length) info.push('narrow_category_without_mcc');
    if (kept.length) parts = dedupeParts(kept);
  }

  // 11. Exclusions with a category AND an MCC list: one row per restriction,
  // because an exclusion applies to the union (the category, or any listed
  // MCC). The category row stays v1-visible (D17b: dropping it would let v1
  // pay there); the MCC row is v2-only.
  //  - D18b: for a narrow token ("fast_food", "movie", "railways") the broad
  //    category row is v1-only. v2 uses only the precise MCC row (the
  //    source's MCCs, else the token's), so a fast-food exclusion doesn't
  //    zero all dining in v2. With no MCCs at all the broad row stays in both.
  if (isExclusion && !info.length) {
    const split = [];
    for (const p of parts) {
      const plain = !p.merchantSlugs?.length && !p.platformSlugs?.length;
      if (p.categorySlug && p.broad && plain) {
        const tokens = [...(p.narrowTokens || []), p.token].filter(Boolean);
        const mccs = p.mccInclude?.length
          ? p.mccInclude
          : NARROW_TOKEN_MCC[categoryKey(rawToken)] || (tokens.length && tokens.every((tk) => NARROW_TOKEN_MCC[tk])
            ? uniq(tokens.flatMap((tk) => NARROW_TOKEN_MCC[tk])).sort()
            : null);
        if (mccs) {
          split.push({ ...p, mccInclude: [], maxEngine: 1, v1Projection: true });
          split.push({ ...p, categorySlug: null, broad: false, mccInclude: mccs });
          flags.push('broad_exclusion_v1_only');
          continue;
        }
        split.push(p);
      } else if (p.categorySlug && p.mccInclude?.length && plain) {
        // D19c: an explicit MCC list is the exclusion's scope: v2 matches on
        // the MCCs; the category-only row is v1-only (v1 can't read MCCs).
        // Conservative reading (contract question, see WP2 report): the v2
        // row keeps the category too, so per C3.3 step 7 the MCC list decides
        // when the MCC is known and the category stands in when it isn't.
        // An MCC-only v2 row would stop excluding fuel/rent/wallet spend
        // whose MCC is unknown (most SMS) — widening v2 on ~770 exclusions.
        split.push({ ...p, mccInclude: [], maxEngine: 1, v1Projection: true });
        if (EXCLUSION_MCC_ROW_KEEPS_CATEGORY) split.push({ ...p });
        // D20a: and an MCC-only v2 row, so a known MCC in the list excludes
        // whatever category the transaction is labelled with.
        split.push({ ...p, categorySlug: null, broad: false });
        flags.push('mcc_scoped_exclusion');
      } else {
        split.push(p);
      }
    }
    parts = dedupeParts(split);
  }

  const effectiveFrom = !isNA(src?.effective_from) && DATE.test(String(src.effective_from)) ? String(src.effective_from) : null;
  const effectiveTo = !isNA(src?.effective_to) && DATE.test(String(src.effective_to)) ? String(src.effective_to) : null;
  if (!isNA(src?.effective_from) && !effectiveFrom) flags.push('unreadable_effective_date');

  const isInfo = info.length > 0;
  let priority = Number.isInteger(src?.priority) ? src.priority : 100;
  if (isCarveOut) {
    // Ahead of the accelerator it carves out of.
    if (ctx.minAcceleratorPriority != null) priority = Math.max(0, Math.min(priority, ctx.minAcceleratorPriority - 1));
    flags.push('exclusion_with_stated_rate');
  }
  const sourceId = isNA(src?.id) ? null : String(src.id);
  const capRefs = uniq([src?.action?.cap_reference, ...cond.capRefs].filter((v) => !isNA(v)).map(String));
  const displayNote = typeof src?.action?.reason === 'string' && src.action.reason.trim()
    ? src.action.reason.trim().slice(0, 300)
    : null;

  let rows = parts.map((p, partIdx) => {
    const merchantSlugs = uniq(p.merchantSlugs || []).sort();
    const platformSlugs = uniq(p.platformSlugs || []).sort();
    const mccInclude = uniq(p.mccInclude || []).sort();
    const mccExclude = uniq(p.mccExclude || []).sort();
    const restricted = hasRestriction({ ...p, minTxn, maxTxn }) ||
      exceptMerchants.length > 0 || exceptPlatforms.length > 0;
    const rowInfo = [...info];
    if (isExclusion && !isInfo && !p.categorySlug && !merchantSlugs.length && !platformSlugs.length &&
        !mccInclude.length && !p.rail && maxTxn === null) {
      // An exclusion with nothing to match on would exclude every spend.
      rowInfo.push('unrestricted_exclusion');
    }
    if (isCarveOut && !restricted) rowInfo.push('unrestricted_carve_out'); // nothing to scope the stated rate to
    // D18h: "PayTM spends except via PayTM" can never apply.
    const selfContradictory = platformSlugs.some((x) => exceptPlatforms.includes(x)) ||
      merchantSlugs.some((x) => exceptMerchants.includes(x));
    if (selfContradictory) rowInfo.push('self_contradictory_rule');
    const rowIsInfo = rowInfo.length > 0;
    let role;
    if (forcedRole && forcedRole !== 'info' && !rowIsInfo) role = forcedRole;
    else if (rowIsInfo) role = 'info';
    else if (isExclusion) role = 'exclusion';
    else if (!isAccelerator && !restricted) role = 'base';
    else role = 'earn';
    const rowFlags = [];
    if (['earn', 'base'].includes(role) && !restricted && !['unrestricted', 'none'].includes(token.kind) && !tokenNeedsConditions) {
      // Safety net (H2): the token restricted this rule, and nothing of that
      // survived mapping. Never let it become an every-spend rule.
      rowInfo.push('restriction_lost');
      role = 'info';
    }
    if (role === 'earn' && isAccelerator && !restricted) rowFlags.push('unrestricted_accelerator');
    if (p.broad && role !== 'info') rowFlags.push('broad_category');
    if (selfContradictory) rowFlags.push('self_contradictory_rule');

    const v2Reasons = [];
    if (role === 'info') v2Reasons.push('info');
    if (platformSlugs.length) v2Reasons.push('platform');
    if (mccInclude.length || mccExclude.length) v2Reasons.push('mcc');
    if (merchantSlugs.length > 1) v2Reasons.push('merchants');
    if (ur.blockInr !== null) v2Reasons.push('block_inr');
    // D16c: an earn rule with exceptions is v2-only; an exclusion with
    // exceptions stays v1 (v1 ignores them and excludes more, which is safe);
    // an exclusion bounded by max_txn_inr would exclude everything in v1.
    if ((exceptMerchants.length || exceptPlatforms.length) && role !== 'exclusion') v2Reasons.push('except_lists');
    if (role === 'exclusion' && maxTxn !== null) v2Reasons.push('exclusion_max_txn');
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
      excluded_category_slugs: ruleExcludedCategories,
      rule_role: role,
      merchant_slugs: merchantSlugs,
      platform_slugs: platformSlugs,
      mcc_include: mccInclude,
      mcc_exclude: mccExclude,
      except_merchant_slugs: exceptMerchants,
      except_platform_slugs: exceptPlatforms,
      block_inr: ur.blockInr,
      min_engine_version: minEngineVersion,
      // D18a: v1-only projection rows (v2 engines ignore them).
      max_engine_version: p.maxEngine === 1 ? 1 : null,
      display_note: displayNote,
      currency: isExclusion ? null : ur.currency,
      cap_refs: capRefs,
      info_reasons: uniq(rowInfo),
      flags: uniq([...flags, ...rowFlags]),
      v2_reasons: v2Reasons,
      narrow_on_merchant: p.narrowOnMerchant || null,
    };
  });

  // A v1-only row that the v1 feed couldn't show either is pointless.
  rows = rows.filter((r) => !(r.max_engine_version === 1 && (r.min_engine_version !== 1 || r.rule_role === 'info')));

  // A categorised exclusion must not vanish from v1 either (v1 would then
  // pay there). When every row is v2-only (a platform, MCCs only), add a
  // v1-only row excluding the whole category — broader, the safe side for
  // an exclusion (as D18b). Not for amount-bounded exclusions, where v1
  // would exclude the whole category at every amount.
  const exclusionRows = rows.filter((r) => r.rule_role === 'exclusion');
  // Only for exclusions whose own token is a category ("education" excluded
  // via third-party apps); a list-scoped one ("PayZapp: no accelerator on
  // rent") is not a category exclusion.
  if (tokenHasCategory && exclusionRows.length && !rows.some((r) => r.min_engine_version === 1 && r.rule_role === 'exclusion') && maxTxn === null) {
    const cats = uniq(token.parts.map((tp) => tp.categorySlug).filter(Boolean));
    for (const cat of cats) {
      rows.push({
        ...exclusionRows[0],
        part: cats.length > 1 ? `v1-${cat}` : 'v1',
        category_slug: cat,
        merchant_pattern: null,
        merchant_slugs: [],
        platform_slugs: [],
        mcc_include: [],
        mcc_exclude: [],
        except_merchant_slugs: [],
        except_platform_slugs: [],
        rail: null,
        min_engine_version: 1,
        max_engine_version: 1,
        flags: uniq([...exclusionRows[0].flags, 'exclusion_v1_projection']),
        v2_reasons: [],
      });
    }
  }

  // D18c: a reduced-rate rule must not vanish from v1 (v1 would then pay
  // the higher base). When every row is v2-only (MCCs, a platform, a block,
  // several merchants), add a v1-only row on the rule's category at the
  // reduced rate — broad is the conservative reading for a reduced rate.
  const earning = rows.filter((r) => ['earn', 'base'].includes(r.rule_role));
  // D19h: an MCC-only reduced rate projects onto the app categories its MCCs
  // belong to (YES Bank "select categories").
  const projectionCategories = preNarrowCategories.length
    ? preNarrowCategories
    : uniq(earning.flatMap((r) => r.mcc_include.map((m) => MCC_CATEGORY[m]).filter(Boolean))).sort();
  if (isReduced && earning.length && !rows.some((r) => r.min_engine_version === 1 && r.rule_role !== 'info') &&
      projectionCategories.length) {
    const model = earning[0];
    const v1Unit = model.block_inr ? 'points_per_100' : model.unit;
    const v1Rate = model.block_inr ? Math.round((Number(model.rate) * 100 / model.block_inr) * 10000) / 10000 : model.rate;
    for (const cat of projectionCategories) {
      rows.push({
        ...model,
        part: projectionCategories.length > 1 ? `v1-${cat}` : 'v1',
        category_slug: cat,
        merchant_pattern: model.merchant_slugs.length === 1 ? model.merchant_pattern : null,
        merchant_slugs: model.merchant_slugs.length === 1 ? model.merchant_slugs : [],
        platform_slugs: [],
        mcc_include: [],
        mcc_exclude: [],
        except_merchant_slugs: [],
        except_platform_slugs: [],
        unit: v1Unit,
        rate: v1Rate,
        block_inr: null,
        min_engine_version: 1,
        max_engine_version: 1,
        flags: uniq([...model.flags, 'reduced_rate_v1_projection']),
        v2_reasons: [],
        v1_projection_of: cat,
      });
    }
  }

  if (isReduced && rows.some((r) => ['earn', 'base'].includes(r.rule_role)) &&
      !rows.some((r) => r.min_engine_version === 1 && r.rule_role !== 'info')) {
    // No app category to project onto (an MCC list spanning several, or
    // FASTag): v1 can't show the reduced rate. Reported for review.
    for (const r of rows) r.flags = uniq([...r.flags, 'reduced_rate_no_v1_row']);
  }

  for (const row of rows) {
    for (const s of row.merchant_slugs) if (!ctx.index.merchants.has(s)) needsDirectory.push(s);
    for (const s of row.platform_slugs) if (!ctx.index.platforms.has(s)) needsDirectory.push(`platform:${s}`);
    for (const s of row.except_merchant_slugs) if (!ctx.index.merchants.has(s)) needsDirectory.push(s);
  }

  return {
    rows,
    infoReasons: uniq(info),
    flags: uniq(flags),
    unmappedTokens: uniq(unmappedTokens.filter(Boolean)),
    needsDirectory: uniq(needsDirectory),
  };
}

const REWARD_WORD = /\b(reward points?|points?|cash ?back|miles|neucoins|rewards?|rps?|value ?back|benefits?)\b/g;
const BONUS_QUALIFIER = /\b(accelerated|accelerator|bonus|additional|extra|incremental|special|milestone|\d+\s*x|\d+(\.\d+)?\s*%|\d+\s*percent)\b[^.,;]{0,25}$/;
const CORE_MENTION = /\b(core|base|standard|regular|normal|default)\b[^.]{0,25}\b(reward|points?|rps?|cash ?back|miles|rewards?|earn\w*)\b/;
const ZERO_EARN = /\b(earns?|earning|accrue\w*)\s+(0|zero|no|nothing)\b|\bzero\s+(reward|points?|cash ?back)\b|\bno\s+(\w+\s+){0,2}(reward|points?|cash ?back|miles|neucoins|rps?)\b/;

const EXCLUDING_CLAUSE = /\b(exclud\w*|not eligible|ineligible|not (qualify|count|accrue|earn|apply|available|applicable|receive)|do(es)? not|don't|doesn't|won't|no longer|zero|earn 0|not form part|discontinued|withdrawn|ceased|stopped|removed)\b/;

// D19a / D20c: classify an exclusion's text by its excluding clause(s) only
// ("... remains eligible for 5X" elsewhere in the sentence doesn't count).
//  'bonus_only' — every excluded benefit is accelerated / bonus / milestone;
//  'full'       — core/base or plain rewards excluded, or the excluding
//                 clause names no reward or qualifier at all.
function classifyExclusionText(raw) {
  const all = String(raw || '').toLowerCase().replace(/[_]+/g, ' ');
  if (!all.trim()) return null;
  const clauses = all.split(/[.;]|,\s*(?:while|whereas|but)\b|\bwhile\b|\bbut\b|\bwhereas\b/).map((c) => c.trim()).filter(Boolean);
  const excluding = clauses.filter((c) => EXCLUDING_CLAUSE.test(c));
  const t = (excluding.length ? excluding : clauses).join('. ');
  if (CORE_MENTION.test(t) || ZERO_EARN.test(t)) return 'full';
  let m;
  REWARD_WORD.lastIndex = 0;
  while ((m = REWARD_WORD.exec(t))) {
    const before = t.slice(Math.max(0, m.index - 40), m.index);
    // "milestone benefits", "accelerated 5% cashback": qualified.
    if (!BONUS_QUALIFIER.test(before) && !/\b(milestone|ticket|voucher|accelerated)\s*$/.test(before)) return 'full';
  }
  return /\b(accelerated|accelerator|bonus|additional|extra|incremental|milestone|ticket|\d+\s*x)\b/.test(t) ? 'bonus_only' : 'full';
}

function dedupeParts(parts) {
  const seen = new Map();
  const out = [];
  for (const p of parts) {
    const sig = JSON.stringify([p.categorySlug, p.merchantSlugs, p.platformSlugs, p.mccInclude, p.mccExclude, p.rail, p.maxEngine || null]);
    const prior = seen.get(sig);
    if (prior) {
      // Same row twice: it is narrow only if every source of it was narrow
      // ("recharges" + "utilities" on bills is all of bills).
      if (!p.broad) {
        prior.broad = false;
        prior.narrowTokens = [];
      } else if (prior.broad) {
        prior.narrowTokens = uniq([...(prior.narrowTokens || []), ...(p.narrowTokens || [])]);
      }
      continue;
    }
    const copy = { ...p };
    seen.set(sig, copy);
    out.push(copy);
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
function transformRewardRules(record, ctxIn) {
  const accPriorities = (record?.reward_rules || [])
    .filter((r) => String(r?.evaluation_type) === 'accelerator' && Number.isInteger(r?.priority))
    .map((r) => r.priority);
  const ctx = { ...ctxIn, minAcceleratorPriority: accPriorities.length ? Math.min(...accPriorities) : null };
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
  addMinimumAmountExclusion(rows, perSource);
  markBookingTypeSplits(rows, perSource);
  return { rows, perSource };
}

// D18i: a narrow token on a merchant rule adds no MCCs (an aggregator such
// as MakeMyTrip books flights and hotels under its own MCC). When the source
// gives that merchant different rates by booking type, we can't tell the
// bookings apart, so those rules are info (D14b) — unless the merchant is
// itself an airline or hotel.
function markBookingTypeSplits(rows, perSource) {
  const groups = new Map();
  for (const r of rows) {
    if (!r.narrow_on_merchant || !['earn', 'base'].includes(r.rule_role)) continue;
    const sig = JSON.stringify(r.merchant_slugs);
    if (!groups.has(sig)) groups.set(sig, []);
    groups.get(sig).push(r);
  }
  for (const [sig, group] of groups) {
    const merchants = JSON.parse(sig);
    if (merchants.every((m) => AIRLINE_OR_HOTEL.has(m))) continue;
    const tokens = new Set(group.map((r) => r.narrow_on_merchant));
    const rates = new Set(group.map((r) => `${r.unit}:${r.rate}:${r.block_inr}`));
    if (tokens.size < 2 || rates.size < 2) continue;
    for (const r of group) {
      r.rule_role = 'info';
      r.min_engine_version = 2;
      r.info_reasons = uniq([...r.info_reasons, 'booking_type_on_merchant']);
      r.flags = uniq([...r.flags, 'depends_on_txn_attribute']);
      const src = perSource.find((p) => p.source_local_id === r.source_local_id);
      if (src) {
        src.roles = uniq([...src.roles, 'info']);
        src.info_reasons = uniq([...src.info_reasons, 'booking_type_on_merchant']);
        src.flags = uniq([...src.flags, 'depends_on_txn_attribute']);
      }
    }
  }
}

// D16(d): "no rewards below ₹100" stated on the catch-all rule. When every
// earning rule on the card has at least that floor, the floor is card-wide:
// add an exclusion (all spend, max_txn_inr = floor) so the implicit base
// doesn't pay below it either.
function addMinimumAmountExclusion(rows, perSource) {
  const catchAll = rows.find((r) => r.rule_role === 'earn' && r.min_txn_inr !== null &&
    ['standard_accrual', 'fallback'].includes(r.evaluation_type) && !r.category_slug &&
    !r.merchant_slugs.length && !r.platform_slugs.length && !r.mcc_include.length && !r.rail);
  if (!catchAll) return;
  const floor = Number(catchAll.min_txn_inr);
  const earning = rows.filter((r) => ['earn', 'base'].includes(r.rule_role) && Number(r.rate) > 0);
  if (!earning.every((r) => r.min_txn_inr !== null && Number(r.min_txn_inr) >= floor)) {
    catchAll.flags.push('min_amount_not_card_wide');
    return;
  }
  rows.push({
    ...catchAll,
    key: `${catchAll.key}#min-amount`,
    part: null,
    evaluation_type: 'exclusion',
    unit: catchAll.unit,
    rate: 0,
    min_txn_inr: null,
    max_txn_inr: floor,
    priority: 0,
    excluded_category_slugs: [],
    rule_role: 'exclusion',
    except_merchant_slugs: [],
    except_platform_slugs: [],
    block_inr: null,
    min_engine_version: 2,
    display_note: `No rewards below ₹${floor}`,
    currency: null,
    cap_refs: [],
    info_reasons: [],
    flags: ['synthesized_min_amount_exclusion'],
    v2_reasons: ['exclusion_max_txn'],
  });
  const src = perSource.find((p) => p.source_local_id === catchAll.source_local_id);
  if (src) src.keys.push(`${catchAll.key}#min-amount`);
}

module.exports = {
  valuePerRupee,
  classifyExclusionText,
  distinctiveAlias,
  transformRewardRules,
  transformRule,
  unitAndRate,
};
