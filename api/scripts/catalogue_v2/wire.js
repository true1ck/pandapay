'use strict';

// Transform output -> the v2 feed's card shape (plan C2), with ids made from
// local keys instead of database UUIDs (`<slug>:rule:<key>`). Used for the
// --transform-only preview feed (which audit_catalogue.js can read) and by
// WP7 for the catalogue_v2_cards snapshots.

function ids(slug) {
  return {
    rule: (key) => (key ? `${slug}:rule:${key}` : null),
    cap: (key) => (key ? `${slug}:cap:${key}` : null),
    benefit: (key) => (key ? `${slug}:benefit:${key}` : null),
    category: (catSlug) => (catSlug ? `cat-${catSlug}` : null),
  };
}

function toV2WireCard(t, opts = {}) {
  const slug = t.card.slug || t.card.source_slug;
  const id = ids(slug);
  const cats = (list) => (list || []).map(id.category);
  return {
    id: `${slug}:card`,
    slug,
    name: t.card.name,
    network: opts.network ?? null,
    issuer_slug: opts.issuerSlug ?? null,
    base_reward_unit: t.card.base_reward_unit,
    base_reward_rate: t.card.base_reward_rate,
    point_value_inr: t.card.point_value_inr,
    excluded_categories: cats(t.card.excluded_category_slugs),
    accrual_block_inr: t.card.accrual_block_inr,
    accrual_rounding: t.card.accrual_rounding,
    cashback_rounding: t.card.cashback_rounding,
    points_expiry_months: t.card.points_expiry_months,
    model_status: t.card.model_status,
    model_coverage: t.card.model_coverage,
    reward_rules: t.rewardRules.map((r) => ({
      id: id.rule(r.key),
      category_id: id.category(r.category_slug),
      category_slug: r.category_slug,
      merchant_pattern: r.merchant_pattern,
      rail: r.rail,
      unit: r.unit,
      rate: r.rate,
      min_txn_inr: r.min_txn_inr,
      max_txn_inr: r.max_txn_inr,
      priority: r.priority,
      conditions: { source_local_id: r.source_local_id, part: r.part, info_reasons: r.info_reasons, flags: r.flags },
      notes: null,
      effective_from: r.effective_from,
      effective_to: r.effective_to,
      excluded_categories: cats(r.excluded_category_slugs),
      rule_role: r.rule_role,
      merchant_slugs: r.merchant_slugs,
      platform_slugs: r.platform_slugs,
      mcc_include: r.mcc_include,
      mcc_exclude: r.mcc_exclude,
      block_inr: r.block_inr,
      min_engine_version: r.min_engine_version,
      source_local_id: r.source_local_id,
      display_note: r.display_note,
    })),
    cap_rules: t.capRules.map((c) => ({
      id: id.cap(c.key),
      reward_rule_id: id.rule(c.reward_rule_key),
      category_id: id.category(c.category_slug),
      category_slug: c.category_slug,
      benefit_kind: null,
      label: c.label,
      measure: c.measure,
      period: c.period,
      cap_value: c.cap_value,
      post_cap_unit: c.post_cap_unit,
      post_cap_rate: c.post_cap_rate,
      resets_on_day: c.resets_on_day,
      cap_kind: c.cap_kind,
      cap_amount: c.cap_amount,
      scope: c.scope,
      targets: c.target_keys.map(id.rule),
      parent_cap_id: id.cap(c.parent_key),
      post_cap_behavior: c.post_cap_behavior,
      anchor: c.anchor,
      min_engine_version: c.min_engine_version,
      source_local_id: c.source_local_id,
    })),
    milestone_rules: t.milestones.map((m) => ({
      id: `${slug}:milestone:${m.key}`,
      label: m.label,
      period: m.period,
      threshold_spend_inr: m.threshold_spend_inr,
      reward_description: m.reward_description,
      reward_value_inr: m.reward_value_inr,
      is_repeatable: m.is_repeatable,
      max_repeats: null,
      anchor: m.anchor,
      reward_points: m.reward_points,
      reward_kind: m.reward_kind,
      excluded_category_ids: cats(m.excluded_category_slugs),
      window_days: m.window_days,
      source_local_id: m.source_local_id,
    })),
    fee_waiver_rules: t.feeWaivers.map((w, i) => ({ id: `${slug}:waiver:${i + 1}`, ...w, excluded_categories: cats(w.excluded_category_slugs) })),
    benefits: t.benefits.map((b) => ({ id: id.benefit(b.key), ...b })),
    unlock_rules: t.unlockRules.map((u) => ({
      id: `${slug}:unlock:${u.key}`,
      card_benefit_id: id.benefit(u.benefit_key),
      kind: u.kind,
      label: u.label,
      spend_threshold_inr: u.spend_threshold_inr,
      spend_window: u.spend_window,
      window_days: u.window_days,
      unlocks_quota: u.unlocks_quota,
      unlocks_period: u.unlocks_period,
      tier_label: u.tier_label,
      excluded_category_ids: cats(u.excluded_category_slugs),
      notes: u.notes,
      source_local_id: u.source_local_id,
    })),
    redemption_options: t.redemptionOptions,
  };
}

module.exports = { toV2WireCard };
