'use strict';

// Cohorts, per-cohort manifests and bundle minting (WP-09). Pure functions plus
// `mintBundles`, which talks to a rules store (see rules_store.js).

const crypto = require('node:crypto');
const { validateBundle } = require('./contracts');
const { canonicalize, canonicalBundleBytes, sha256Hex, signBundle } = require('./signer');

const COHORTS = ['testers', 'pct5', 'pct25', 'all'];
const COHORT_RANK = { testers: 0, pct5: 1, pct25: 2, all: 3 };
// `all` is minted first so the first import yields bundle 1 for everyone.
const MINT_ORDER = ['all', 'pct25', 'pct5', 'testers'];
const PART_KEYS = ['minEngineVersion', 'taxonomyVersion', 'senders', 'ignoreRules', 'counterpartyPurposes', 'linkRules', 'categoryRules', 'merchantAliases'];
const BUNDLE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PARTS_KEY = '@parts';

// ---- cohorts ---------------------------------------------------------------

// sha256(profileId) mod 100, reading the 256-bit digest as a big-endian integer.
function bucketOf(profileId) {
  const digest = crypto.createHash('sha256').update(String(profileId).toLowerCase(), 'utf8').digest('hex');
  return Number(BigInt(`0x${digest}`) % 100n);
}

function cohortFor(profileId, isTester) {
  if (isTester) return 'testers';
  const b = bucketOf(profileId);
  if (b < 5) return 'pct5';
  if (b < 25) return 'pct25';
  return 'all';
}

// A version released to `releasedTo` is seen by this profile cohort when the
// profile's cohort is the same or narrower. testers see all four; `all` sees only `all`.
function visibleTo(profileCohort, releasedTo) {
  return COHORT_RANK[profileCohort] <= COHORT_RANK[releasedTo];
}

// ---- manifests -------------------------------------------------------------

// rules: [{ruleId, version, status}], cohortRows: [{ruleId, version, cohort, pausedAt}]
// Returns {ruleId: version} for what `cohort` sees: the newest unpaused visible version.
function ruleManifest(cohort, rules, cohortRows) {
  const releases = new Map();
  for (const c of cohortRows) {
    if (c.pausedAt) continue;
    if (!visibleTo(cohort, c.cohort)) continue;
    releases.set(`${c.ruleId}\u0000${c.version}`, true);
  }
  const out = {};
  for (const r of rules) {
    if (r.status === 'retired' || r.status === 'draft') continue;
    if (!releases.has(`${r.ruleId}\u0000${r.version}`)) continue;
    if (out[r.ruleId] === undefined || r.version > out[r.ruleId]) out[r.ruleId] = r.version;
  }
  return out;
}

function partsOf(source) {
  const parts = {};
  for (const k of PART_KEYS) if (source[k] !== undefined) parts[k] = source[k];
  return parts;
}

const partsHash = (parts) => sha256Hex(Buffer.from(canonicalize(parts), 'utf8'));

function buildManifest(cohort, rules, cohortRows, parts) {
  return { ...ruleManifest(cohort, rules, cohortRows), [PARTS_KEY]: partsHash(parts) };
}

// ---- assembling ------------------------------------------------------------

function assembleBundle({ manifest, rules, parts, bundleVersion, createdAt, expiresAt }) {
  const byKey = new Map(rules.map((r) => [`${r.ruleId}\u0000${r.version}`, r]));
  const ruleBodies = [];
  for (const id of Object.keys(manifest).filter((k) => k !== PARTS_KEY).sort()) {
    const row = byKey.get(`${id}\u0000${manifest[id]}`);
    if (!row) throw new Error(`manifest names missing rule ${id}@${manifest[id]}`);
    ruleBodies.push({ ...row.body, status: 'active' });
  }
  const bundle = {
    schema: 'pandapay.sms.rules/2',
    bundleVersion,
    createdAt,
    expiresAt,
    minEngineVersion: parts.minEngineVersion,
    taxonomyVersion: parts.taxonomyVersion,
    senders: parts.senders || [],
    ignoreRules: parts.ignoreRules || [],
    rules: ruleBodies,
    counterpartyPurposes: parts.counterpartyPurposes || [],
    linkRules: parts.linkRules || [],
    categoryRules: parts.categoryRules || [],
    merchantAliases: parts.merchantAliases || [],
    signature: null,
  };
  return bundle;
}

// Hash of a bundle's content independent of its version number and timestamps.
// This is what a golden report's `bundleSha256` must equal.
function contentSha256(bundle) {
  const copy = { ...bundle };
  for (const k of ['signature', 'bundleVersion', 'createdAt', 'expiresAt']) delete copy[k];
  return sha256Hex(Buffer.from(canonicalize(copy), 'utf8'));
}

const isoSeconds = (d) => new Date(Math.floor(d.getTime() / 1000) * 1000).toISOString().replace('.000Z', 'Z');

function assertValidBundle(bundle) {
  const check = validateBundle({ ...bundle, signature: bundle.signature || { alg: 'Ed25519', keyId: 'placeholder', value: 'AAAA' } });
  if (!check.ok) {
    const err = new Error('bundle_invalid');
    err.code = 'bundle_invalid';
    err.details = check.errors;
    throw err;
  }
}

// Candidate for a prospective manifest, without a version (used for the publish gate).
function candidateBundle({ manifest, rules, parts, now }) {
  const createdAt = isoSeconds(now);
  return assembleBundle({ manifest, rules, parts, bundleVersion: 0, createdAt, expiresAt: isoSeconds(new Date(now.getTime() + BUNDLE_TTL_MS)) });
}

// ---- minting ---------------------------------------------------------------

// Inside a store transaction: recompute the manifest of each cohort and mint a
// signed bundle for every cohort whose manifest changed. Returns minted rows.
// opts: {signer, now, publishedBy, goldenReport, supersededStatus}
async function mintBundles(s, opts) {
  const { signer, now = new Date(), publishedBy = null, goldenReport = null, supersededStatus = 'superseded' } = opts;
  if (!signer) {
    const err = new Error('signing_unavailable');
    err.code = 'signing_unavailable';
    throw err;
  }
  const rules = await s.allRules();
  const cohortRows = await s.allCohorts();
  const parts = await s.getParts();
  const minted = [];
  let nextVersion = (await s.maxBundleVersion()) + 1;
  for (const cohort of MINT_ORDER) {
    const manifest = buildManifest(cohort, rules, cohortRows, parts);
    const current = await s.latestBundle(cohort);
    if (current && canonicalize(current.manifest) === canonicalize(manifest)) continue;
    if (parts.minEngineVersion === undefined) {
      const err = new Error('bundle_parts_missing');
      err.code = 'bundle_parts_missing';
      throw err;
    }
    const bundle = assembleBundle({
      manifest, rules, parts, bundleVersion: nextVersion,
      createdAt: isoSeconds(now), expiresAt: isoSeconds(new Date(now.getTime() + BUNDLE_TTL_MS)),
    });
    assertValidBundle(bundle);
    const signed = signBundle(bundle, signer);
    const row = {
      bundleVersion: nextVersion, manifest, sha256: contentSha256(bundle), signature: signed.signature.value,
      keyId: signer.keyId, cohort, goldenReport: opts.goldenReportsByCohort?.[cohort] || goldenReport, status: 'active', publishedBy, createdAt: bundle.createdAt, body: bundle,
      servedBody: signed, // pre-signed copy the public API serves as is (LO-09)
    };
    if (current) await s.setBundleStatus(current.bundleVersion, supersededStatus);
    await s.insertBundle(row);
    minted.push(row);
    nextVersion += 1;
  }
  return minted;
}

// Re-sign a stored bundle with a fresh expiry (expiry is rounded to the hour so repeated
// fetches share an ETag). Only maintenance jobs call this: the public API holds no key and
// serves `servedBody` as stored (LO-09).
function resignBundle(row, signer, now = new Date()) {
  const hour = new Date(Math.floor(now.getTime() / 3600000) * 3600000);
  const bundle = { ...row.body, expiresAt: isoSeconds(new Date(hour.getTime() + BUNDLE_TTL_MS)) };
  return signBundle(bundle, signer);
}

const REFRESH_BEFORE_MS = 72 * 3600 * 1000;

// Hourly job, inside a store transaction: re-sign the active bundle of each cohort when its
// served copy is missing, signed by another key id, or within `refreshBeforeMs` of expiry.
// The stored content must still match the hash recorded at mint time.
async function refreshServedBundles(s, { signer, now = new Date(), refreshBeforeMs = REFRESH_BEFORE_MS }) {
  if (!signer) {
    const err = new Error('signing_unavailable');
    err.code = 'signing_unavailable';
    throw err;
  }
  const refreshed = [];
  for (const cohort of MINT_ORDER) {
    const row = await s.latestBundle(cohort);
    if (!row) continue;
    const served = row.servedBody;
    const due = !served || !served.signature || served.signature.keyId !== signer.keyId ||
      served.bundleVersion !== row.bundleVersion || !(Date.parse(served.expiresAt) - now.getTime() > refreshBeforeMs);
    if (!due) continue;
    if (contentSha256(row.body) !== row.sha256) {
      const err = new Error('bundle_corrupt');
      err.code = 'bundle_corrupt';
      throw err;
    }
    const signed = resignBundle(row, signer, now);
    assertValidBundle(signed);
    await s.setServedBundle(row.bundleVersion, signed);
    refreshed.push({ bundleVersion: row.bundleVersion, cohort, expiresAt: signed.expiresAt });
  }
  return refreshed;
}

module.exports = {
  COHORTS, COHORT_RANK, PART_KEYS, PARTS_KEY, BUNDLE_TTL_MS,
  bucketOf, cohortFor, visibleTo, ruleManifest, partsOf, partsHash, buildManifest,
  assembleBundle, candidateBundle, contentSha256, assertValidBundle, mintBundles, resignBundle, refreshServedBundles, REFRESH_BEFORE_MS, isoSeconds,
  canonicalBundleBytes,
};
