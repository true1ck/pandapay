'use strict';

// Plan C7.10 / C7.11 — per-card model coverage and status, and the
// catalogue-wide coverage report (api/scripts/.staging/coverage-report.*).

const { uniq } = require('./util');

// Flags that describe a choice we made, not a gap. They're reported but
// don't hold a card at `partial` on their own.
const INFORMATIONAL_FLAGS = new Set([
  'synthesized_base_rule', 'token_replaced_by_conditions', 'merchant_prose_restates',
  'channel_type_restates_brand', 'cap_target_inferred_by_category', 'non_earning_cap_skipped',
  'fuel_waiver_cap_skipped', 'group_replaced_by_condition_list', 'synthesized_min_amount_exclusion',
  'narrow_token_to_mcc', 'exclusion_list_expanded',
]);

const DEFERRALS = new Set(['cap_depends_on_user', 'depends_on_user_attribute', 'depends_on_txn_attribute']);

function buildCoverage({
  rewardRules, perSource, capResult, milestoneResult, benefitResult, extraFlags,
  overridesApplied, overrideErrors, verified,
}) {
  const flags = [];
  for (const src of perSource) {
    for (const reason of src.info_reasons) flags.push({ code: 'info_rule', source_local_id: src.source_local_id, detail: reason });
    for (const f of src.flags) flags.push({ code: f, source_local_id: src.source_local_id, detail: null });
  }
  for (const r of rewardRules) {
    if (r.flags.includes('unrestricted_accelerator')) flags.push({ code: 'unrestricted_accelerator', source_local_id: r.source_local_id, detail: r.key });
  }
  flags.push(...capResult.flags, ...milestoneResult.flags, ...benefitResult.flags, ...extraFlags);
  for (const e of overrideErrors) flags.push({ code: 'override_not_applied', source_local_id: null, detail: `${e.path}: ${e.error}` });

  // De-duplicate identical flags (composite parts repeat their source's flags).
  const seen = new Set();
  const uniqueFlags = flags.filter((f) => {
    const sig = `${f.code}|${f.source_local_id}|${f.detail}`;
    if (seen.has(sig)) return false;
    seen.add(sig);
    return true;
  });

  const rulesTotal = perSource.length;
  const rulesInfo = perSource.filter((s) => s.roles.includes('info')).length;
  const rulesModelled = rulesTotal - rulesInfo;
  const capsTotal = capResult.total;
  const capsEnforced = capResult.caps.filter((c) => c.enforced).length;
  const hasEarn = rewardRules.some((r) => r.rule_role === 'earn');
  const unresolved = uniqueFlags.filter((f) => !INFORMATIONAL_FLAGS.has(f.code));
  const hasUnenforcedCap = capResult.caps.some((c) => !c.enforced) || capResult.skipped.some((s) => !['non_earning_cap_skipped', 'fuel_waiver_cap_skipped', 'tier_by_card_age'].includes(s.reason));

  // verified: WP7 listed it (its worked examples pass).
  // basic:    nothing beyond the base rate — and nothing we failed to model.
  // partial:  everything else: an info rule, an unenforced cap or an
  //           unresolved flag, or bonus rules not yet verified.
  // D17j: listed as verified AND nothing left but D13/D14 deferrals.
  const deferredRules = new Set(uniqueFlags.filter((f) => DEFERRALS.has(f.code)).map((f) => f.source_local_id));
  const blockingFlags = uniqueFlags.filter((f) => !INFORMATIONAL_FLAGS.has(f.code) && !DEFERRALS.has(f.code) &&
    !(f.code === 'info_rule' && deferredRules.has(f.source_local_id)));
  let modelStatus;
  if (verified && blockingFlags.length === 0) modelStatus = 'verified';
  else if (!hasEarn && rulesInfo === 0 && !hasUnenforcedCap) modelStatus = 'basic';
  else modelStatus = 'partial';

  const modelCoverage = {
    rules_total: rulesTotal,
    rules_modelled: rulesModelled,
    rules_info: rulesInfo,
    caps_total: capsTotal,
    caps_enforced: capsEnforced,
    flags: uniqueFlags,
    overrides_applied: overridesApplied,
  };
  return {
    model_status: modelStatus,
    model_coverage: modelCoverage,
    details: {
      perSource,
      hasUnenforcedCap,
      unresolvedFlagCount: unresolved.length,
      capsSkipped: capResult.skipped,
      milestoneAnchors: milestoneResult.anchors,
      unlockRules: benefitResult.unlockRules.length,
      verifiedListed: verified,
      verifiedBlockedBy: verified && blockingFlags.length ? uniq(blockingFlags.map((f) => f.code)) : [],
    },
  };
}

function inc(map, key, by = 1) {
  map[key] = (map[key] || 0) + by;
}

function sortedEntries(map, limit = Infinity) {
  return Object.entries(map).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, limit);
}

/**
 * Catalogue-wide report. `cards` = [{ sourceSlug, name, result (transform
 * output) | null, error?, skippedReason?, legacy: {acceleratorsTotal,
 * acceleratorsUnmapped} }].
 */
function aggregateReport(cards, meta = {}) {
  const report = {
    generated_at: meta.generatedAt || new Date().toISOString(),
    transform_version: meta.transformVersion || null,
    source: meta.source || null,
    cards_total: cards.length,
    cards_transformed: 0,
    cards_skipped: [],
    cards_failed: [],
    model_status: {},
    rules: { source_total: 0, by_role: {}, info: 0, v1_visible: 0, v2_only: 0 },
    accelerators: {
      total: 0,
      before_unmapped_token: 0,
      before_unmapped_cards: 0,
      after_modelled: 0,
      after_info: 0,
      after_dropped: 0,
      after_unrestricted: 0,
    },
    caps: { source_total: 0, written: 0, enforced: 0, by_kind: {}, skipped_by_reason: {}, orphan: 0, unenforced_period: 0, suspect_unit: 0, missing_value: 0, post_zero_bonus: 0 },
    milestones: { written: 0, anchors: {}, unsupported: 0 },
    unlocks: { rows: 0, benefits_with_unlocks: 0, unparsed: 0, lounge_benefits: 0, lounge_with_unlocks: 0 },
    unmapped_tokens: {},
    info_reasons: {},
    flags: {},
    needs_directory_entry: {},
    unrestricted_accelerators: [],
    orphan_caps: [],
    suspect_cap_units: [],
    overrides_applied: [],
    override_errors: [],
    per_card: [],
  };
  let beforeUnmappedCards = 0;
  for (const c of cards) {
    if (c.skippedReason) {
      report.cards_skipped.push({ slug: c.sourceSlug, reason: c.skippedReason });
      continue;
    }
    if (c.error) {
      report.cards_failed.push({ slug: c.sourceSlug, error: c.error });
      continue;
    }
    const t = c.result;
    report.cards_transformed += 1;
    inc(report.model_status, t.card.model_status);
    const cov = t.card.model_coverage;
    report.rules.source_total += cov.rules_total;
    report.rules.info += cov.rules_info;
    for (const r of t.rewardRules) {
      inc(report.rules.by_role, r.rule_role);
      if (r.min_engine_version === 1 && r.rule_role !== 'info') report.rules.v1_visible += 1;
      else report.rules.v2_only += 1;
    }
    if (c.legacy) {
      report.accelerators.before_unmapped_token += c.legacy.acceleratorsUnmapped;
      if (c.legacy.acceleratorsUnmapped > 0) beforeUnmappedCards += 1;
    }
    for (const src of t.coverage.perSource) {
      for (const tok of src.unmapped_tokens) inc(report.unmapped_tokens, tok);
      for (const reason of src.info_reasons) inc(report.info_reasons, reason);
      for (const n of src.needs_directory) inc(report.needs_directory_entry, n);
      if (String(src.evaluation_type).toLowerCase() === 'accelerator') {
        report.accelerators.total += 1;
        if (!src.keys.length) report.accelerators.after_dropped += 1;
        else if (src.roles.includes('info')) report.accelerators.after_info += 1;
        else report.accelerators.after_modelled += 1;
      }
    }
    for (const r of t.rewardRules) {
      if (r.flags.includes('unrestricted_accelerator')) {
        report.accelerators.after_unrestricted += 1;
        report.unrestricted_accelerators.push({ slug: c.sourceSlug, rule: r.key, rate: r.rate, unit: r.unit, note: r.display_note });
      }
    }
    for (const f of cov.flags) inc(report.flags, f.code);
    report.caps.source_total += cov.caps_total;
    report.caps.written += t.capRules.length;
    report.caps.enforced += cov.caps_enforced;
    for (const cap of t.capRules) {
      inc(report.caps.by_kind, cap.cap_kind);
      if (cap.flags.includes('orphan_cap')) {
        report.caps.orphan += 1;
        report.orphan_caps.push({ slug: c.sourceSlug, cap: cap.key });
      }
      if (cap.flags.includes('unenforced_period')) report.caps.unenforced_period += 1;
      if (cap.flags.includes('suspect_cap_unit')) {
        report.caps.suspect_unit += 1;
        report.suspect_cap_units.push({ slug: c.sourceSlug, cap: cap.key, cap_amount: cap.cap_amount });
      }
      if (cap.cap_kind.startsWith('bonus_') && cap.post_cap_rate === 0) report.caps.post_zero_bonus += 1;
    }
    for (const s of t.coverage.capsSkipped) {
      inc(report.caps.skipped_by_reason, s.reason);
      if (s.reason === 'missing_cap_value') report.caps.missing_value += 1;
    }
    report.milestones.written += t.milestones.length;
    for (const [k, v] of Object.entries(t.coverage.milestoneAnchors)) inc(report.milestones.anchors, k, v);
    report.milestones.unsupported += cov.flags.filter((f) => f.code === 'unsupported_milestone').length;
    report.unlocks.rows += t.unlockRules.length;
    const benefitsWithUnlocks = new Set(t.unlockRules.map((u) => u.benefit_key));
    report.unlocks.benefits_with_unlocks += benefitsWithUnlocks.size;
    report.unlocks.unparsed += cov.flags.filter((f) => f.code === 'unparsed_unlock').length;
    for (const b of t.benefits) {
      if (!String(b.kind).startsWith('lounge')) continue;
      report.unlocks.lounge_benefits += 1;
      if (benefitsWithUnlocks.has(b.key)) report.unlocks.lounge_with_unlocks += 1;
    }
    for (const o of cov.overrides_applied) report.overrides_applied.push({ slug: c.sourceSlug, ...o });
    for (const f of cov.flags.filter((x) => x.code === 'override_not_applied')) {
      report.override_errors.push({ slug: c.sourceSlug, detail: f.detail });
    }
    report.per_card.push({
      slug: c.sourceSlug,
      name: t.card.name,
      model_status: t.card.model_status,
      accrual_rounding: t.card.accrual_rounding,
      rules_total: cov.rules_total,
      rules_modelled: cov.rules_modelled,
      rules_info: cov.rules_info,
      caps_total: cov.caps_total,
      caps_enforced: cov.caps_enforced,
      unlock_rules: t.unlockRules.length,
      flags: uniq(cov.flags.map((f) => f.code)).sort(),
      verified_blocked_by: t.coverage.verifiedBlockedBy || [],
    });
  }
  report.accelerators.before_unmapped_cards = beforeUnmappedCards;
  // Arrays of [key, count], most frequent first (an object would reorder
  // numeric-looking keys).
  report.unmapped_tokens = sortedEntries(report.unmapped_tokens);
  report.info_reasons = sortedEntries(report.info_reasons);
  report.flags = sortedEntries(report.flags);
  report.needs_directory_entry = sortedEntries(report.needs_directory_entry);
  return report;
}

function table(rows, headers) {
  const lines = [`| ${headers.join(' | ')} |`, `|${headers.map(() => '---').join('|')}|`];
  for (const r of rows) lines.push(`| ${r.map((v) => String(v).replace(/\|/g, '\\|')).join(' | ')} |`);
  return lines.join('\n');
}

function renderMarkdown(report) {
  const a = report.accelerators;
  const out = [];
  out.push('# Catalogue v2 coverage report');
  out.push('');
  out.push(`Generated ${report.generated_at} · transform version ${report.transform_version} · source ${report.source || 'n/a'}`);
  out.push('');
  out.push('Legend: `info` = shown, never ranked, hidden from v1 (plan H2). `v2-only` = min_engine_version 2. ' +
    'Rounding: CardPipeline `nearest_integer` → `points_half_up` and `floor_to_nearest_paisa` → `none` (D7/D17k; C7.10\'s `round` is superseded). ' +
    '`verified` needs the card in verified_cards.json and no flags other than D13/D14 deferrals (D17j). ' +
    'Narrow category tokens on earning rules are MCC-only (D17a).');
  out.push('');
  out.push('## Headline');
  out.push('');
  out.push(table([
    ['Cards transformed', `${report.cards_transformed} / ${report.cards_total}`],
    ['Cards skipped (sanity check) / failed', `${report.cards_skipped.length} / ${report.cards_failed.length}`],
    ['Model status', Object.entries(report.model_status).map(([k, v]) => `${k} ${v}`).join(', ')],
    ['Accelerators (source)', a.total],
    ['Before: accelerators in unmapped category tokens (v1 loader drops them)', `${a.before_unmapped_token} on ${a.before_unmapped_cards} cards`],
    ['After: accelerators modelled / info / dropped', `${a.after_modelled} / ${a.after_info} / ${a.after_dropped}`],
    ['After: unrestricted accelerators (flagged for review)', a.after_unrestricted],
    ['Rules written by role', Object.entries(report.rules.by_role).map(([k, v]) => `${k} ${v}`).join(', ')],
    ['Rules visible in v1 / v2-only', `${report.rules.v1_visible} / ${report.rules.v2_only}`],
    ['Caps: source / written / enforced', `${report.caps.source_total} / ${report.caps.written} / ${report.caps.enforced}`],
    ['Caps: orphan / unenforced period / suspect unit / missing value', `${report.caps.orphan} / ${report.caps.unenforced_period} / ${report.caps.suspect_unit} / ${report.caps.missing_value}`],
    ['Caps by kind', Object.entries(report.caps.by_kind).map(([k, v]) => `${k} ${v}`).join(', ')],
    ['Caps skipped', Object.entries(report.caps.skipped_by_reason).map(([k, v]) => `${k} ${v}`).join(', ') || '0'],
    ['Milestones written / unsupported', `${report.milestones.written} / ${report.milestones.unsupported}`],
    ['Milestone period/anchor', Object.entries(report.milestones.anchors).map(([k, v]) => `${k} ${v}`).join(', ')],
    ['Unlock rules / benefits with unlocks / unparsed', `${report.unlocks.rows} / ${report.unlocks.benefits_with_unlocks} / ${report.unlocks.unparsed}`],
    ['Lounge benefits with structured unlocks', `${report.unlocks.lounge_with_unlocks} / ${report.unlocks.lounge_benefits}`],
    ['Overrides applied / not applied', `${report.overrides_applied.length} / ${report.override_errors.length}`],
  ], ['Metric', 'Value']));
  out.push('');
  out.push('## Unmapped category tokens (by frequency)');
  out.push('');
  out.push(table(report.unmapped_tokens.slice(0, 80), ['Token', 'Rules']));
  out.push('');
  out.push('## Why rules became `info`');
  out.push('');
  out.push(table(report.info_reasons.slice(0, 60), ['Reason', 'Rules']));
  out.push('');
  out.push('## Flags');
  out.push('');
  out.push(table(report.flags.slice(0, 80), ['Flag', 'Count']));
  out.push('');
  out.push('## Needs directory entry');
  out.push('');
  out.push(table(report.needs_directory_entry.slice(0, 80), ['Slug or text', 'Rules']));
  out.push('');
  out.push('## Unrestricted accelerators (review)');
  out.push('');
  out.push(table(report.unrestricted_accelerators.map((u) => [u.slug, u.rule, `${u.rate} ${u.unit}`, (u.note || '').slice(0, 90)]), ['Card', 'Rule', 'Rate', 'Note']));
  out.push('');
  out.push('## Suspect cap units');
  out.push('');
  out.push(table(report.suspect_cap_units.map((s) => [s.slug, s.cap, s.cap_amount]), ['Card', 'Cap', 'Amount']));
  out.push('');
  out.push('## Overrides applied');
  out.push('');
  out.push(table(report.overrides_applied.map((o) => [o.slug, o.path, o.op, (o.reason || '').slice(0, 80)]), ['Card', 'Path', 'Op', 'Reason']));
  if (report.override_errors.length) {
    out.push('');
    out.push('## Overrides NOT applied');
    out.push('');
    out.push(table(report.override_errors.map((o) => [o.slug, o.detail]), ['Card', 'Detail']));
  }
  out.push('');
  out.push('## Per card');
  out.push('');
  out.push(table(report.per_card.map((p) => [
    p.slug, p.model_status, p.accrual_rounding, `${p.rules_modelled}/${p.rules_total}`, p.rules_info,
    `${p.caps_enforced}/${p.caps_total}`, p.unlock_rules, p.flags.join(', '),
  ]), ['Card', 'Status', 'Rounding', 'Rules modelled', 'Info', 'Caps enforced', 'Unlocks', 'Flags']));
  out.push('');
  return out.join('\n');
}

module.exports = { INFORMATIONAL_FLAGS, aggregateReport, buildCoverage, renderMarkdown };
