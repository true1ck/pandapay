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

// Decision D9: the old per-message Gemini worker stays deleted. GEMINI_API_KEY
// lives only on the private admin host (deploy/admin/compose.private.yml).
test('old per-message AI worker settings are gone, and the public deploy sends no Gemini key', () => {
  const read = (file) => fs.readFileSync(path.join(repo, file), 'utf8');
  const stale = /\b(AI_WORKER_[A-Z_]+|AI_PROVIDER_TIMEOUT_MS|GEMINI_FALLBACK_[A-Z_]+|GEMINI_API_KEYS|GEMINI_MODEL|GEMINI_REQUESTS_PER_[A-Z]+|GEMINI_TOKENS_PER_MINUTE)\b/;
  for (const file of ['.env.prod.example', 'api/example.env', 'docker-compose.yml', 'docker-compose.prod.yml',
    'docker-compose.staging.yml', 'deploy/deploy.sh', '.github/workflows/deploy-prod.yml',
    '.github/workflows/deploy-pushed-branch.yml', 'deploy/tests/test_deploy_security_order.py']) {
    assert.doesNotMatch(read(file), stale, file);
  }
  for (const file of ['docker-compose.prod.yml', 'docker-compose.staging.yml', 'deploy/deploy.sh',
    '.github/workflows/deploy-prod.yml', '.github/workflows/deploy-pushed-branch.yml',
    'deploy/tests/test_deploy_security_order.py']) {
    assert.doesNotMatch(read(file), /GEMINI_API_KEY/, file);
  }
  // The private overlay is the one place that passes the key, to the AI worker only.
  assert.match(read('deploy/admin/compose.private.yml'), /GEMINI_API_KEY: '\$\{GEMINI_API_KEY:\?\}'/);
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

// Fresh start: the legacy SMS route cutoff and its 426 version gate are gone,
// so nothing may read their settings again.
test('server, database setup, deploy scripts and env examples carry no legacy SMS cutoff settings', () => {
  const removed = /\b(LEGACY_SMS_CUTOFF_DATE|LEGACY_SMS_BLOCK_MISSING_VERSION|SMS_V2_FIRST_APP_VERSION|LEGACY_SMS_[A-Z_]+)\b/;
  const candidates = ['api/example.env', 'db/setup_app_role.sql', 'docker-compose.yml', 'docker-compose.staging.yml',
    'docker-compose.prod.yml', '.env.staging.example', '.env.prod.example'];
  for (const root of ['api/src', 'api/scripts', 'auth/src', 'db/scripts', 'deploy', 'scripts', '.github/workflows']) {
    const dir = path.join(repo, root);
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir, { recursive: true })) {
      const rel = path.join(root, name);
      if (!/node_modules/.test(rel) && fs.statSync(path.join(repo, rel)).isFile()) candidates.push(rel);
    }
  }
  const hits = [];
  for (const rel of candidates) {
    const file = path.join(repo, rel);
    if (!fs.existsSync(file)) continue;
    const match = fs.readFileSync(file, 'utf8').match(removed);
    if (match) hits.push(`${rel}: ${match[0]}`);
  }
  assert.deepEqual(hits, []);
});
