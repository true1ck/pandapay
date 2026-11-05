'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// The app records one policy version for every consent screen, and product
// activation compares the terms version it sends with this server's. They
// must be the same date, or sign-up fails with `product_terms_changed`.
function appPolicyVersion() {
  const source = fs.readFileSync(path.join(__dirname, '../../app/lib/data/consent_policy.dart'), 'utf8');
  const match = source.match(/const consentPolicyVersion = '([^']+)';/);
  assert.ok(match, 'consentPolicyVersion is declared in the app');
  return match[1];
}

test('the server default product terms version is the app policy version', () => {
  const saved = process.env.PRODUCT_TERMS_VERSION;
  delete process.env.PRODUCT_TERMS_VERSION;
  delete require.cache[require.resolve('../src/config')];
  try {
    const config = require('../src/config');
    assert.equal((config.config || config).productTermsVersion, appPolicyVersion());
  } finally {
    if (saved !== undefined) process.env.PRODUCT_TERMS_VERSION = saved;
    delete require.cache[require.resolve('../src/config')];
  }
});

test('deploy files do not pin an older product terms version', () => {
  const root = path.join(__dirname, '../..');
  for (const file of ['docker-compose.yml', 'docker-compose.prod.yml', 'docker-compose.staging.yml', '.env.prod.example', '.env.staging.example']) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    const pinned = text.match(/PRODUCT_TERMS_VERSION[:=]\s*"?\$?\{?(?:PRODUCT_TERMS_VERSION:-)?([0-9]{4}-[0-9]{2}-[0-9]{2})/);
    assert.ok(pinned, `${file} sets PRODUCT_TERMS_VERSION`);
    assert.equal(pinned[1], appPolicyVersion(), `${file} pins ${pinned[1]}`);
  }
});
