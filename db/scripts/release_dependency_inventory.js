#!/usr/bin/env node
'use strict';

// Deterministic, bounded and offline dependency/artifact inventory. It never
// loads application configuration or contacts registries/providers.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const ROOT = path.resolve(__dirname, '../..');
const POLICY = require('../security/dependency-review-policy.json');
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
const candidates = [
  ['api/package-lock.json','npm-lock'], ['auth/package-lock.json','npm-lock'],
  ['app/pubspec.lock','dart-lock'], ['console/pubspec.lock','dart-lock'],
  ['packages/pandapay_domain/pubspec.lock','dart-lock'], ['packages/pandapay_lints/pubspec.lock','dart-lock'],
  ['app/ios/Podfile.lock','cocoapods-lock'], ['app/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved','swiftpm-lock'],
  ['app/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved','swiftpm-lock'],
  ['app/android/gradle.lockfile','gradle-lock'], ['app/android/app/gradle.lockfile','gradle-lock'],
  ['console/android/gradle.lockfile','gradle-lock'], ['console/android/app/gradle.lockfile','gradle-lock']
];
function safeRead(relative, max = POLICY.max_file_bytes, root = ROOT) {
  const base = path.resolve(root), file = path.resolve(base, relative);
  if (!file.startsWith(base + path.sep)) throw Error('unsafe path');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.size > max) throw Error('bounded regular file required');
    const data = Buffer.alloc(before.size + 1), n = fs.readSync(fd, data, 0, data.length, 0);
    const after = fs.fstatSync(fd);
    if (n !== before.size || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) throw Error('file changed during scan');
    return data.subarray(0, n);
  } finally { fs.closeSync(fd); }
}
function metadata(relative, kind, data, state) {
  let packageCount = null, licenseCount = null, provenanceCount = null, licenseStatus = 'unknown';
  const text = data.toString('utf8');
  if (kind === 'npm-lock') {
    const parsed = JSON.parse(text), packages = parsed.packages || {};
    packageCount = Object.keys(packages).length;
    licenseCount = Object.values(packages).filter(p => p && p.license).length;
    provenanceCount = Object.values(packages).filter(p => p && p.integrity).length;
    licenseStatus = licenseCount === packageCount ? 'known' : 'unknown';
  } else if (kind === 'dart-lock') {
    packageCount = (text.match(/^  [^ #][^:]*:\s*$/gm) || []).length;
    licenseCount = (text.match(/^    (?:description|license):/gm) || []).length;
    provenanceCount = (text.match(/^    source: /gm) || []).length;
  } else if (kind === 'cocoapods-lock') {
    packageCount = (text.match(/^  - [A-Za-z0-9_.+-]+ \(/gm) || []).length;
    provenanceCount = (text.match(/^SPEC REPOS:/m) || []).length;
  } else if (kind === 'swiftpm-lock') {
    const parsed = JSON.parse(text), pins = parsed.pins || [];
    packageCount = pins.length;
    provenanceCount = pins.filter(p => p && (p.location || p.identity)).length;
  } else if (kind.includes('lock')) {
    packageCount = (text.match(/^[^#\s][^=\s]+(?:=|\s)/gm) || []).length;
    provenanceCount = (text.match(/(?:originHash|repositoryURL|url):/g) || []).length;
  }
  return { path: relative, kind, state, sha256: data.length ? hash(data) : null, package_count: packageCount, license_count: licenseCount, license_status: licenseStatus, provenance_count: provenanceCount };
}
function inventory(root = ROOT) {
  const base = path.resolve(root);
  const files = [];
  let totalBytes = 0;
  const read = (relative, max = POLICY.max_file_bytes) => { const bytes=safeRead(relative,max,base);totalBytes+=bytes.length;if(totalBytes>POLICY.max_total_bytes)throw Error('inventory byte bound exceeded');return bytes; };
  for (const [relative, kind] of candidates) {
    try { files.push(metadata(relative, kind, read(relative), 'resolved-lock')); }
    catch (e) { if (e.code === 'ENOENT') files.push({path:relative,kind,state:'missing-unresolved',sha256:null,package_count:null,license_count:null,license_status:'unknown',provenance_count:null}); else throw Error(`${relative}: ${e.message}`); }
  }
  // Native declarations are declarations only, never presented as resolved.
  for (const relative of ['app/android/app/build.gradle','app/android/app/build.gradle.kts','app/android/build.gradle','app/android/build.gradle.kts','console/android/app/build.gradle','console/android/app/build.gradle.kts','app/ios/Podfile']) {
    try { files.push(metadata(relative, relative.endsWith('Podfile') ? 'pod-declaration' : 'gradle-declaration', read(relative), 'declared-only')); }
    catch (e) { if (e.code !== 'ENOENT') throw Error(`${relative}: ${e.message}`); }
  }
  // Vendored telephony source is hashed with per-file and aggregate bounds.
  const vendorRoot = path.join(base, 'app/third_party/telephony');
  if (fs.existsSync(vendorRoot)) {
    const list = [];
    function walk(dir) {
      for (const ent of fs.readdirSync(dir, { withFileTypes: true }).sort((a,b)=>a.name.localeCompare(b.name))) {
        if (POLICY.exclude_directories.includes(ent.name)) continue;
        const full = path.join(dir, ent.name);
        if (ent.isSymbolicLink()) throw Error('symlink in vendored source scope');
        if (ent.isDirectory()) walk(full);
        else if (ent.isFile()) { if (list.length >= POLICY.max_vendor_files) throw Error('vendor file bound exceeded'); const rel=path.relative(base,full).split(path.sep).join('/'), bytes=read(rel,POLICY.max_vendor_file_bytes); list.push({path:rel,sha256:hash(bytes)}); }
      }
    }
    walk(vendorRoot);
    const canonical = JSON.stringify(list);
    files.push({path:'app/third_party/telephony',kind:'vendored-source',state:'source-hashed',sha256:hash(canonical),file_count:list.length,files:list});
  }
  files.sort((a,b)=>a.path.localeCompare(b.path));
  if(files.length>POLICY.max_files)throw Error('inventory file bound exceeded');
  return {format:'pandapay-dependency-inventory-v1', generated_from:'working-tree', network:'none', built_artifacts:'not assessed', files};
}
if (require.main === module) {
  try { process.stdout.write(JSON.stringify(inventory(), null, 2) + '\n'); }
  catch (e) { process.stderr.write(`dependency inventory incomplete: ${e.message}\n`); process.exitCode = 2; }
}
module.exports = { inventory, safeRead, hash };
