// Regex parity: every rule pattern runs against every example of its rule (and
// every ignore pattern against every example in the folder), in Dart and in
// Node. The match position, matched text and all named groups must agree.
//
//   node tools/sms_rules_cli/test/regex_parity.mjs [rulesFolder]
//
// The folder defaults to rules/sms/v2 when it exists, else the sample folder.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cliDir = resolve(here, '..');
const repoRoot = resolve(cliDir, '..', '..');

let folder = process.argv[2];
if (!folder) {
  const real = resolve(repoRoot, 'rules/sms/v2');
  folder = existsSync(real) ? real : resolve(here, 'sample_rules/good');
}
folder = resolve(folder);

// On Windows `dart` is a .bat shim, which spawnSync cannot start without a shell.
const dump = execFileSync('dart', ['run', 'test/regex_parity_dump.dart', folder], {
  cwd: cliDir,
  maxBuffer: 1 << 30,
  encoding: 'utf8',
  shell: process.platform === 'win32',
});
const cases = JSON.parse(dump);

let bad = 0;
const cache = new Map();
for (const c of cases) {
  const key = `${c.flags}/${c.pattern}`;
  let re = cache.get(key);
  if (!re) {
    // Dart has no stateful lastIndex; neither do we (no g/y flag).
    re = new RegExp(c.pattern, c.flags);
    cache.set(key, re);
  }
  const m = re.exec(c.input);
  const problems = [];
  if ((m !== null) !== c.matched) {
    problems.push(`matched: dart=${c.matched} node=${m !== null}`);
  } else if (m) {
    if (m.index !== c.index) problems.push(`index: dart=${c.index} node=${m.index}`);
    if (m[0] !== c.match) problems.push(`text: dart=${JSON.stringify(c.match)} node=${JSON.stringify(m[0])}`);
    const groups = m.groups ?? {};
    const names = new Set([...Object.keys(c.groups ?? {}), ...Object.keys(groups)]);
    for (const g of names) {
      const d = c.groups?.[g] ?? null;
      const n = groups[g] ?? null;
      if (d !== n) problems.push(`group ${g}: dart=${JSON.stringify(d)} node=${JSON.stringify(n)}`);
    }
  }
  if (problems.length) {
    bad++;
    console.error(`MISMATCH ${c.kind} ${c.id}: ${problems.join('; ')}\n  input: ${JSON.stringify(c.input)}`);
  }
}
console.log(`regex parity: ${cases.length} comparisons, ${bad} mismatch(es) [${folder}]`);
process.exit(bad === 0 ? 0 : 1);
