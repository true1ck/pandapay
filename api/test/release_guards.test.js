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

test('mailbox passwords are never encrypted or decrypted inside PostgreSQL', () => {
  const hits = [];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    if (/pgp_sym_(en|de)crypt|app_password_encrypted/.test(text)) hits.push(path.relative(src, f));
  }
  assert.deepEqual(hits, []);
});

test('both email paths drop the email text through the shared helper once a transaction exists', () => {
  const index = fs.readFileSync(path.join(src, 'index.js'), 'utf8');
  assert.equal((index.match(/markInboundEmailConverted\(client,/g) || []).length, 2);
  assert.ok(!/UPDATE inbound_emails SET produced_txn_id/.test(index));
});
