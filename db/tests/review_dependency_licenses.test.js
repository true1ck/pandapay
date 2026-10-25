'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {summarize, dartEntries, podEntries} = require('../scripts/review_dependency_licenses');

test('review deterministically describes current locks and preserves unknown license evidence', () => {
  const a = summarize(), b = summarize();
  assert.deepEqual(a, b);
  assert.equal(a.network, 'none');
  assert.equal(a.locks.find(x => x.path === 'api/package-lock.json').license_evidence.known, 98);
  assert.equal(a.locks.find(x => x.path === 'auth/package-lock.json').license_evidence.known, 186);
  assert.ok(a.locks.find(x => x.ecosystem === 'pod').license_evidence.unknown > 0);
  assert.equal(a.locks.find(x => x.ecosystem === 'swift').license_evidence.unknown, 1);
  const appDart = a.locks.find(x => x.path === 'app/pubspec.lock');
  assert.equal(appDart.packages.find(p => p.name === 'telephony').license, 'MIT');
  assert.equal(a.status, 'incomplete');
  assert.match(a.vendored.license_sha256, /^[a-f0-9]{64}$/);
  assert.equal(a.vendored.license, 'MIT');
  assert.ok(a.locks.flatMap(x => x.packages).every(p => !('url' in p) && !('resolved' in p)));
});

test('Dart and Podfile lock readers preserve exact package/version/source boundaries', () => {
  const dart = dartEntries(`packages:\n  demo:\n    dependency: transitive\n    description:\n      name: demo\n      url: "https://pub.dev"\n    source: hosted\n    version: "1.2.3"\n  path_pkg:\n    dependency: "direct main"\n    description:\n      path: ../path_pkg\n      relative: true\n    source: path\n    version: "0.1.0"\nsdks:\n  dart: ">=3.0.0 <4.0.0"\n`);
  assert.deepEqual(dart, [
    {name:'demo',version:'1.2.3',source:'hosted'},
    {name:'path_pkg',version:'0.1.0',source:'path'}
  ]);
  assert.deepEqual(podEntries('PODS:\n  - "Demo/Sub (1.2.3)":\n  - Plain (4.5.6)\nDEPENDENCIES:\n'), [
    {name:'Demo/Sub',version:'1.2.3'}, {name:'Plain',version:'4.5.6'}
  ]);
});

test('malformed locks and unsafe files fail closed', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-license-review-'));
  try {
    fs.mkdirSync(path.join(root,'app/third_party/telephony'),{recursive:true});
    fs.writeFileSync(path.join(root,'app/third_party/telephony/LICENSE'),'MIT License\nCopyright (c) 2020 Shounak Mulay\n');
    fs.mkdirSync(path.join(root,'api'),{recursive:true});
    fs.writeFileSync(path.join(root,'api/package-lock.json'),'{broken');
    assert.throws(() => summarize(root, path.join(root,'pub-cache')), /JSON|position|property/i);
    fs.rmSync(path.join(root,'api/package-lock.json'));
    fs.symlinkSync('/etc/hosts',path.join(root,'api/package-lock.json'));
    assert.throws(() => summarize(root, path.join(root,'pub-cache')), /ELOOP|symbolic|too many levels/i);
  } finally { fs.rmSync(root,{recursive:true,force:true}); }
});

test('Dart package metadata cannot escape cache or silently accept malformed input',()=>{
 for(const [name,version] of [['../outside','1.2.3'],['valid','../../private'],['valid','']]){
  assert.throws(()=>dartEntries(`packages:\n  ${name}:\n    description:\n      name: ${name}\n    source: hosted\n    version: "${version}"\nsdks:\n`),/invalid Dart lock entry/);
 }
});

test('CLI marks unresolved review incomplete with a failing exit code',()=>{
 const {spawnSync}=require('node:child_process');const script=path.resolve(__dirname,'../scripts/review_dependency_licenses.js');
 const env=Object.fromEntries(['PATH','HOME','PUB_CACHE'].filter(k=>process.env[k]).map(k=>[k,process.env[k]]));
 const result=spawnSync(process.execPath,[script],{env,encoding:'utf8',timeout:10000,maxBuffer:4*1024*1024});
 assert.equal(result.status,2);assert.equal(JSON.parse(result.stdout).status,'incomplete');assert.equal(result.stderr,'');
});
