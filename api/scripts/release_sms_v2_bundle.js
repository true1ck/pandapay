#!/usr/bin/env node
'use strict';
/**
 * One-command SMS v2 rule bundle release (Lane C).
 *
 *   node api/scripts/release_sms_v2_bundle.js                       # dry run (default): build, golden gate, checks
 *   node api/scripts/release_sms_v2_bundle.js --apply --admin-id <admin_users.id>
 *
 * Steps (each one stops the whole release on failure, and nothing after it runs):
 *   1. build    tools CLI `build` merges rules/sms/v2 into one canonical bundle and runs every rule example.
 *   2. gate     tools CLI `golden` scores that bundle against the golden set (profile `release` by default)
 *               and against the committed baseline. The bundle is signed with a throwaway key made for
 *               this run only, because the golden command loads signed-shape bundles.
 *   3. checks   the contract validator accepts the bundle; with --apply the signing key and key id are
 *               present and usable.
 *   4. import   with --apply only: api/scripts/import_sms_v2_rules.js stores the rules, signs the bundle with
 *               SMS_RULES_SIGNING_KEY / SMS_RULES_KEY_ID and mints it for every cohort (testers, pct5,
 *               pct25, all). Re-running with the same input changes nothing.
 *   5. verify   every cohort has a minted bundle, or the import reported nothing new to mint.
 *
 * Keys come from the environment only. They are never printed, written to disk or put on a command line;
 * output from child processes is filtered for their values before it is shown.
 * Local only: this script does not push, deploy or touch flags. The import uses ADMIN_API_DATABASE_URL.
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '../..');
const COHORTS = ['testers', 'pct5', 'pct25', 'all'];
const USAGE = 'usage: release_sms_v2_bundle.js [--apply --admin-id <uuid>] [--rules <dir>] [--work-dir <dir>] [--profile release|m1] [--baseline <report.json>]';

class ReleaseError extends Error {
  constructor(step, message, code = 1) { super(message); this.step = step; this.exitCode = code; }
}

function parseArgs(argv) {
  const opts = { apply: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') { opts.apply = true; continue; }
    if (arg === '--dry-run') { opts.apply = false; continue; }
    const value = argv[i + 1];
    if (['--admin-id', '--rules', '--work-dir', '--profile', '--baseline'].includes(arg) && value && !value.startsWith('--')) {
      opts[arg.slice(2).replace(/-([a-z])/g, (_m, c) => c.toUpperCase())] = value;
      i += 1;
      continue;
    }
    throw new ReleaseError('args', `unknown or incomplete option ${arg}\n${USAGE}`, 2);
  }
  return opts;
}

// Every secret-looking string this run holds, in the shapes it could be echoed back.
function secretsFrom(env, extra = []) {
  const out = new Set(extra.filter(Boolean));
  const raw = env.SMS_RULES_SIGNING_KEY;
  if (raw) {
    const pem = raw.replace(/\\n/g, '\n');
    out.add(raw);
    out.add(pem);
    for (const line of pem.split('\n')) if (line.length >= 16 && !line.startsWith('-----')) out.add(line.trim());
    const body = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    if (body.length >= 16) out.add(body);
  }
  return [...out].filter((s) => s.length >= 8).sort((a, b) => b.length - a.length);
}

function redactor(secrets) {
  return (text) => secrets.reduce((acc, secret) => acc.split(secret).join('[redacted]'), String(text ?? ''));
}

function defaultRun(command, args, { cwd, env }) {
  const r = spawnSync(command, args, { cwd, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return { status: r.status === null ? 1 : r.status, stdout: r.stdout || '', stderr: r.stderr || '', error: r.error };
}

function tail(text, lines = 12) {
  return String(text).trim().split('\n').slice(-lines).join('\n');
}

/**
 * @param {string[]} argv
 * @param {object} [deps] injected in tests: env, run, log, fs, repo
 * @returns {number} the process exit code
 */
function release(argv, deps = {}) {
  const env = deps.env || process.env;
  const run = deps.run || defaultRun;
  const out = deps.fs || fs;
  const repo = deps.repo || REPO;
  const logLine = deps.log || ((line) => console.log(line));
  const ephemeralSeed = crypto.randomBytes(32).toString('base64');
  const redact = redactor(secretsFrom(env, [ephemeralSeed]));
  const log = (line) => logLine(redact(line));
  const steps = [];
  const step = (name, status, detail) => { steps.push({ name, status }); log(`[${name}] ${status}${detail ? `: ${detail}` : ''}`); };

  try {
    const opts = parseArgs(argv);
    const mode = opts.apply ? 'APPLY' : 'DRY RUN';
    log(`SMS v2 bundle release (${mode})`);
    if (opts.apply && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(opts.adminId || '')) {
      throw new ReleaseError('args', `--apply needs --admin-id <admin_users.id>\n${USAGE}`, 2);
    }
    const profile = opts.profile || 'release';
    if (!['release', 'm1'].includes(profile)) throw new ReleaseError('args', '--profile must be release or m1', 2);
    // Preconditions for --apply are checked first, so a release that cannot finish never starts.
    const keyId = env.SMS_RULES_KEY_ID || '';
    let signingReady = false;
    if (env.SMS_RULES_SIGNING_KEY && keyId) {
      try {
        (deps.createSigner || require('../src/sms_v2/signer').createSigner)({ privateKeyPem: env.SMS_RULES_SIGNING_KEY.replace(/\\n/g, '\n'), keyId });
        signingReady = true;
      } catch { signingReady = false; }
    }
    if (opts.apply && !signingReady) throw new ReleaseError('preconditions', 'SMS_RULES_SIGNING_KEY and SMS_RULES_KEY_ID must be set to a usable Ed25519 key before --apply', 2);
    if (opts.apply && !env.ADMIN_API_DATABASE_URL) throw new ReleaseError('preconditions', 'ADMIN_API_DATABASE_URL is required for --apply', 2);

    const rulesDir = path.resolve(opts.rules || path.join(repo, 'rules/sms/v2'));
    const baseline = path.resolve(opts.baseline || path.join(repo, 'tools/sms_golden/reports/latest.json'));
    const workDir = path.resolve(opts.workDir || out.mkdtempSync(path.join(os.tmpdir(), 'sms-v2-release-')));
    out.mkdirSync(workDir, { recursive: true, mode: 0o700 });
    const cli = path.join(repo, 'tools/sms_rules_cli');
    const bundlePath = path.join(workDir, 'bundle.json');
    const goldenBundlePath = path.join(workDir, 'bundle.golden-signed.json');
    const goldenDir = path.join(workDir, 'golden');
    // Child processes inherit the environment, but never the production key unless they sign with it.
    const { SMS_RULES_SIGNING_KEY: _production, ...cliEnv } = env;

    // 1. build
    const build = run('dart', ['run', 'bin/sms_rules.dart', 'build', '--rules', rulesDir, '--out', bundlePath], { cwd: cli, env: cliEnv });
    if (build.status !== 0) throw new ReleaseError('build', `tools CLI build failed\n${tail(build.stderr || build.stdout)}`);
    step('build', 'ok', tail(build.stdout, 1));

    // 2. golden gate (throwaway signing key for this run only)
    const sign = run('dart', ['run', 'bin/sms_rules.dart', 'sign-dev', '--in', bundlePath, '--out', goldenBundlePath, '--key-id', 'sms-rules-release-gate'],
      { cwd: cli, env: { ...cliEnv, SMS_RULES_DEV_KEY: ephemeralSeed } });
    if (sign.status !== 0) throw new ReleaseError('gate', `could not prepare the bundle for the golden run\n${tail(sign.stderr || sign.stdout)}`);
    const golden = run('dart', ['run', 'bin/sms_rules.dart', 'golden', '--bundle', goldenBundlePath, '--profile', profile,
      '--baseline', baseline, '--require-stages', '--out', goldenDir], { cwd: cli, env: cliEnv });
    if (golden.status !== 0) {
      throw new ReleaseError('gate', `golden gate failed (profile ${profile}); nothing was imported\n${tail(golden.stdout || golden.stderr, 30)}\nreport: ${goldenDir}`);
    }
    step('golden gate', 'ok', `profile ${profile}, report ${goldenDir}/report.json`);
    out.rmSync(goldenBundlePath, { force: true });

    // 3. checks
    const bundleText = out.readFileSync(bundlePath, 'utf8');
    let bundle;
    try { bundle = JSON.parse(bundleText); } catch { throw new ReleaseError('checks', 'built bundle is not valid JSON'); }
    const { validateBundle } = deps.contracts || require('../src/sms_v2/contracts');
    const verdict = validateBundle({ ...bundle, signature: bundle.signature || { alg: 'Ed25519', keyId: 'check', value: 'AAAA' } });
    if (!verdict.ok) {
      throw new ReleaseError('checks', `bundle does not satisfy the contract: ${verdict.errors.slice(0, 5).map((e) => `${e.code}@${e.path}`).join(', ')}`);
    }
    const ruleCount = Array.isArray(bundle.rules) ? bundle.rules.length : 0;
    step('contract check', 'ok', `${ruleCount} rules, sha256 ${crypto.createHash('sha256').update(bundleText).digest('hex').slice(0, 16)}`);
    if (signingReady) step('signing key', 'ok', `key id ${keyId} (key loaded from SMS_RULES_SIGNING_KEY, not shown)`);
    else step('signing key', 'warning', 'not configured here; --apply would refuse');

    // 4 and 5. import and verify
    if (!opts.apply) {
      step('import', 'skipped', `dry run. --apply would import ${ruleCount} rules and mint ${COHORTS.join(', ')} via import_sms_v2_rules.js`);
      log(`Dry run complete. Work files: ${workDir}`);
      return 0;
    }
    const imported = run(process.execPath, [path.join(repo, 'api/scripts/import_sms_v2_rules.js'), '--input', bundlePath, '--admin-id', opts.adminId], { cwd: path.join(repo, 'api'), env });
    if (imported.status !== 0) throw new ReleaseError('import', `import failed; no further step ran\n${redact(tail(imported.stderr || imported.stdout))}`);
    let result;
    try { result = JSON.parse(tail(imported.stdout, 1)); } catch { throw new ReleaseError('import', 'import finished but its result could not be read; check the bundles on the Rules page before retrying'); }
    const minted = Array.isArray(result.bundlesMinted) ? result.bundlesMinted : [];
    step('import', 'ok', `${result.rulesInserted} rules inserted, ${minted.length} bundles minted`);
    const covered = new Set(minted.map((b) => b.cohort));
    if (minted.length === 0) step('verify', 'ok', 'nothing new to mint: the active bundles already match this content');
    else if (COHORTS.every((c) => covered.has(c))) step('verify', 'ok', minted.map((b) => `${b.cohort}=v${b.bundleVersion}`).join(' '));
    else throw new ReleaseError('verify', `bundles were minted for only ${[...covered].join(', ')}; compare with the Rules page before going on`);
    log('Release complete. Check GET /admin/sms/v2/metrics and the Rules page, then follow the runbook.');
    return 0;
  } catch (error) {
    if (error instanceof ReleaseError) {
      log(`[${error.step}] FAILED: ${error.message}`);
      log('Stopped. Nothing after this step ran.');
      return error.exitCode;
    }
    log(`[release] FAILED: ${redact(error && error.message)}`);
    return 1;
  }
}

if (require.main === module) process.exit(release(process.argv.slice(2)));

module.exports = { release, parseArgs, secretsFrom, redactor, ReleaseError, COHORTS };
