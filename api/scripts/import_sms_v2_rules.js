#!/usr/bin/env node
'use strict';
/**
 * Imports the sms_rules_cli `build` output as bundle 1 (idempotent).
 *
 *   node api/scripts/import_sms_v2_rules.js --input bundle.json --admin-id <admin_users.id>
 *
 * Every rule becomes version 1 on cohort `all`, the non-rule parts (senders,
 * link rules, ...) are stored, and signed bundles are minted. Needs
 * SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID. Re-running with the same input
 * changes nothing. Point DATABASE_URL at a local database to test.
 */
const fs = require('node:fs');

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function main() {
  const input = arg('input');
  const adminId = arg('admin-id');
  if (!input || !adminId) {
    console.error('usage: import_sms_v2_rules.js --input <bundle.json> --admin-id <uuid>');
    process.exit(2);
  }
  const { signerFromEnv } = require('../src/sms_v2/signer');
  const signer = signerFromEnv();
  if (!signer) { console.error('SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID are required'); process.exit(2); }
  const { withUserClient, pool } = require('../src/db');
  const { createPgStore } = require('../src/sms_v2/rules_store');
  const { importBundle } = require('../src/sms_v2/rules_admin_route');
  const bundle = JSON.parse(fs.readFileSync(input, 'utf8'));
  const store = createPgStore({ withUserClient });
  const result = await store.tx(adminId, (s) => importBundle(s, bundle, { signer, adminId }));
  console.log(JSON.stringify({ rulesInserted: result.rulesInserted, bundlesMinted: result.minted.map((m) => ({ bundleVersion: m.bundleVersion, cohort: m.cohort })) }));
  await pool.end();
}

main().catch((err) => { console.error('import failed:', err && (err.code || err.message)); process.exit(1); });
