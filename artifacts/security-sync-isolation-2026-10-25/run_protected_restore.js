'use strict';

// Uses the already-authorized local recovery set and retained original keys.
// No source URL is loaded; the reviewed helper owns/removes its RAM-backed
// loopback container. Only count/status summaries leave the private root.
const fs = require('node:fs'), path = require('node:path'), { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const recovery = '/Users/chandresh_kerkar/Library/Application Support/PandaPay/Recovery';
const output = path.join(__dirname, 'protected-restore-summary.json');
const { sourceSnapshot } = require(path.join(root, 'db/scripts/release_security_check'));
const retainedNames = ['ENCRYPTION_ENABLED', 'ENCRYPTION_KEY', 'PHONE_LOOKUP_HMAC_KEY', 'IMAP_ENCRYPTION_KEY',
  'REFERRAL_IDENTITY_HMAC_KEY', 'REFERRAL_IDENTITY_HMAC_KEY_VERSION', 'REFERRAL_PREVIEW_SECRET', 'ENGAGEMENT_RECEIPT_SECRET', 'ENCRYPTION_READ_KEYS_JSON'];
function main() {
  const reviewOnly = process.argv.includes('--review-only');
  const before = sourceSnapshot(root);
  const env = Object.fromEntries(['PATH', 'HOME', 'TMPDIR'].filter(name => process.env[name]).map(name => [name, process.env[name]]));
  env.PATH = [path.dirname(process.execPath), '/opt/homebrew/opt/postgresql@18/bin', '/opt/homebrew/bin', path.join(recovery, 'tools'), env.PATH || ''].join(path.delimiter);
  env.NODE_ENV = 'test'; env.DB_SSL = 'false'; env.DOTENV_CONFIG_QUIET = 'true';
  const keys = require(path.join(root, 'auth/node_modules/dotenv')).parse(fs.readFileSync(path.join(recovery, 'keys/application-keys.env')));
  for (const name of retainedNames) if (keys[name] !== undefined) env[name] = keys[name];
  if (!env.ENCRYPTION_KEY || !env.PHONE_LOOKUP_HMAC_KEY) throw new Error('Retained recovery keys unavailable');
  // Only extract role names from the saved encrypted deployment configuration;
  // never pass its live URLs/provider credentials to a recovery subprocess.
  let roleMapping = 'not_requested';
  if (reviewOnly) {
    const deployed = spawnSync(path.join(recovery, 'tools/age'), ['-d', '-i', path.join(recovery, 'keys/recovery-identity.txt'), path.join(recovery, 'keys/deployed-server.env.age')], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
    if (deployed.status !== 0) throw new Error('Saved role mapping unavailable');
    const settings = require(path.join(root, 'auth/node_modules/dotenv')).parse(deployed.stdout);
    const product = settings.API_DATABASE_URL || settings.DATABASE_URL, auth = settings.AUTH_DATABASE_URL;
    const role = raw => { const username = decodeURIComponent(new URL(raw).username).split('.')[0]; if (!/^[A-Za-z_][A-Za-z0-9_]{0,62}$/.test(username)) throw new Error('Unreviewed role name'); return username; };
    env.RESTORE_PRODUCT_RUNTIME_ROLE = role(product);
    if (auth) { env.RESTORE_AUTH_RUNTIME_ROLE = role(auth); roleMapping = 'saved_explicit_product_and_auth_urls'; }
    else { env.RESTORE_AUTH_RUNTIME_ROLE = 'auth_runtime'; roleMapping = 'product_saved_auth_proposed_unconfirmed'; }
  }
  const args = [path.join(root, 'db/scripts/rehearse_local_backup.py'), recovery, '--image', 'supabase/postgres:17.6.1.136'];
  if (reviewOnly) args.push('--privilege-review');
  else args.push('--contact-upgrade', '--product-baseline', path.join(recovery, 'baseline-review/product-source-v2-recovery-v5.json'), '--dump-image', 'pandapay-security-backup-test');
  const result = spawnSync('python3', args, { cwd: root, env, encoding: 'utf8', timeout: 900000, maxBuffer: 4 * 1024 * 1024 });
  const raw = Buffer.from((result.stdout || '') + '\n' + (result.stderr || ''));
  const encrypted = spawnSync(path.join(recovery, 'tools/age'), ['-R', path.join(recovery, 'public-recipients.txt')],
    { input: raw, env: { PATH: env.PATH, HOME: env.HOME }, timeout: 30000, maxBuffer: 5 * 1024 * 1024 });
  if (encrypted.status !== 0 || !encrypted.stdout?.length) throw new Error('Protected diagnostic encryption failed');
  const log = path.join(recovery, 'status/sync-isolation-upgrade.log.age'), pending = log + '.pending';
  fs.writeFileSync(pending, encrypted.stdout, { flag: 'wx', mode: 0o600 }); fs.renameSync(pending, log);
  const after = sourceSnapshot(root);
  const safe = (result.stdout || '').split(/\r?\n/).filter(line => /^(?:Disposable memory-backed recovery container started\.|Independent recovery PostgreSQL is ready; applying reviewed roles and restore checks\.|Actual local backup restored and verified; disposable RAM-backed recovery cluster removed\.|PRODUCT_UPGRADE_STATUS=passed tables_preserved=\d+ ledger_entries_verified=\d+ runtime_roles_preserved=\d+ replay=passed|CONTACT_UPGRADE_STATUS=passed accounts_preserved=\d+ phone_claims_archived=\d+ preserved_auth_tables=\d+ replay=passed|Recovery keys, phone indexes and product\/auth identities verified; profiles=\d+)$/.test(line));
  const reviewSummary = /^RESTORED_PRIVILEGE_REVIEW=complete product_blocking=(\d+) auth_blocking=(\d+) history_unknown=(\d+) history_mismatched=(\d+)$/m.exec(result.stdout || '');
  let protectedSummary = null;
  if (reviewOnly && result.status === 0) {
    // The restore hook keeps detailed review output private. Read its encrypted
    // report in memory and export only code counts, never ACLs or account data.
    const reviewed = spawnSync(path.join(recovery, 'tools/age'), ['-d', '-i', path.join(recovery, 'keys/recovery-identity.txt'), path.join(recovery, 'status/privilege-review.json.age')], { encoding: 'utf8', maxBuffer: 17 * 1024 * 1024 });
    if (reviewed.status !== 0) throw new Error('Encrypted review summary unavailable');
    const review = JSON.parse(reviewed.stdout);
    const scopes = Object.fromEntries(Object.entries(review.reports).map(([scope, report]) => [scope, {
      complete: report.complete, strict_pass: report.strict_pass, blocking: report.summary.blocking,
      codes: Object.fromEntries([...new Set(report.findings.map(finding => finding.code))].sort().map(code => [code, report.findings.filter(finding => finding.code === code).length])),
    }]));
    protectedSummary = { format: 'pandapay-restored-privilege-review-summary-v1', source: 'existing-local-encrypted-backup',
      candidate_sha256: before.candidate_sha256, read_only: true, live_connection_opened: false, role_mapping: roleMapping, scopes,
      history: { entries: review.product_history.entries, unknown: review.product_history.unknown.length,
        mismatched: review.product_history.mismatched.length, missing_checksum: review.product_history.missingChecksum.length,
        duplicate: review.product_history.duplicate.length }, encrypted_details: 'status/privilege-review.json.age', production_accepted: false };
    fs.writeFileSync(path.join(__dirname, 'protected-privilege-findings-summary.json'), JSON.stringify(protectedSummary, null, 2) + '\n');
  }
  const summary = { format: 'pandapay-protected-restore-upgrade-attempt-v1', generated_at: new Date().toISOString(),
    candidate_sha256: before.candidate_sha256, candidate_unchanged: before.candidate_sha256 === after.candidate_sha256,
    exit_code: result.status, timed_out: result.error?.code === 'ETIMEDOUT', safe_messages: safe,
    existing_local_backup_only: true, live_connection_opened: false, live_mutations: false,
    retained_keys_used_privately: true, private_encrypted_diagnostic: 'status/sync-isolation-upgrade.log.age',
    protected_backup_source_version: 'historical existing local encrypted set; not a new live snapshot',
    role_mapping: roleMapping, review_only: reviewOnly,
    privilege_review: protectedSummary || (reviewSummary ? { product_blocking: +reviewSummary[1], auth_blocking: +reviewSummary[2], history_unknown: +reviewSummary[3], history_mismatched: +reviewSummary[4] } : null),
    production_accepted: false };
  fs.writeFileSync(reviewOnly ? path.join(__dirname, 'protected-privilege-summary.json') : output, JSON.stringify(summary, null, 2) + '\n'); console.log(JSON.stringify(summary));
  if (result.status !== 0 || !summary.candidate_unchanged) process.exitCode = 1;
}
try { main(); } catch (_) { console.error('Protected local restore review failed; no key, connection or customer values are emitted.'); process.exitCode = 1; }
