'use strict';
// node scripts/snapshot_diff.js DIR_A DIR_B [ignoreKey,ignoreKey] : lists responses that differ between two bench_http.js --snapshot runs.
// The optional third argument names keys to drop everywhere first (e.g. `id` when rows were deleted and re-created between runs).
const fs = require('node:fs');
const [a, b, ignore] = process.argv.slice(2);
const ignored = new Set((ignore || '').split(',').filter(Boolean));
const strip = (v) => (Array.isArray(v) ? v.map(strip) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).filter(([k]) => !ignored.has(k)).map(([k, x]) => [k, strip(x)])) : v);
if (!a || !b) { console.error('usage: snapshot_diff.js DIR_A DIR_B'); process.exit(2); }
const names = new Set([...fs.readdirSync(a), ...fs.readdirSync(b)]);
let diff = 0;
function firstDiff(x, y, path = '') {
  if (JSON.stringify(x) === JSON.stringify(y)) return null;
  if (x && y && typeof x === 'object' && typeof y === 'object') {
    for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) { const d = firstDiff(x[k], y[k], `${path}/${k}`); if (d) return d; }
  }
  return `${path}: ${JSON.stringify(x)?.slice(0, 80)} -> ${JSON.stringify(y)?.slice(0, 80)}`;
}
for (const n of [...names].sort()) {
  const fa = fs.existsSync(`${a}/${n}`) ? strip(JSON.parse(fs.readFileSync(`${a}/${n}`, 'utf8'))) : undefined;
  const fb = fs.existsSync(`${b}/${n}`) ? strip(JSON.parse(fs.readFileSync(`${b}/${n}`, 'utf8'))) : undefined;
  const d = firstDiff(fa, fb);
  if (d) { diff += 1; console.log(`DIFF ${n} ${d}`); }
}
console.log(diff === 0 ? `IDENTICAL: ${names.size} responses` : `${diff} of ${names.size} responses differ`);
process.exit(diff === 0 ? 0 : 1);
