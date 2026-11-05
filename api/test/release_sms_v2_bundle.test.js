'use strict';
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { release, parseArgs, secretsFrom } = require('../scripts/release_sms_v2_bundle');

const ADMIN = '11111111-2222-4333-8444-555555555555';
const FIXTURE = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../contracts/sms/v2/fixtures/valid/bundle/full.json'), 'utf8'));
const UNSIGNED = { ...FIXTURE, signature: null };

function makeKey() {
  const pem = crypto.generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'pem' });
  return pem.trim();
}

// A runner that stands in for dart and the import script, recording every call.
function harness({ goldenStatus = 0, buildStatus = 0, importResult, importStatus = 0, leak = null, bundle = UNSIGNED } = {}) {
  const calls = [];
  const lines = [];
  const run = (command, args, { cwd, env }) => {
    const which = command === 'dart' ? args[2] : 'import';
    calls.push({ which, command, args, cwd, env });
    if (which === 'build') {
      if (buildStatus === 0) fs.writeFileSync(args[args.indexOf('--out') + 1], JSON.stringify(bundle));
      return { status: buildStatus, stdout: 'built: 2 rules, 3 examples OK.\n', stderr: leak && buildStatus ? `boom ${leak}` : '' };
    }
    if (which === 'sign-dev') return { status: 0, stdout: 'signed\n', stderr: '' };
    if (which === 'golden') return { status: goldenStatus, stdout: leak ? `GATE FAIL ${leak}\n` : '  GATE FAIL ruleCount: 1\ngolden: FAILED\n', stderr: '' };
    if (which === 'import') {
      return { status: importStatus, stdout: `${JSON.stringify(importResult || { rulesInserted: 2, bundlesMinted: [{ bundleVersion: 1, cohort: 'all' }, { bundleVersion: 2, cohort: 'pct25' }, { bundleVersion: 3, cohort: 'pct5' }, { bundleVersion: 4, cohort: 'testers' }] })}\n`, stderr: importStatus ? `import error ${leak || ''}` : '' };
    }
    throw new Error(`unexpected command ${command} ${args.join(' ')}`);
  };
  return { calls, lines, deps: (env) => ({ env, run, log: (l) => lines.push(l) }) };
}
const workDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'release-test-'));

test('dry run is the default: build, gate and checks run, nothing is imported', () => {
  const h = harness();
  const code = release(['--work-dir', workDir()], h.deps({ PATH: process.env.PATH }));
  assert.equal(code, 0);
  assert.deepEqual(h.calls.map((c) => c.which), ['build', 'sign-dev', 'golden']);
  assert.ok(h.lines.some((l) => /DRY RUN/.test(l)));
  assert.ok(h.lines.some((l) => /\[import\] skipped/.test(l)));
  const golden = h.calls.find((c) => c.which === 'golden').args;
  assert.ok(golden.includes('--require-stages'));
  assert.equal(golden[golden.indexOf('--profile') + 1], 'release');
  assert.ok(golden[golden.indexOf('--baseline') + 1].endsWith('tools/sms_golden/reports/latest.json'));
});

test('a failing golden gate stops everything, in dry run and with --apply', () => {
  for (const extra of [[], ['--apply', '--admin-id', ADMIN]]) {
    const h = harness({ goldenStatus: 1 });
    const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: makeKey(), SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
    const code = release(['--work-dir', workDir(), ...extra], h.deps(env));
    assert.equal(code, 1);
    assert.ok(!h.calls.some((c) => c.which === 'import'), 'no import after a failed gate');
    assert.ok(h.lines.some((l) => /\[gate\] FAILED/.test(l) && /nothing was imported/.test(l)));
    assert.ok(h.lines.some((l) => /Nothing after this step ran/.test(l)));
  }
});

test('a failing build stops before the golden run', () => {
  const h = harness({ buildStatus: 1 });
  assert.equal(release(['--work-dir', workDir()], h.deps({ PATH: process.env.PATH })), 1);
  assert.deepEqual(h.calls.map((c) => c.which), ['build']);
});

test('a bundle that breaks the contract stops the release before any import', () => {
  const h = harness({ bundle: { ...UNSIGNED, rules: 'not-an-array' } });
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: makeKey(), SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  assert.equal(release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], h.deps(env)), 1);
  assert.ok(!h.calls.some((c) => c.which === 'import'));
  assert.ok(h.lines.some((l) => /\[checks\] FAILED/.test(l)));
});

test('--apply refuses before building when its preconditions are missing', () => {
  const base = { PATH: process.env.PATH };
  const cases = [
    [['--apply'], base],
    [['--apply', '--admin-id', 'not-a-uuid'], base],
    [['--apply', '--admin-id', ADMIN], base],
    [['--apply', '--admin-id', ADMIN], { ...base, SMS_RULES_SIGNING_KEY: makeKey() }],
    [['--apply', '--admin-id', ADMIN], { ...base, SMS_RULES_SIGNING_KEY: 'not a key', SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' }],
    [['--apply', '--admin-id', ADMIN], { ...base, SMS_RULES_SIGNING_KEY: makeKey(), SMS_RULES_KEY_ID: 'k1' }],
  ];
  for (const [argv, env] of cases) {
    const h = harness();
    assert.equal(release(['--work-dir', workDir(), ...argv], h.deps(env)), 2, argv.join(' '));
    assert.equal(h.calls.length, 0, 'nothing ran');
  }
  assert.throws(() => parseArgs(['--bogus']), /unknown or incomplete/);
});

test('--apply imports once with the key in the environment only, and checks every cohort was minted', () => {
  const key = makeKey();
  const h = harness();
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: key, SMS_RULES_KEY_ID: 'prod-1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  assert.equal(release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], h.deps(env)), 0);
  assert.deepEqual(h.calls.map((c) => c.which), ['build', 'sign-dev', 'golden', 'import']);
  const imp = h.calls[3];
  assert.ok(imp.args[0].endsWith('import_sms_v2_rules.js'));
  assert.equal(imp.args[imp.args.indexOf('--admin-id') + 1], ADMIN);
  assert.equal(imp.env.SMS_RULES_SIGNING_KEY, key);
  assert.equal(imp.env.SMS_RULES_KEY_ID, 'prod-1');
  assert.ok(h.lines.some((l) => /\[verify\] ok: .*testers=v4/.test(l)));
  // The tools CLI never receives the production key; only the sign-dev step gets the throwaway seed.
  for (const c of h.calls.filter((x) => x.command === 'dart')) assert.equal(c.env.SMS_RULES_SIGNING_KEY, undefined);
  assert.ok(h.calls.find((c) => c.which === 'sign-dev').env.SMS_RULES_DEV_KEY);
  assert.equal(h.calls.find((c) => c.which === 'golden').env.SMS_RULES_DEV_KEY, undefined);
  assert.equal(imp.env.SMS_RULES_DEV_KEY, undefined);
});

test('a second run that has nothing new to mint is a clean success', () => {
  const h = harness({ importResult: { rulesInserted: 0, bundlesMinted: [] } });
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: makeKey(), SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  assert.equal(release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], h.deps(env)), 0);
  assert.ok(h.lines.some((l) => /nothing new to mint/.test(l)));
});

test('partially minted cohorts and failed imports are errors', () => {
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: makeKey(), SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  const partial = harness({ importResult: { rulesInserted: 2, bundlesMinted: [{ bundleVersion: 1, cohort: 'all' }] } });
  assert.equal(release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], partial.deps(env)), 1);
  assert.ok(partial.lines.some((l) => /\[verify\] FAILED/.test(l)));
  const failed = harness({ importStatus: 1 });
  assert.equal(release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], failed.deps(env)), 1);
  assert.ok(failed.lines.some((l) => /\[import\] FAILED/.test(l)));
});

test('the signing key and the throwaway seed never reach the output, even when a child echoes them', () => {
  const key = makeKey();
  const body = key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const h = harness({ goldenStatus: 1, leak: body });
  let seen;
  const run = (command, args, opts) => {
    if (args[2] === 'sign-dev') seen = opts.env.SMS_RULES_DEV_KEY;
    return h.deps({}).run(command, args, opts);
  };
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: key, SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  const lines = [];
  release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], { env, run, log: (l) => lines.push(l) });
  const all = lines.join('\n');
  assert.ok(seen && seen.length >= 40, 'the throwaway seed was passed to sign-dev');
  assert.ok(!all.includes(body));
  assert.ok(!all.includes(seen));
  for (const part of key.split('\n').filter((l) => l.length > 16 && !l.startsWith('-----'))) assert.ok(!all.includes(part));
  assert.ok(all.includes('[redacted]'));
  // Echoed from an import failure too.
  const h2 = harness({ importStatus: 1, leak: body });
  const lines2 = [];
  release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], { env, run: h2.deps({}).run, log: (l) => lines2.push(l) });
  assert.ok(!lines2.join('\n').includes(body));
  assert.ok(secretsFrom(env).length >= 2);
});

test('the key is never placed on a command line', () => {
  const key = makeKey();
  const h = harness();
  const env = { PATH: process.env.PATH, SMS_RULES_SIGNING_KEY: key, SMS_RULES_KEY_ID: 'k1', ADMIN_API_DATABASE_URL: 'postgres://x/y' };
  release(['--work-dir', workDir(), '--apply', '--admin-id', ADMIN], h.deps(env));
  const body = key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  for (const c of h.calls) assert.ok(!c.args.join(' ').includes(body));
});
