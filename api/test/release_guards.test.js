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

// Decision D5: server-escrowed account recovery is gone for good.
const repo = path.join(__dirname, '..', '..');

test('server has no account recovery escrow route, module or configuration', () => {
  const hits = [];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    if (/account[-_]recovery|ACCOUNT_RECOVERY|\/account\/recovery/i.test(text)) hits.push(path.relative(src, f));
  }
  assert.deepEqual(hits, []);
});

test('compose files and env examples carry no account recovery settings', () => {
  const hits = [];
  for (const name of ['docker-compose.yml', 'docker-compose.staging.yml', 'docker-compose.prod.yml',
    '.env.staging.example', '.env.prod.example']) {
    const file = path.join(repo, name);
    if (fs.existsSync(file) && /ACCOUNT_RECOVERY/.test(fs.readFileSync(file, 'utf8'))) hits.push(name);
  }
  assert.deepEqual(hits, []);
});

test('a migration drops the account_recovery schema, so a database cannot keep the escrow tables', () => {
  const dir = path.join(repo, 'db', 'supabase', 'migrations');
  const dropping = fs.readdirSync(dir).filter((n) => n.endsWith('.sql'))
    .filter((n) => /drop\s+schema\s+(if\s+exists\s+)?account_recovery\s*;/i.test(fs.readFileSync(path.join(dir, n), 'utf8')));
  assert.equal(dropping.length, 1, 'exactly one migration drops account_recovery');
  const created = fs.readdirSync(dir).filter((n) => /create\s+schema\s+account_recovery/i.test(fs.readFileSync(path.join(dir, n), 'utf8')));
  for (const n of created) assert.ok(dropping[0] > n, `${dropping[0]} must sort after ${n}`);
  assert.ok(!/\bcascade\b/i.test(fs.readFileSync(path.join(dir, dropping[0]), 'utf8').replace(/--[^\n]*/g, '')), 'no CASCADE');
});
