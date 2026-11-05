'use strict';

// Syntax-checks every JavaScript file under api/src/sms_v2/ plus the v2 scripts
// (WP-08), and that api/sms_v2_assets is in step with its sources. New files are
// picked up by the glob, so later work packages never edit api/package.json.
// Run by `npm run check`.

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const dirs = [path.join(root, 'src', 'sms_v2'), path.join(root, 'src', 'sms_v2', 'jobs')];
const extra = fs.readdirSync(path.join(root, 'scripts'))
  .filter((f) => /sms_v2.*\.js$/.test(f))
  .map((f) => path.join(root, 'scripts', f));

const files = [...extra];
for (const dir of dirs) {
  if (!fs.existsSync(dir)) continue;
  for (const f of fs.readdirSync(dir)) if (f.endsWith('.js')) files.push(path.join(dir, f));
}

let failed = 0;
for (const file of files.sort()) {
  const r = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  if (r.status !== 0) {
    failed += 1;
    process.stderr.write(`syntax error in ${path.relative(root, file)}\n${r.stderr}\n`);
  }
}
// The vendored copy the Docker image uses must match contracts/sms/v2 and the gates file.
const assets = require('./sync_sms_v2_assets').check();
if (!assets.ok) {
  failed += 1;
  process.stderr.write(`api/sms_v2_assets is out of date (run: node scripts/sync_sms_v2_assets.js)\n  ${assets.problems.join('\n  ')}\n`);
}
if (!files.length) {
  process.stderr.write('check_sms_v2: no files found\n');
  process.exit(1);
}
if (failed) process.exit(1);
console.log(`check_sms_v2: ${files.length} files OK`);
