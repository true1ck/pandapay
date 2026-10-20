// npm audit is read-only: it does not run npm audit fix or change lockfiles.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const results = { date: '2026-10-20', command: 'npm audit --omit=dev --json',
  caveat: 'Affected installed packages, not proof every advisory is reachable in this application', services: {} };
for (const name of ['api', 'auth']) {
  let output;
  try { output = execFileSync('npm', ['audit', '--omit=dev', '--json'], { cwd: path.join(root, name), encoding: 'utf8' }); }
  catch (error) { output = error.stdout; }
  const report = JSON.parse(output);
  if (report.error) throw new Error(`${name}: npm audit did not complete`);
  results.services[name] = { metadata: report.metadata, vulnerabilities: report.vulnerabilities };
}
fs.writeFileSync(path.join(__dirname, 'dependency-audit.json'), JSON.stringify(results, null, 2) + '\n');
for (const [name, result] of Object.entries(results.services)) {
  console.log(JSON.stringify({ service: name, vulnerabilities: result.metadata.vulnerabilities,
    packages: Object.keys(result.vulnerabilities) }));
}
