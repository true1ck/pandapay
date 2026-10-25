'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { inventory, safeRead } = require('../scripts/release_dependency_inventory');

test('offline dependency inventory is deterministic and separates lock state from declarations', () => {
  const first = inventory(), second = inventory();
  assert.deepEqual(first, second);
  assert.equal(first.network, 'none');
  assert.equal(first.built_artifacts, 'not assessed');
  assert.ok(first.files.some(f => f.path === 'api/package-lock.json' && f.state === 'resolved-lock'));
  assert.ok(first.files.some(f => f.kind === 'gradle-declaration' && f.state === 'declared-only'));
  assert.ok(first.files.some(f => f.path === 'app/ios/Podfile.lock'));
  assert.ok(first.files.some(f => f.path === 'app/third_party/telephony' && f.state === 'source-hashed'));
  for (const f of first.files) if (f.sha256) assert.match(f.sha256, /^[a-f0-9]{64}$/);
  assert.equal(JSON.stringify(first).includes('://'), false, 'inventory must not include registry/source URLs');
});

test('missing locks remain unresolved and declarations never claim resolved dependencies', () => {
  const result = inventory();
  for (const f of result.files.filter(f => f.state === 'missing-unresolved')) {
    assert.equal(f.package_count, null);
    assert.equal(f.sha256, null);
  }
  for (const f of result.files.filter(f => f.kind.endsWith('declaration'))) assert.equal(f.state, 'declared-only');
  assert.ok(result.files.some(f => f.kind === 'npm-lock' && f.license_status === 'unknown'));
});

test('fixture inventory fails closed for malformed, oversized, unsafe, and symlinked inputs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-deps-'));
  try {
    fs.mkdirSync(path.join(dir, 'api'), {recursive:true});
    fs.writeFileSync(path.join(dir, 'api/package-lock.json'), '{"packages":{}}');
    assert.equal(inventory(dir).files.find(f => f.path === 'api/package-lock.json').package_count, 0);
    fs.writeFileSync(path.join(dir, 'api/package-lock.json'), '{truncated');
    assert.throws(() => inventory(dir), /JSON|position|property/i);
    fs.writeFileSync(path.join(dir, 'api/package-lock.json'), 'x'.repeat(16 * 1024 * 1024 + 1));
    assert.throws(() => inventory(dir), /bounded regular file/);
    assert.throws(() => safeRead('../outside', 1024, dir), /unsafe path/);
    fs.rmSync(path.join(dir, 'api/package-lock.json'));
    fs.symlinkSync('/etc/hosts', path.join(dir, 'api/package-lock.json'));
    assert.throws(() => inventory(dir), /ELOOP|symbolic|too many levels/i);
  } finally { fs.rmSync(dir, {recursive:true, force:true}); }
});

test('inventory reports hashes and metadata without exposing lock URLs or duplicate content', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-deps-redact-'));
  try {
    fs.mkdirSync(path.join(dir, 'api'), {recursive:true}); fs.mkdirSync(path.join(dir, 'auth'), {recursive:true});
    const raw = JSON.stringify({packages:{'':{},'node_modules/demo':{version:'1.0.0',resolved:'https://user:password@registry.example/pkg?token=secret',integrity:'sha512-fixture'}}});
    fs.writeFileSync(path.join(dir, 'api/package-lock.json'), raw); fs.writeFileSync(path.join(dir, 'auth/package-lock.json'), raw);
    const result=inventory(dir), a=result.files.find(f=>f.path==='api/package-lock.json'), b=result.files.find(f=>f.path==='auth/package-lock.json');
    assert.equal(a.sha256,b.sha256);
    const output=JSON.stringify(result);
    assert.equal(output.includes('registry.example'),false); assert.equal(output.includes('password'),false); assert.equal(output.includes('token=secret'),false);
    assert.equal(a.license_status,'unknown');
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});
