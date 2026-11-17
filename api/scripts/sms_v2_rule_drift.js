#!/usr/bin/env node
'use strict';
// Which rules in the repo (rules/sms/v2) differ from the ones live on the server?
//
// The rules import only inserts a rule id that does not exist yet (version 1), so a rule fixed in the repo
// never reaches production on its own. This lists the rules that have drifted. Read-only: it reads a dump of
// the live rules and the repo files, and changes nothing.
//
//   node api/scripts/sms_v2_rule_drift.js --live live_rules.json [--repo rules/sms/v2] [--json]
//
// live_rules.json: an array of { rule_id, version, status, body } (the latest version of each rule), as
// printed by `select rule_id,version,status,body from sms_v2_rules` (see docs of the drift report).
const fs = require('fs');
const path = require('path');

// What decides how a rule reads a message. updatedAt, version and createdBy are bookkeeping and ignored.
const FIELDS = ['status', 'priority', 'confidence', 'senders', 'family', 'match', 'emit'];

function repoRules(dir) {
  const out = new Map();
  const walk = (d) => {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.name.endsWith('.json')) {
        let json;
        try { json = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
        const list = Array.isArray(json) ? json : Array.isArray(json?.rules) ? json.rules : [];
        for (const r of list) if (r && typeof r.id === 'string' && r.match && r.emit) out.set(r.id, { rule: r, file: path.relative(dir, p) });
      }
    }
  };
  walk(dir);
  return out;
}

const norm = (v) => JSON.stringify(v, (_k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));

// { same, drifted: [{id, file, liveVersion, fields}], repoOnly: [ids], liveOnly: [ids] }
function compare(repo, live) {
  const liveById = new Map(live.map((row) => [row.rule_id, row]));
  const report = { same: 0, drifted: [], repoOnly: [], liveOnly: [] };
  for (const [id, { rule, file }] of repo) {
    const row = liveById.get(id);
    if (!row) { report.repoOnly.push(id); continue; }
    const body = row.body || {};
    const fields = FIELDS.filter((f) => norm(rule[f]) !== norm(body[f]));
    if (fields.length) report.drifted.push({ id, file, liveVersion: row.version, fields });
    else report.same += 1;
  }
  for (const id of liveById.keys()) if (!repo.has(id)) report.liveOnly.push(id);
  return report;
}

function main(argv) {
  const arg = (name, fallback) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : fallback; };
  const livePath = arg('--live');
  if (!livePath) { console.error('usage: sms_v2_rule_drift.js --live live_rules.json [--repo rules/sms/v2] [--json]'); return 2; }
  const live = JSON.parse(fs.readFileSync(livePath, 'utf8'));
  const report = compare(repoRules(arg('--repo', 'rules/sms/v2')), live);
  if (argv.includes('--json')) { console.log(JSON.stringify(report, null, 2)); return 0; }
  console.log(`same: ${report.same}   drifted: ${report.drifted.length}   repo only: ${report.repoOnly.length}   live only: ${report.liveOnly.length}`);
  console.log('\nDRIFTED (live text differs from the repo; a re-import will not fix these):');
  for (const d of report.drifted) console.log(`  ${d.id}  v${d.liveVersion}  [${d.fields.join(', ')}]  ${d.file}`);
  console.log('\nREPO ONLY (not live yet; the import adds these):');
  for (const id of report.repoOnly) console.log(`  ${id}`);
  console.log('\nLIVE ONLY (in production, not in the repo files):');
  for (const id of report.liveOnly) console.log(`  ${id}`);
  return report.drifted.length ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { compare, repoRules };
