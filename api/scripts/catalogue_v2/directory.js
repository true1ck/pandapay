'use strict';

// Merchant/platform directory access for the loader (plan C5, change D6).
//
// The loader resolves free text from research records ("Swiggy Liquor",
// "PhonePe app", "HDFC SmartBuy") to directory slugs. Resolution here is
// deliberately STRICTER than the engines' runtime alias matching: the whole
// phrase, minus generic words such as "app" or "website", must equal an alias.
// A containment match would turn "Swiggy Liquor" (an exclusion) into "all of
// Swiggy" — exactly the widening plan H2 forbids.

const fs = require('fs');
const path = require('path');
const { normalizeText, uniq } = require('./util');

const DEFAULT_DIRECTORY_PATH = path.resolve(__dirname, '../../../db/fixtures/merchant_directory.json');

const GENERIC_WORDS = new Set([
  'app', 'apps', 'application', 'mobile', 'website', 'web', 'site', 'online',
  'platform', 'portal', 'official', 'com', 'co', 'in', 'india', 'store', 'stores',
  'outlet', 'outlets', 'the', 'and', 'or', 'via', 'through', 'using', 'on', 'at',
  'brand', 'transactions', 'transaction', 'payments', 'payment', 'spends', 'spend',
  'eligible', 'participating', 'authorised', 'authorized', 'petrol', 'pump', 'pumps',
  'station', 'stations', 'fuel', 'pos', 'android', 'ios', 'websites',
]);

function loadDirectory(file = DEFAULT_DIRECTORY_PATH) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function addKey(map, key, slug) {
  if (!key) return;
  if (!map.has(key)) map.set(key, new Set());
  map.get(key).add(slug);
}

function buildDirectoryIndex(directory) {
  const merchants = new Map();
  const platforms = new Map();
  const merchantKeys = new Map();
  const platformKeys = new Map();
  const groups = new Map();

  for (const m of directory?.merchants || []) {
    if (!m || typeof m.slug !== 'string') continue;
    if (m.is_active === false) continue;
    merchants.set(m.slug, m);
    addKey(merchantKeys, normalizeText(m.slug.replace(/_/g, ' ')), m.slug);
    addKey(merchantKeys, normalizeText(m.name), m.slug);
    for (const alias of m.aliases || []) addKey(merchantKeys, normalizeText(alias), m.slug);
    if (typeof m.group === 'string' && m.group.trim()) {
      const g = m.group.trim();
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(m.slug);
    }
  }
  for (const p of directory?.platforms || []) {
    if (!p || typeof p.slug !== 'string') continue;
    if (p.is_active === false) continue;
    platforms.set(p.slug, p);
    addKey(platformKeys, normalizeText(p.slug.replace(/_/g, ' ')), p.slug);
    addKey(platformKeys, normalizeText(p.name), p.slug);
    for (const alias of p.aliases || []) addKey(platformKeys, normalizeText(alias), p.slug);
  }
  return { merchants, platforms, merchantKeys, platformKeys, groups };
}

// Every intermediate form while trimming generic words one at a time from the
// ends, so "air india website" yields "air india" before "air".
function stripSteps(normalized) {
  const words = normalized.split(' ').filter(Boolean);
  const steps = [];
  while (words.length && GENERIC_WORDS.has(words[words.length - 1])) {
    words.pop();
    steps.push(words.join(' '));
  }
  while (words.length && GENERIC_WORDS.has(words[0])) {
    words.shift();
    steps.push(words.join(' '));
  }
  return steps;
}

function stripGeneric(normalized) {
  const steps = stripSteps(normalized);
  return steps.length ? steps[steps.length - 1] : normalized;
}

// Candidate phrasings of one piece of text, most literal first.
function candidates(text) {
  const n = normalizeText(text);
  if (!n) return [];
  const out = [n, ...stripSteps(n)];
  // "Scan & Pay via Kiwi App" -> "kiwi"
  const via = n.match(/\b(?:via|through|using|on|in|at)\s+(.+)$/);
  if (via) out.push(via[1], ...stripSteps(via[1]));
  return uniq(out.filter(Boolean));
}

function lookup(keys, text) {
  for (const candidate of candidates(text)) {
    const hit = keys.get(candidate);
    if (hit && hit.size === 1) return [...hit][0];
  }
  return null;
}

function resolveMerchantText(text, index) {
  if (!index || typeof text !== 'string') return null;
  return lookup(index.merchantKeys, text);
}

function resolvePlatformText(text, index) {
  if (!index || typeof text !== 'string') return null;
  const exact = lookup(index.platformKeys, text);
  if (exact) return exact;
  // A portal named inside a longer phrase ("BOBCARD SmartDeal logged-in
  // mobile app or portal"). Platforms only: a platform restriction narrows a
  // rule; a merchant found inside prose would not be safe the same way.
  const n = ` ${normalizeText(text)} `;
  let best = null;
  for (const [key, slugs] of index.platformKeys) {
    if (key.length < 5 || slugs.size !== 1) continue;
    if (!n.includes(` ${key} `)) continue;
    if (!best || key.length > best.key.length) best = { key, slug: [...slugs][0] };
  }
  return best ? best.slug : null;
}

// Splits a source string naming several merchants ("Amazon, Flipkart and
// Myntra") into pieces. Arrays are returned as-is.
function splitNames(value) {
  if (Array.isArray(value)) return value.filter((v) => typeof v === 'string' && v.trim());
  if (typeof value !== 'string') return [];
  return value
    .split(/\s*(?:,|;|\/|\||&|\band\b|\bor\b)\s*/i)
    .map((s) => s.trim())
    .filter(Boolean);
}

function groupMembers(group, index) {
  return index?.groups.get(group) ? [...index.groups.get(group)] : [];
}

module.exports = {
  DEFAULT_DIRECTORY_PATH,
  buildDirectoryIndex,
  groupMembers,
  loadDirectory,
  resolveMerchantText,
  resolvePlatformText,
  splitNames,
  stripGeneric,
};
