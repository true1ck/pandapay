'use strict';

// Keeps api/sms_v2_assets/ in step with its sources (WP-08).
//
// api/Dockerfile builds from the api/ directory only, so contracts/sms/v2 and
// tools/sms_golden/gates.json are not in the image's build context. The server
// needs both at run time (every v2 route validates against the contracts; rule
// publishing checks the golden-set gates), so a copy of exactly those files
// lives under api/sms_v2_assets/ and the Dockerfile points
// SMS_V2_CONTRACTS_DIR / SMS_V2_GATES_PATH at it.
//
//   node scripts/sync_sms_v2_assets.js          copy the sources over the vendored files
//   node scripts/sync_sms_v2_assets.js --check  exit 1 if they differ (run by `npm run check`)
//
// Only schemas and error_codes.json are copied, never the fixtures.

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const repo = path.resolve(root, '..');
const SOURCES = [
  { from: path.join(repo, 'contracts', 'sms', 'v2'), to: path.join(root, 'sms_v2_assets', 'contracts', 'sms', 'v2'), pick: (rel) => rel === 'error_codes.json' || rel.endsWith('.schema.json') },
  { from: path.join(repo, 'tools', 'sms_golden'), to: path.join(root, 'sms_v2_assets'), pick: (rel) => rel === 'gates.json' },
];

function list(dir, pick, base = dir) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'fixtures') out.push(...list(full, pick, base)); } else if (pick(path.relative(base, full))) out.push(path.relative(base, full));
  }
  return out.sort();
}

function plan() {
  const ops = [];
  for (const s of SOURCES) {
    for (const rel of list(s.from, s.pick)) ops.push({ src: path.join(s.from, rel), dst: path.join(s.to, rel) });
  }
  return ops;
}

function check() {
  const ops = plan();
  if (!ops.length) return { ok: true, skipped: true, problems: [] }; // sources absent (for example inside the image)
  const problems = [];
  for (const { src, dst } of ops) {
    if (!fs.existsSync(dst)) problems.push(`missing ${path.relative(root, dst)}`);
    else if (!fs.readFileSync(src).equals(fs.readFileSync(dst))) problems.push(`differs ${path.relative(root, dst)}`);
  }
  // A vendored file whose source was removed is stale too.
  for (const s of SOURCES) {
    const expected = new Set(list(s.from, s.pick));
    for (const rel of list(s.to, s.pick)) if (!expected.has(rel)) problems.push(`stale ${path.relative(root, path.join(s.to, rel))}`);
  }
  return { ok: problems.length === 0, skipped: false, problems };
}

function sync() {
  const ops = plan();
  if (!ops.length) throw new Error('sources not found; run from a full checkout');
  for (const { src, dst } of ops) {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
  }
  for (const s of SOURCES) {
    const expected = new Set(list(s.from, s.pick));
    for (const rel of list(s.to, s.pick)) if (!expected.has(rel)) fs.rmSync(path.join(s.to, rel));
  }
  return ops.length;
}

if (require.main === module) {
  if (process.argv.includes('--check')) {
    const r = check();
    if (!r.ok) {
      process.stderr.write(`api/sms_v2_assets is out of date (run: node scripts/sync_sms_v2_assets.js)\n  ${r.problems.join('\n  ')}\n`);
      process.exit(1);
    }
    console.log(r.skipped ? 'sms_v2_assets: sources not present, skipped' : 'sms_v2_assets: in step with contracts/sms/v2 and tools/sms_golden/gates.json');
  } else {
    console.log(`sms_v2_assets: copied ${sync()} files`);
  }
}

module.exports = { check, sync, plan };
