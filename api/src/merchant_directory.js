/**
 * Merchant and platform directory resolver (Card Rewards Phase 1, plan C5).
 *
 * Turns the raw merchant text a bank SMS, QR code or search box carries
 * ("BUNDL TECHNOLOGIES", "swiggy.instamart@icici") into a stable merchant
 * slug, so reward rules can target brands (`merchant_slugs`) instead of
 * substrings. Sub-brands roll up to their parents through `parent_slug`, so
 * an Instamart spend can satisfy a Swiggy rule.
 *
 * The algorithm is the contract both engines implement (the Dart twin lives
 * in packages/pandapay_domain); change it there and here together:
 *
 *   1. normalize(s): lowercase, every non-alphanumeric run -> one space, trim.
 *   2. A VPA match wins: the part before '@', normalized, starts with a
 *      normalized `vpa_prefix`. Longest prefix wins; ties -> slug sorting first.
 *   3. Otherwise an alias matches when the normalized alias appears in the
 *      normalized name on word boundaries. Longest alias wins; ties -> slug
 *      sorting first.
 *   4. Ancestors follow `parent_slug`, at most 5 levels, cycle-safe.
 *
 * Inactive merchants (`is_active === false`) are never resolved, but stay
 * reachable as ancestors: deactivating a parent doesn't orphan its children.
 *
 * Pure: no I/O. Input is the db/fixtures/merchant_directory.json shape or the
 * `merchants` / `platforms` arrays of the v2 catalogue feed (same fields).
 */

const MAX_ANCESTOR_DEPTH = 5;
const LOADED = Symbol.for('pandapay.merchantDirectory');

function normalize(value) {
  return String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

/** Candidate ordering shared by VPA and alias matching. */
function better(a, b) {
  if (!b) return true;
  if (a.match.length !== b.match.length) return a.match.length > b.match.length;
  return a.slug < b.slug;
}

/**
 * Builds the lookup structure once. Idempotent: passing an already-loaded
 * directory returns it unchanged, and `null` gives an empty directory.
 */
function loadDirectory(json) {
  if (json && json[LOADED]) return json;
  const merchants = new Map();
  const platforms = new Map();
  const aliasIndex = [];
  const vpaIndex = [];

  for (const m of (json && json.merchants) || []) {
    if (!m || typeof m.slug !== 'string' || m.slug === '') continue;
    merchants.set(m.slug, m);
    if (m.is_active === false) continue;
    for (const alias of m.aliases || []) {
      const match = normalize(alias);
      if (match) aliasIndex.push({ slug: m.slug, match });
    }
    for (const prefix of m.vpa_prefixes || []) {
      const match = normalize(prefix);
      if (match) vpaIndex.push({ slug: m.slug, match });
    }
  }
  for (const p of (json && json.platforms) || []) {
    if (p && typeof p.slug === 'string' && p.slug !== '') platforms.set(p.slug, p);
  }

  return { [LOADED]: true, merchants, platforms, aliasIndex, vpaIndex };
}

/**
 * Resolves raw merchant text and/or a VPA to `{ slug, via, match }`, where
 * `via` is 'vpa' or 'alias' and `match` the normalized prefix/alias that
 * matched — or `null` when nothing matches.
 */
function resolveMerchant(dir, name, vpa) {
  if (!dir) return null;
  const directory = loadDirectory(dir);

  if (vpa != null && String(vpa).trim() !== '') {
    const raw = String(vpa);
    const at = raw.indexOf('@');
    const user = normalize(at >= 0 ? raw.slice(0, at) : raw);
    if (user) {
      let best = null;
      for (const entry of directory.vpaIndex) {
        if (user.startsWith(entry.match) && better(entry, best)) best = entry;
      }
      if (best) return { slug: best.slug, via: 'vpa', match: best.match };
    }
  }

  const text = normalize(name);
  if (!text) return null;
  const padded = ` ${text} `;
  let best = null;
  for (const entry of directory.aliasIndex) {
    if (padded.includes(` ${entry.match} `) && better(entry, best)) best = entry;
  }
  return best ? { slug: best.slug, via: 'alias', match: best.match } : null;
}

/** Parent chain of `slug` (excluding itself), nearest first, ≤ 5 deep. */
function ancestors(dir, slug) {
  if (!dir || slug == null) return [];
  const directory = loadDirectory(dir);
  const out = [];
  const seen = new Set([slug]);
  let current = directory.merchants.get(slug);
  while (current && out.length < MAX_ANCESTOR_DEPTH) {
    const parent = current.parent_slug;
    if (parent == null || parent === '' || seen.has(parent)) break;
    seen.add(parent);
    out.push(parent);
    current = directory.merchants.get(parent);
  }
  return out;
}

module.exports = { normalize, loadDirectory, resolveMerchant, ancestors, MAX_ANCESTOR_DEPTH };
