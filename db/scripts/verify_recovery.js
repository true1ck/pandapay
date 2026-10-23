#!/usr/bin/env node
'use strict';

// Recovery-host application check: supply the same retained phone/HMAC keys
// through its secret channel. This never migrates, rewrites or deletes data.
const { createRequire } = require('node:module');
const path = require('node:path');
const authDir = process.env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
const authRequire = createRequire(path.join(authDir, 'package.json'));

async function main() {
  const { Pool } = authRequire('pg');
  const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
  const { validateMigrationConfiguration, verifyPhoneLookupHashes } = require(path.join(authDir, 'scripts/migrate'));
  validateMigrationConfiguration();
  const urls = [process.env.RESTORE_PRODUCT_TARGET_URL, process.env.RESTORE_AUTH_TARGET_URL];
  if (urls.some(url => !url)) throw new Error('Both explicit recovery target URLs are required');
  const [product, auth] = urls.map(url => new Pool({ ...resolveDatabaseTls(url), max: 1, connectionTimeoutMillis: 10000 }));
  try {
    await verifyPhoneLookupHashes(auth, { batchSize: 100 });
    let cursor = null, count = 0;
    while (true) {
      const rows = (await product.query('SELECT id FROM public.profiles WHERE ($1::uuid IS NULL OR id > $1::uuid) ORDER BY id LIMIT 100', [cursor])).rows;
      if (!rows.length) break;
      const users = (await auth.query('SELECT id FROM public.users WHERE id = ANY($1::uuid[])', [rows.map(row => row.id)])).rows;
      if (new Set(users.map(row => row.id)).size !== rows.length) throw new Error('Product/auth identity reconciliation failed');
      cursor = rows.at(-1).id; count += rows.length;
    }
    console.log(`Recovery keys, phone indexes and product/auth identities verified; profiles=${count}`);
  } finally { await Promise.allSettled([product.end(), auth.end()]); }
}
if (require.main === module) main().catch(() => { console.error('Application recovery key/identity check failed'); process.exitCode = 1; });
module.exports = { main };
