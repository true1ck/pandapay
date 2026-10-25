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
    if (process.env.RESTORE_DATA_REVIEW_FILE) {
      const fs = require('node:fs');
      const {spawnSync} = require('node:child_process');
      const {reviewDataCleanup} = require('./review_data_cleanup');
      const output = process.env.RESTORE_DATA_REVIEW_FILE;
      const recipients = process.env.RESTORE_DIAGNOSTIC_RECIPIENTS_FILE;
      if (!path.isAbsolute(output) || !output.endsWith('.json.age') || !path.isAbsolute(recipients || '')) throw Error('Protected encrypted review output required');
      const reports = {};
      // Dedicated connections retain each read-only repeatable-read transaction.
      for (const [scope,pool] of [['product',product],['auth',auth]]) {
        const connection = await pool.connect();
        try { reports[scope] = await reviewDataCleanup(connection,{scope,maxChecks:500,maxDurationMs:180000}); }
        finally { connection.release(); }
      }
      const encrypted = spawnSync('age',['-R',recipients],{
        input:JSON.stringify({format:'pandapay-protected-restored-data-review-v1',reports}),
        timeout:30000,maxBuffer:16*1024*1024,
        env:{PATH:process.env.PATH,HOME:process.env.HOME},
      });
      if (encrypted.status !== 0 || !encrypted.stdout?.length) throw Error('Encrypted review failed');
      const pending = output + '.pending';
      const fd = fs.openSync(pending,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
      try {fs.writeFileSync(fd,encrypted.stdout);fs.fsyncSync(fd);} finally {fs.closeSync(fd);}
      fs.renameSync(pending,output);
      console.log(`Read-only restored data review saved encrypted; product_complete=${reports.product.complete} auth_complete=${reports.auth.complete}`);
      if (!reports.product.complete || !reports.auth.complete) throw Error('Restored data review is incomplete');
    }
    if (process.env.RESTORE_PRIVILEGE_REVIEW_FILE) {
      const result = await require('./review_restored_privileges').reviewRestoredPrivileges({ product, auth });
      console.log(`RESTORED_PRIVILEGE_REVIEW=complete product_blocking=${result.product_blocking} auth_blocking=${result.auth_blocking} history_unknown=${result.history_unknown} history_mismatched=${result.history_mismatched}`);
      // Complete review is not strict acceptance. Preserve findings encrypted;
      // caller/release gates must inspect strict_pass rather than infer it
      // from the successful underlying archive/key/identity restore.
    }
    console.log(`Recovery keys, phone indexes and product/auth identities verified; profiles=${count}`);
  } finally { await Promise.allSettled([product.end(), auth.end()]); }
}
if (require.main === module) main().catch(() => { console.error('Application recovery key/identity check failed'); process.exitCode = 1; });
module.exports = { main };
