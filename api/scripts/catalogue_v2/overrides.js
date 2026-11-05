'use strict';

// Plan C7.2 — reviewed research fixes applied to a CardPipeline record before
// the transform. Files live in api/scripts/catalogue_overrides/<source_slug>.json
// (see the README there).
//
// Path syntax: dotted keys, `[n]` array index, `[key=value]` element selector
// (`[id=x]` is the usual one). Examples:
//   cap_rules[id=swiggy_cashback_cap].metric
//   reward_rules[id=online_5pct].conditions.mcc_list
//   accrual_engine.rounding_mode
//   fee_waiver_and_milestones.spend_milestones[0].period
//
// A change whose path doesn't resolve is reported and NOT applied; the rest of
// the file still applies.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { deepClone } = require('./util');

const DEFAULT_OVERRIDES_DIR = path.resolve(__dirname, '../catalogue_overrides');

function valueHash(value) {
  return crypto.createHash('sha256').update(JSON.stringify(value === undefined ? null : value)).digest('hex').slice(0, 16);
}

function parsePath(p) {
  if (typeof p !== 'string' || !p.trim()) throw new Error('empty path');
  const tokens = [];
  const re = /([^.[\]]+)|\[(\d+)\]|\[([^=\]]+)=([^\]]*)\]|(\.)/g;
  let m;
  let last = 0;
  while ((m = re.exec(p))) {
    if (m.index !== last) throw new Error(`bad path near "${p.slice(last)}"`);
    last = re.lastIndex;
    if (m[1] !== undefined) tokens.push({ key: m[1] });
    else if (m[2] !== undefined) tokens.push({ index: Number(m[2]) });
    else if (m[3] !== undefined) tokens.push({ selectKey: m[3].trim(), selectValue: m[4].trim() });
  }
  if (last !== p.length) throw new Error(`bad path near "${p.slice(last)}"`);
  if (!tokens.length) throw new Error('empty path');
  return tokens;
}

function step(container, token) {
  if (container === null || typeof container !== 'object') return { ok: false };
  if ('key' in token) {
    return { ok: true, holder: container, slot: token.key, value: container[token.key] };
  }
  if (!Array.isArray(container)) return { ok: false };
  if ('index' in token) {
    if (token.index >= container.length) return { ok: false };
    return { ok: true, holder: container, slot: token.index, value: container[token.index] };
  }
  const idx = container.findIndex((el) => el && typeof el === 'object' && String(el[token.selectKey]) === token.selectValue);
  if (idx < 0) return { ok: false };
  return { ok: true, holder: container, slot: idx, value: container[idx] };
}

/**
 * Applies one change in place. op: "set" (default), "remove" (delete a key or
 * an array element), "append" (push onto an array).
 */
function applyChange(target, change) {
  const tokens = parsePath(change.path);
  let cur = target;
  for (let i = 0; i < tokens.length - 1; i++) {
    const r = step(cur, tokens[i]);
    if (!r.ok || r.value === undefined) return { ok: false, error: `path not found at segment ${i + 1}` };
    cur = r.value;
  }
  const lastTok = tokens[tokens.length - 1];
  const r = step(cur, lastTok);
  if (!r.ok) return { ok: false, error: 'final segment not found' };
  const op = change.op || 'set';
  if (op === 'set') {
    r.holder[r.slot] = deepClone(change.value);
    return { ok: true };
  }
  if (op === 'remove') {
    if (r.value === undefined) return { ok: false, error: 'nothing to remove' };
    if (Array.isArray(r.holder)) r.holder.splice(r.slot, 1);
    else delete r.holder[r.slot];
    return { ok: true };
  }
  if (op === 'append') {
    if (!Array.isArray(r.value)) return { ok: false, error: 'append target is not an array' };
    r.value.push(deepClone(change.value));
    return { ok: true };
  }
  return { ok: false, error: `unknown op ${op}` };
}

/** Returns { record (a copy), applied: [...], errors: [...] }. Never mutates the input. */
function applyOverrides(record, overrideFile) {
  const out = deepClone(record);
  const applied = [];
  const errors = [];
  if (!overrideFile) return { record: out, applied, errors };
  const changes = Array.isArray(overrideFile.changes) ? overrideFile.changes : [];
  changes.forEach((change, i) => {
    try {
      const r = applyChange(out, change);
      if (r.ok) {
        applied.push({
          path: change.path,
          op: change.op || 'set',
          // D17i: the value is part of what was applied, so a value-only
          // edit changes the card's override fingerprint and forces a rebuild.
          value_sha256: valueHash(change.value),
          reason: change.reason || null,
          source_url: change.source_url || null,
          checked_on: change.checked_on || null,
        });
      } else {
        errors.push({ index: i, path: change.path, error: r.error });
      }
    } catch (err) {
      errors.push({ index: i, path: change?.path ?? null, error: err.message });
    }
  });
  return { record: out, applied, errors };
}

function loadOverride(sourceSlug, dir = DEFAULT_OVERRIDES_DIR) {
  if (!sourceSlug || !/^[a-z0-9][a-z0-9-]*$/.test(sourceSlug)) return null;
  const file = path.join(dir, `${sourceSlug}.json`);
  if (!fs.existsSync(file)) return null;
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (parsed.source_slug && parsed.source_slug !== sourceSlug) {
    throw new Error(`${file}: source_slug "${parsed.source_slug}" does not match the file name`);
  }
  return parsed;
}

// verified_cards.json (owned by WP7). Accepts ["slug", ...],
// {"cards": [...]}, or {"verified": [{"source_slug": ...}]}.
function loadVerifiedSlugs(dir = DEFAULT_OVERRIDES_DIR) {
  const file = path.join(dir, 'verified_cards.json');
  if (!fs.existsSync(file)) return new Set();
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  const list = Array.isArray(parsed) ? parsed : parsed.cards || parsed.verified || [];
  return new Set(list.map((e) => (typeof e === 'string' ? e : e?.source_slug)).filter(Boolean));
}

module.exports = {
  DEFAULT_OVERRIDES_DIR,
  applyChange,
  applyOverrides,
  loadOverride,
  loadVerifiedSlugs,
  parsePath,
};
