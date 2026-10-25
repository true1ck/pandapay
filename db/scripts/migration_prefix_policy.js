'use strict';

const fs = require('node:fs');
const path = require('node:path');

const FORMAT = 'pandapay-migration-prefix-exceptions-v1';
const NAMESPACES = ['auth_migrations', 'product_migrations', 'product_seeds'];
const EMPTY_MANIFEST = {
  format: FORMAT,
  namespaces: {
    auth_migrations: {},
    product_migrations: {},
    product_seeds: {},
  },
};
const DEFAULT_MANIFEST_PATH = path.resolve(__dirname, '..', 'migration-prefix-exceptions.json');

function parseManifest(manifestPath) {
  if (manifestPath == null) return EMPTY_MANIFEST;
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (_) {
    throw new Error('Migration prefix exception manifest is unreadable or invalid JSON');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) ||
      parsed.format !== FORMAT ||
      Object.keys(parsed).sort().join(',') !== 'format,namespaces' ||
      !parsed.namespaces || typeof parsed.namespaces !== 'object' || Array.isArray(parsed.namespaces) ||
      Object.keys(parsed.namespaces).sort().join(',') !== NAMESPACES.slice().sort().join(',')) {
    throw new Error('Migration prefix exception manifest has an unsupported structure');
  }

  for (const namespace of NAMESPACES) {
    const groups = parsed.namespaces[namespace];
    if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
      throw new Error('Migration prefix exception manifest has an invalid namespace');
    }
    const versions = new Set();
    for (const [prefix, names] of Object.entries(groups)) {
      if (!/^\d+$/.test(prefix) || !Array.isArray(names) || names.length < 2 ||
          names.some(name => typeof name !== 'string') ||
          names.some(name => !new RegExp('^' + prefix + '_[A-Za-z0-9_-]+\\.sql$').test(name)) ||
          names.some((name, index) => index > 0 && names[index - 1] >= name)) {
        throw new Error('Migration prefix exception manifest has an invalid collision group');
      }
      const version = BigInt(prefix).toString();
      if (versions.has(version)) throw new Error('Migration prefix exception manifest repeats a numeric version');
      versions.add(version);
    }
  }
  return parsed;
}

function validateMigrationPrefixPolicy(inventories, { manifestPath = DEFAULT_MANIFEST_PATH } = {}) {
  const manifest = parseManifest(manifestPath);
  if (!inventories || typeof inventories !== 'object' || Array.isArray(inventories)) {
    throw new Error('Migration prefix inventory is invalid');
  }
  for (const namespace of Object.keys(inventories)) {
    if (!NAMESPACES.includes(namespace) || !Array.isArray(inventories[namespace])) {
      throw new Error('Migration prefix inventory has an unknown namespace');
    }
    const names = inventories[namespace];
    const seen = new Set();
    const byPrefix = new Map();
    for (const name of names) {
      if (typeof name !== 'string' || !/^\d+_[A-Za-z0-9_-]+\.sql$/.test(name) || seen.has(name)) {
        throw new Error('Migration prefix inventory contains an invalid or duplicate filename');
      }
      seen.add(name);
      const prefix = BigInt(name.slice(0, name.indexOf('_'))).toString();
      if (!byPrefix.has(prefix)) byPrefix.set(prefix, []);
      byPrefix.get(prefix).push(name);
    }

    const expected = Object.fromEntries(Object.entries(manifest.namespaces[namespace])
      .map(([prefix, names]) => [BigInt(prefix).toString(), names]));
    const expectedPrefixes = Object.keys(expected);
    for (const [prefix, actualNames] of byPrefix) {
      if (actualNames.length < 2) continue;
      actualNames.sort();
      const allowedNames = expected[prefix];
      if (!allowedNames || JSON.stringify(actualNames) !== JSON.stringify(allowedNames)) {
        throw new Error('Unreviewed migration version-prefix collision in ' + namespace);
      }
    }
    for (const prefix of expectedPrefixes) {
      const actualNames = (byPrefix.get(prefix) || []).slice().sort();
      if (JSON.stringify(actualNames) !== JSON.stringify(expected[prefix])) {
        throw new Error('Reviewed migration version-prefix exception no longer matches ' + namespace);
      }
    }
  }
  return true;
}

module.exports = {
  DEFAULT_MANIFEST_PATH,
  validateMigrationPrefixPolicy,
};
