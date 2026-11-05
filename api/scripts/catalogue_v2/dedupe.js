'use strict';

// Rows the database would reject as duplicates. card_benefits, cap_rules and
// milestone_rules carry unique "semantic identity" indexes (NULLS NOT
// DISTINCT), and for benefits and caps a second one on the label normalised
// by whitespace and case (uq_*_label_identity_v1). Two transform rows with the
// same identity would abort the whole card's import, so the first is kept and
// each later one is dropped and reported. source_local_id is not part of any
// identity. reward_rules can't collide: their identity holds the source id
// and part (in `conditions`). benefit_unlock_rules have no identity index.

const { uniq } = require('./util');

function canon(v) {
  if (v === undefined || v === null) return null;
  if (typeof v === 'number') return Number(v);
  if (Array.isArray(v)) return v.map(canon);
  if (typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) if (v[k] !== undefined) out[k] = canon(v[k]);
    return out;
  }
  return v;
}

// Postgres: translate(btrim(regexp_replace(label, '[\t-\r ]+', ' ', 'g')), A-Z, a-z)
function normalizeLabel(label) {
  if (label === null || label === undefined) return null;
  return String(label).replace(/[\t-\r ]+/g, ' ').replace(/^ +| +$/g, '').replace(/[A-Z]/g, (c) => c.toLowerCase());
}

const idKey = (parts) => JSON.stringify(canon(parts));
const sortedSlugs = (xs) => [...(xs || [])].sort();

function benefitIdentity(b) {
  return idKey([b.kind, normalizeLabel(b.label), b.description, b.quota_count, b.quota_period,
    b.network_program, b.value_estimate_inr, b.conditions]);
}

function milestoneIdentity(m) {
  return idKey([m.label, m.period, m.threshold_spend_inr, m.reward_description, m.reward_value_inr,
    m.is_repeatable, null, m.anchor, m.reward_points, m.reward_kind, m.window_days,
    sortedSlugs(m.excluded_category_slugs)]);
}

function capIdentity(c) {
  return idKey([c.reward_rule_key || null, c.category_slug, null, normalizeLabel(c.label), c.measure, c.period,
    c.cap_value, c.post_cap_unit, c.post_cap_rate, c.resets_on_day, c.cap_kind, c.cap_amount, c.scope,
    c.parent_key || null, c.post_cap_behavior, c.anchor, c.min_engine_version]);
}

// Benefits: unlock rules of a dropped benefit move to the kept one.
function dedupeBenefits(benefits, unlockRules) {
  const seen = new Map();
  const kept = [];
  const dropped = [];
  const remap = new Map();
  for (const b of benefits) {
    const id = benefitIdentity(b);
    const first = seen.get(id);
    if (first) {
      dropped.push({ code: 'duplicate_benefit_dropped', source_local_id: b.source_local_id ?? null, detail: `${b.key} duplicates ${first.key}` });
      remap.set(b.key, first.key);
      continue;
    }
    seen.set(id, b);
    kept.push(b);
  }
  for (const u of unlockRules) if (remap.has(u.benefit_key)) u.benefit_key = remap.get(u.benefit_key);
  return { benefits: kept, flags: dropped };
}

function dedupeMilestones(milestones) {
  const seen = new Map();
  const kept = [];
  const dropped = [];
  for (const m of milestones) {
    const id = milestoneIdentity(m);
    const first = seen.get(id);
    if (first) {
      dropped.push({ code: 'duplicate_milestone_dropped', source_local_id: m.source_local_id ?? null, detail: `${m.key || m.label} duplicates ${first.key || first.label}` });
      continue;
    }
    seen.set(id, m);
    kept.push(m);
  }
  return { milestones: kept, flags: dropped };
}

// Caps arrive parents-first. A dropped cap's targets join the kept cap (one
// shared pool: never more reward than two pools), and its children are
// re-parented to the kept cap before their own identity is taken.
function dedupeCaps(caps, capTargets) {
  const seen = new Map();
  const kept = [];
  const dropped = [];
  const remap = new Map();
  for (const c of caps) {
    if (c.parent_key && remap.has(c.parent_key)) c.parent_key = remap.get(c.parent_key);
    const id = capIdentity(c);
    const first = seen.get(id);
    if (first) {
      dropped.push({ code: 'duplicate_cap_dropped', source_local_id: c.source_local_id ?? null, detail: `${c.key} duplicates ${first.key}` });
      remap.set(c.key, first.key);
      first.target_keys = uniq([...(first.target_keys || []), ...(c.target_keys || [])]);
      continue;
    }
    seen.set(id, c);
    kept.push(c);
  }
  if (!remap.size) return { caps: kept, capTargets, flags: dropped };
  const targetSeen = new Set();
  const targets = [];
  for (const t of capTargets) {
    const capKey = remap.get(t.cap_key) || t.cap_key;
    const k = `${capKey}\u0000${t.rule_key}`;
    if (targetSeen.has(k)) continue;
    targetSeen.add(k);
    targets.push({ ...t, cap_key: capKey });
  }
  return { caps: kept, capTargets: targets, flags: dropped };
}

module.exports = { dedupeBenefits, dedupeCaps, dedupeMilestones, normalizeLabel };
