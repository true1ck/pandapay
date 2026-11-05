'use strict';

// GET /admin/system/status: what runs where, which code it runs, and whether
// it is healthy. Read-only. Probe targets come only from operator config
// (never from the request), responses carry no secrets or connection strings,
// and each section fails on its own so one broken signal cannot hide others.

const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../../..');
const CACHE_MS = 15_000;
const PROBE_TIMEOUT_MS = 3_000;
const MAX_PROBES = 12;
const MAX_BRANCHES = 100;
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]']);
const DEFAULT_PROBES = 'api=https://api.pandapath.site/ready,auth=https://auth.pandapath.site/ready';

// What production runs (docker-compose.prod.yml + deploy/admin/compose.private.yml)
// and how each one's health is measured here. These are programs, not
// machines: production runs them as containers on one VM, and the database
// is hosted separately. `runs`: always_on | per_deploy | manual (no scheduler
// installed, off by default) | hosted | admin_only (private admin profile).
const SERVICES = Object.freeze([
  { key: 'api', runs: 'always_on', name: 'Customer API', purpose: 'Serves the mobile app: cards, transactions, SMS import, rewards.', health: 'probe' },
  { key: 'auth', runs: 'always_on', name: 'Auth service', purpose: 'Customer sign-in, OTP codes and sessions.', health: 'probe' },
  { key: 'postgres', runs: 'hosted', name: 'Product database', purpose: 'PostgreSQL holding catalogue, users and transactions.', health: 'database' },
  { key: 'rewards-worker', runs: 'always_on', name: 'Rewards worker', purpose: 'Recomputes reward, cap and milestone progress.', health: 'none' },
  { key: 'backup', runs: 'always_on', name: 'Backup', purpose: 'Encrypted database backup every night at 02:15.', health: 'job:backup' },
  { key: 'operational-maintenance', runs: 'manual', name: 'Operational maintenance', purpose: 'Bounded cleanup and reward-divergence checks. Off by default.', health: 'none' },
  { key: 'auth-retention-maintenance', runs: 'manual', name: 'Auth retention', purpose: 'Deletes expired sign-in records. Off by default.', health: 'none' },
  { key: 'db-migrate', runs: 'per_deploy', name: 'Database migrations', purpose: 'Runs once per deploy before the services start.', health: 'none' },
  { key: 'admin-gateway', runs: 'admin_only', name: 'Admin gateway', purpose: 'Admin sign-in, sessions and request filtering.', health: 'self' },
  { key: 'admin-api', runs: 'admin_only', name: 'Admin API', purpose: 'Serves this console. Private, never public.', health: 'self' },
  { key: 'sms-v2-rule-jobs', runs: 'admin_only', name: 'SMS rule job', purpose: 'Every hour: re-signs the SMS rule sets phones download (they expire after 7 days) and pauses rules with too many corrections.', health: 'job:sms_v2_rule_signing' },
  { key: 'sms-v2-template-worker', runs: 'admin_only', name: 'SMS AI drafts', purpose: 'Asks Gemini to draft a rule for each shared message layout.', health: 'job:sms_v2_ai_drafts' },
]);

// Scheduled work with a run history. expectedEveryHours drives "overdue".
const JOBS = Object.freeze([
  {
    key: 'backup', name: 'Database backup', permission: 'admin.audit.read', expectedEveryHours: 26,
    sql: `SELECT max(ran_at) AS last_run_at,
                 (array_agg(status ORDER BY ran_at DESC))[1] AS last_status,
                 max(ran_at) FILTER (WHERE status = 'success') AS last_success_at
            FROM backup_runs`,
    ok: status => status === 'success',
  },
  {
    key: 'privacy_audit', name: 'Privacy audit', permission: 'admin.audit.read', expectedEveryHours: 26,
    sql: `SELECT max(ran_at) AS last_run_at,
                 CASE (array_agg(passed ORDER BY ran_at DESC))[1]
                   WHEN true THEN 'passed' WHEN false THEN 'failed' END AS last_status,
                 max(ran_at) FILTER (WHERE passed) AS last_success_at
            FROM anonymization_audit_runs`,
    ok: status => status === 'passed',
  },
  {
    key: 'scraper', name: 'Issuer page scraper', permission: 'operations.read', expectedEveryHours: 192,
    sql: `SELECT max(started_at) AS last_run_at,
                 (array_agg(status::text ORDER BY started_at DESC NULLS LAST))[1] AS last_status,
                 max(started_at) FILTER (WHERE status::text <> 'failed') AS last_success_at
            FROM scrape_runs
           WHERE started_at IS NOT NULL`,
    ok: status => status !== 'failed',
  },
  // SMS v2 tables are readable by the private admin role only with learning.read
  // (RLS), so these two jobs are shown to roles that hold it.
  {
    // Served rule sets expire 7 days after signing; the hourly job re-signs them
    // when less than 72 hours remain. Under 48 hours left means it is not running.
    key: 'sms_v2_rule_signing', name: 'SMS rule set signing', permission: 'learning.read', expectedEveryHours: 120,
    sql: `SELECT max(served_expires_at) - interval '7 days' AS last_run_at,
                 CASE WHEN min(served_expires_at) > now() + interval '48 hours' THEN 'fresh' ELSE 'expiring' END AS last_status,
                 max(served_expires_at) - interval '7 days' AS last_success_at
            FROM sms_v2_bundles WHERE status = 'active'`,
    ok: status => status === 'fresh',
  },
  {
    // A shared layout waiting over an hour for a draft means the worker is down
    // or out of capacity.
    key: 'sms_v2_ai_drafts', name: 'SMS AI drafts', permission: 'learning.read', expectedEveryHours: 24,
    sql: `SELECT now() AS last_run_at,
                 CASE WHEN EXISTS (SELECT 1 FROM sms_v2_unknown_templates
                                    WHERE ai_status = 'queued' AND first_seen < now() - interval '1 hour')
                      THEN 'backlog' ELSE 'ok' END AS last_status,
                 (SELECT max(started_at) FROM sms_v2_template_attempts WHERE outcome = 'valid') AS last_success_at`,
    ok: status => status === 'ok',
  },
]);

function parseProbes(raw) {
  const value = raw === undefined ? DEFAULT_PROBES : String(raw).trim();
  if (value === '' || value === 'none') return { probes: [], ignored: 0 };
  const probes = [];
  let ignored = 0;
  for (const entry of value.split(',').map(s => s.trim()).filter(Boolean)) {
    const at = entry.indexOf('=');
    const key = at > 0 ? entry.slice(0, at).trim() : '';
    let url;
    try { url = new URL(entry.slice(at + 1).trim()); } catch { url = null; }
    const safe = /^[a-z0-9][a-z0-9._-]{0,47}$/.test(key) && url &&
      !url.username && !url.password && !url.hash &&
      (url.protocol === 'https:' || (url.protocol === 'http:' && LOOPBACK.has(url.hostname)));
    if (!safe || probes.length >= MAX_PROBES) { ignored++; continue; }
    probes.push({ key, url: url.toString(), host: url.host });
  }
  return { probes, ignored };
}

async function runProbe(fetchImpl, probe, now) {
  const started = now();
  try {
    const response = await fetchImpl(probe.url, {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
      headers: { accept: 'application/json' },
    });
    try { await response.body?.cancel(); } catch { /* body is never read */ }
    return { key: probe.key, host: probe.host, ok: response.status >= 200 && response.status < 300,
      httpStatus: response.status, latencyMs: Math.round(now() - started) };
  } catch (error) {
    const timedOut = error?.name === 'TimeoutError' || error?.name === 'AbortError';
    return { key: probe.key, host: probe.host, ok: false, httpStatus: null,
      latencyMs: Math.round(now() - started), error: timedOut ? 'timeout' : 'unreachable' };
  }
}

const REF_NAME = /^(?!.*\.\.)(?!\/)[A-Za-z0-9._/-]{1,200}$/;
const SHA = /^[0-9a-f]{40}$/;

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return null; }
}

/** Last reflog line: when a ref last moved and why (author email dropped). */
function lastReflog(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const length = Math.min(size, 8192);
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, size - length);
    const line = buffer.toString('utf8').trimEnd().split('\n').pop() || '';
    const match = /^[0-9a-f]{40} ([0-9a-f]{40}) .*?> (\d+) [+-]\d{4}\t?(.*)$/.exec(line);
    if (!match) return null;
    return { updatedAt: new Date(Number(match[2]) * 1000).toISOString(), message: match[3].slice(0, 140) };
  } catch { return null; } finally { if (fd !== undefined) fs.closeSync(fd); }
}

function gitDirs(root) {
  const dotGit = path.join(root, '.git');
  let stat;
  try { stat = fs.statSync(dotGit); } catch { return null; }
  let gitDir = dotGit;
  if (stat.isFile()) {
    const pointer = /^gitdir: (.+)$/m.exec(readText(dotGit) || '');
    if (!pointer) return null;
    gitDir = path.resolve(root, pointer[1].trim());
  }
  const common = readText(path.join(gitDir, 'commondir'));
  return { gitDir, commonDir: common ? path.resolve(gitDir, common.trim()) : gitDir };
}

function listRefs(commonDir, prefix) {
  const refs = new Map();
  const packed = readText(path.join(commonDir, 'packed-refs')) || '';
  for (const line of packed.split('\n')) {
    const match = /^([0-9a-f]{40}) (refs\/\S+)$/.exec(line);
    if (match && match[2].startsWith(prefix)) refs.set(match[2].slice(prefix.length), match[1]);
  }
  const walk = (dir, relative, depth) => {
    if (depth > 6 || refs.size > 2000) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const name = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(path.join(dir, entry.name), name, depth + 1);
      else if (entry.isFile()) {
        const sha = (readText(path.join(dir, entry.name)) || '').trim();
        if (SHA.test(sha)) refs.set(name, sha);
      }
    }
  };
  walk(path.join(commonDir, ...prefix.split('/').filter(Boolean)), '', 0);
  for (const name of [...refs.keys()]) if (!REF_NAME.test(name) || name === 'HEAD') refs.delete(name);
  return refs;
}

/** Branch and commit metadata from a local checkout; null inside images. */
function readGitInfo(root = REPO_ROOT) {
  const dirs = gitDirs(root);
  if (!dirs) return null;
  const head = (readText(path.join(dirs.gitDir, 'HEAD')) || '').trim();
  const local = listRefs(dirs.commonDir, 'refs/heads/');
  const remote = listRefs(dirs.commonDir, 'refs/remotes/origin/');
  const headRef = /^ref: refs\/heads\/(.+)$/.exec(head);
  const current = headRef && REF_NAME.test(headRef[1]) ? headRef[1] : null;
  const headSha = current ? local.get(current) || null : (SHA.test(head) ? head : null);

  const branches = [];
  for (const name of new Set([...local.keys(), ...remote.keys()])) {
    const localSha = local.get(name) || null;
    const remoteSha = remote.get(name) || null;
    const log = (localSha && lastReflog(path.join(dirs.commonDir, 'logs', 'refs', 'heads', ...name.split('/')))) ||
      (remoteSha && lastReflog(path.join(dirs.commonDir, 'logs', 'refs', 'remotes', 'origin', ...name.split('/'))));
    branches.push({
      name,
      commit: (localSha || remoteSha).slice(0, 12),
      current: name === current,
      location: localSha && remoteSha ? (localSha === remoteSha ? 'in_sync' : 'differs')
        : localSha ? 'local_only' : 'remote_only',
      updatedAt: log?.updatedAt || null,
      lastAction: log?.message || null,
    });
  }
  branches.sort((a, b) => (b.current - a.current) || String(b.updatedAt).localeCompare(String(a.updatedAt)));
  return {
    branch: current,
    commit: headSha,
    total: branches.length,
    branches: branches.slice(0, MAX_BRANCHES),
  };
}

function releaseInfo(env, git, startedAt) {
  const deployedSha = String(env.PANDAPAY_GIT_SHA || '').trim().toLowerCase();
  const fromDeploy = SHA.test(deployedSha);
  const ref = String(env.PANDAPAY_GIT_REF || '').trim();
  const deployedAt = Date.parse(env.PANDAPAY_DEPLOYED_AT || '');
  return {
    source: fromDeploy ? 'deploy' : git?.commit ? 'checkout' : 'unknown',
    commit: fromDeploy ? deployedSha : git?.commit || null,
    branch: fromDeploy ? (REF_NAME.test(ref) ? ref : null) : git?.branch || null,
    deployedAt: fromDeploy && Number.isFinite(deployedAt) ? new Date(deployedAt).toISOString() : null,
    startedAt: startedAt.toISOString(),
    runtime: `Node ${process.versions.node}`,
  };
}

function jobState(job, row, nowMs) {
  if (!row || !row.last_run_at) return { state: 'never' };
  const last = new Date(row.last_run_at);
  const overdue = nowMs - last.getTime() > job.expectedEveryHours * 3600_000;
  return {
    state: !job.ok(row.last_status) ? 'failed' : overdue ? 'overdue' : 'ok',
    lastRunAt: last.toISOString(),
    lastStatus: row.last_status,
    lastSuccessAt: row.last_success_at ? new Date(row.last_success_at).toISOString() : null,
  };
}

function createSystemStatus({ env = process.env, fetchImpl = fetch, repoRoot = REPO_ROOT,
  now = () => performance.now(), clock = () => Date.now(),
  startedAt = new Date(Date.now() - process.uptime() * 1000) } = {}) {
  const { probes, ignored } = parseProbes(env.ADMIN_HEALTH_PROBES);
  let cached = null;

  // Probes and git metadata do not depend on who asks; cache them briefly so
  // a refreshing console cannot multiply outbound requests.
  async function shared() {
    if (cached && clock() - cached.at < CACHE_MS) return cached.value;
    const [checks, git] = await Promise.all([
      Promise.all(probes.map(probe => runProbe(fetchImpl, probe, now))),
      Promise.resolve().then(() => { try { return readGitInfo(repoRoot); } catch { return null; } }),
    ]);
    const value = { checks, git };
    cached = { at: clock(), value };
    return value;
  }

  async function database(withAdminClient, permissions) {
    const visibleJobs = JOBS.filter(job => permissions.includes(job.permission));
    try {
      return await withAdminClient(async client => {
        const started = now();
        const info = await client.query("SELECT current_setting('server_version') AS version");
        const latencyMs = Math.round(now() - started);
        const jobs = [];
        for (const job of visibleJobs) {
          await client.query('SAVEPOINT system_status_job');
          try {
            const result = await client.query(job.sql);
            await client.query('RELEASE SAVEPOINT system_status_job');
            jobs.push({ key: job.key, name: job.name, expectedEveryHours: job.expectedEveryHours,
              ...jobState(job, result.rows[0], clock()) });
          } catch {
            await client.query('ROLLBACK TO SAVEPOINT system_status_job');
            jobs.push({ key: job.key, name: job.name, expectedEveryHours: job.expectedEveryHours, state: 'unavailable' });
          }
        }
        return { database: { ok: true, latencyMs, version: `PostgreSQL ${String(info.rows[0]?.version || '').split(' ')[0]}` }, jobs };
      });
    } catch {
      return { database: { ok: false, error: 'unreachable' }, jobs: [] };
    }
  }

  return async function systemStatus(req, res, ctx) {
    const permissions = Array.isArray(req.admin?.permissions) ? req.admin.permissions : [];
    const [{ checks, git }, db] = await Promise.all([shared(), database(ctx.withAdminClient, permissions)]);
    res.set('Cache-Control', 'no-store');
    return res.json({
      version: 1,
      generatedAt: new Date(clock()).toISOString(),
      release: releaseInfo(env, git, startedAt),
      database: db.database,
      services: SERVICES,
      checks,
      ignoredProbeEntries: ignored,
      jobs: db.jobs,
      repository: git ? { branch: git.branch, total: git.total, branches: git.branches } : null,
    });
  };
}

function registerSystemStatusRoutes(api, options) {
  api.route('GET', '/admin/system/status', createSystemStatus(options));
}

module.exports = { registerSystemStatusRoutes, createSystemStatus, parseProbes, readGitInfo, SERVICES, JOBS };
