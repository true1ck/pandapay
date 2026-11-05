const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const src = path.join(__dirname, '..', 'src');
const files = fs.readdirSync(src, { recursive: true })
  .filter((f) => f.endsWith('.js'))
  .map((f) => path.join(src, f));

test('server has no route that accepts raw SMS text', () => {
  const banned = ["'/transactions/from-sms'", "'/transactions/from-sms/batch'",
    "'/transactions/reconcile-sms'", "'/transactions/sms-import-state'", "'/sms/facts'"];
  const hits = [];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    for (const b of banned) if (text.includes(b)) hits.push(`${path.relative(src, f)}: ${b}`);
  }
  assert.deepEqual(hits, []);
});
