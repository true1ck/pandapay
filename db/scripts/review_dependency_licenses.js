#!/usr/bin/env node
'use strict';

// Offline, bounded summary of dependency license evidence. Lock metadata is
// evidence about the lock entry only; it does not establish legal approval.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const ROOT = path.resolve(__dirname, '../..');
const PUB_CACHE = path.join(process.env.PUB_CACHE || path.join(process.env.HOME || '', '.pub-cache'), 'hosted/pub.dev');
const MAX_FILE = 16 * 1024 * 1024;
const MAX_PACKAGES = 5000;
const LOCKS = [
  ['api/package-lock.json', 'npm'], ['auth/package-lock.json', 'npm'],
  ['app/pubspec.lock', 'dart'], ['console/pubspec.lock', 'dart'],
  ['packages/pandapay_lints/pubspec.lock', 'dart'], ['packages/pandapay_domain/pubspec.lock', 'dart'],
  ['app/ios/Podfile.lock', 'pod'],
  ['app/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'swift']
];
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
function read(root, rel) {
  const base = path.resolve(root), full = path.resolve(base, rel);
  if (!full.startsWith(base + path.sep)) throw Error('unsafe path');
  const fd = fs.openSync(full, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > MAX_FILE) throw Error('bounded regular file required');
    const buf = Buffer.alloc(st.size + 1), n = fs.readSync(fd, buf, 0, buf.length, 0);
    const after=fs.fstatSync(fd);if(n!==st.size||after.size!==st.size||after.mtimeMs!==st.mtimeMs||after.ctimeMs!==st.ctimeMs)throw Error('file changed during scan');
    return buf.subarray(0, n);
  } finally { fs.closeSync(fd); }
}
function dartEntries(text) {
  const entries = [];
  const re = /^  ([^ #][^:]*):\n([\s\S]*?)(?=^  [^ #][^:]*:\n|^sdks:)/gm;
  for (const m of text.matchAll(re)) {
    const block = m[2];
    const version = block.match(/^    version: "?([^"\n]+)"?$/m)?.[1] || null;
    const source = block.match(/^    source: ([^\n]+)$/m)?.[1] || 'unknown';
    const pkg = block.match(/^      name: ([^\n]+)$/m)?.[1] || m[1];
    if(!/^[a-z_][a-z0-9_]{0,127}$/.test(pkg)||!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(version||'')||!['hosted','path','sdk','git'].includes(source))throw Error('invalid Dart lock entry');
    if(entries.some(p=>p.name===pkg)||entries.length>=MAX_PACKAGES)throw Error('duplicate or excessive Dart entries');
    entries.push({name:pkg,version,source});
  }
  return entries;
}
function podEntries(text) {
  const section = text.match(/^PODS:\n([\s\S]*?)(?=^DEPENDENCIES:)/m)?.[1] || '';
  return [...section.matchAll(/^  - (?:"(.+?) \(([^)]+)\)"|([^\s(]+) \(([^)]+)\)):?$/gm)]
    .map(m => ({name: m[1] || m[3], version: m[2] || m[4]}));
}
function summarize(root = ROOT, pubCache = PUB_CACHE) {
  const reports = [];
  const vendorLicenseText = read(root, 'app/third_party/telephony/LICENSE').toString('utf8');
  const vendorLicenseRecognized = /MIT License/.test(vendorLicenseText) && /Copyright \(c\) 2020 Shounak Mulay/.test(vendorLicenseText);
  let total = 0;
  for (const [rel, ecosystem] of LOCKS) {
    const bytes = read(root, rel); total += bytes.length;
    let packages = [], sourceEvidence = null, licenseEvidence = null;
    const text = bytes.toString('utf8');
    if (ecosystem === 'npm') {
      const lock = JSON.parse(text), entries = Object.entries(lock.packages || {}).filter(([k]) => k !== '');
      packages = entries.map(([name, p]) => ({name: name.replace(/^node_modules\//, ''), version: p.version || null, license: typeof p.license === 'string' && /^[A-Za-z0-9.+() -]{1,128}$/.test(p.license) ? p.license : (p.license ? 'present-unparsed' : null), evidence: p.license ? 'lock-license-field' : 'unknown'}));
      licenseEvidence = {known: packages.filter(p => p.evidence !== 'unknown').length, unknown: packages.filter(p => p.evidence === 'unknown').length, basis: 'package-lock license fields; values are not approval'};
      sourceEvidence = {integrity: entries.filter(([,p]) => p.integrity).length, absentIntegrity: entries.filter(([,p]) => !p.integrity).length};
    } else if (ecosystem === 'dart') {
      packages = dartEntries(text).map(p => {
        let licenseFile = false;
        if (p.source === 'hosted') {
          const dir = path.join(pubCache, `${p.name}-${p.version}`);
          try {
            const cache=fs.realpathSync(pubCache),resolved=fs.realpathSync(dir);
            if(!resolved.startsWith(cache+path.sep))throw Error('package cache escape');
            for(const name of ['LICENSE','LICENSE.md','LICENSE.txt','LICENCE','LICENCE.md','LICENCE.txt']) {
              try{const filename=path.join(dir,name);const fd=fs.openSync(filename,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const stat=fs.fstatSync(fd);if(stat.isFile()&&stat.size<=MAX_FILE)licenseFile=true;}finally{fs.closeSync(fd);}}catch(_){}
            }
          } catch (_) {}
        }
        if (p.name === 'telephony' && p.version === '0.2.0' && p.source === 'path' && vendorLicenseRecognized) licenseFile = true;
        return {...p, license: p.name === 'telephony' && licenseFile ? 'MIT' : undefined, evidence: licenseFile ? (p.source === 'path' ? 'vendored-license-file-present' : 'cached-license-file-present') : 'unknown'};
      });
      licenseEvidence = {known: packages.filter(p => p.evidence !== 'unknown').length, unknown: packages.filter(p => p.evidence === 'unknown').length, basis: 'cached hosted package LICENSE file existence only; contents/terms not reviewed'};
      sourceEvidence = {hosted: packages.filter(p => p.source === 'hosted').length, sdk: packages.filter(p => p.source === 'sdk').length, path: packages.filter(p => p.source === 'path').length, git: packages.filter(p => p.source === 'git').length};
    } else if (ecosystem === 'pod') {
      packages = podEntries(text).map(p => ({...p, evidence:'unknown'}));
      licenseEvidence = {known:0, unknown:packages.length, basis:'Podfile.lock has no license terms; no package license review performed'};
      sourceEvidence = {specRepos: (text.match(/^SPEC REPOS:/gm)||[]).length, checksums: (text.match(/^SPEC CHECKSUMS:/gm)||[]).length};
    } else {
      const json = JSON.parse(text);
      packages = (json.pins || []).map(p => ({name:p.identity || 'unknown', version:p.state?.version || null, revision:p.state?.revision || null, evidence:'unknown'}));
      licenseEvidence = {known:0, unknown:packages.length, basis:'Package.resolved pins source revisions, not license terms'};
      sourceEvidence = {pins:packages.length, withRevision:packages.filter(p=>p.revision).length};
    }
    if (packages.length > MAX_PACKAGES) throw Error(`${rel}: package count bound exceeded`);
    reports.push({path:rel, ecosystem, lock_sha256:hash(bytes), package_count:packages.length, license_evidence:licenseEvidence, source_evidence:sourceEvidence, packages});
  }
  if (total > 64 * 1024 * 1024) throw Error('aggregate lock byte bound exceeded');
  const vendorRel = 'app/third_party/telephony/LICENSE';
  const vendor = vendorLicenseText;
  if (!/MIT License/.test(vendor) || !/Copyright \(c\) 2020 Shounak Mulay/.test(vendor)) throw Error('telephony license text not recognized');
  const unknown = reports.reduce((n,r)=>n+r.license_evidence.unknown,0);
  return {format:'pandapay-dependency-license-review-v1', generated_from:'working-tree', network:'none', status:unknown ? 'incomplete' : 'evidence-collected-needs-legal-review', unknown_license_entries:unknown, lock_count:reports.length, packages:reports.reduce((n,r)=>n+r.package_count,0), licenses:'package evidence summarized; legal/application approval not asserted', locks:reports, vendored:{path:'app/third_party/telephony',version:'0.2.0',license:'MIT',license_path:vendorRel,license_sha256:hash(Buffer.from(vendor)),upstream:'https://github.com/shounakmulay/Telephony',local_patch:'app/third_party/telephony/PANDAPAY_PATCH.md',provenance:'README and pubspec identify upstream; source is locally patched; no immutable upstream commit/archive hash established by this review'}};
}
if (require.main === module) {
  try { const report=summarize();process.stdout.write(JSON.stringify(report,null,2)+'\n');if(report.status==='incomplete')process.exitCode=2; }
  catch (e) { process.stderr.write('Dependency license review incomplete; bounded input review failed.\n'); process.exitCode = 2; }
}
module.exports = {summarize, dartEntries, podEntries};
