'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createSystemStatus, parseProbes, readGitInfo } = require('../src/admin/system_status');
const { routeManifest } = require('../src/admin/route_manifest');

const HOUR = 3600_000;
const NOW = Date.parse('2026-11-05T12:00:00Z');

function fakeResponse() {
  const out = { headers: {}, body: null };
  out.set = (k, v) => { out.headers[k] = v; return out; };
  out.json = body => { out.body = body; return out; };
  return out;
}

function fakeDb(rowsByTable, { failTables = [], log = [] } = {}) {
  return async operation => operation({
    async query(sql) {
      log.push(sql.replace(/\s+/g, ' ').trim());
      if (/server_version/.test(sql)) return { rows: [{ version: '18.4 (Homebrew)' }] };
      if (/SAVEPOINT/.test(sql)) return { rows: [] };
      if (failTables.some(table => sql.includes(table))) throw new Error('permission denied');
      for (const [table, row] of Object.entries(rowsByTable)) {
        if (sql.includes(table)) return { rows: [row] };
      }
      return { rows: [{}] };
    },
  });
}

test('route is classified as a read for operations staff', () => {
  const entry = routeManifest.find(r => r.method === 'GET' && r.path === '/admin/system/status');
  assert.deepEqual({ ...entry }, { method: 'GET', path: '/admin/system/status', permission: 'operations.read', freshMfa: false });
});

test('probe config only accepts https or loopback http, without credentials', () => {
  const parsed = parseProbes([
    'api=https://api.pandapath.site/ready',
    'local=http://127.0.0.1:4000/ready',
    'lan=http://192.168.1.5/ready',
    'creds=https://user:pass@example.com/',
    'BAD KEY=https://example.com/',
    'nourl',
  ].join(','));
  assert.deepEqual(parsed.probes.map(p => p.key), ['api', 'local']);
  assert.equal(parsed.ignored, 4);
  assert.deepEqual(parseProbes('none'), { probes: [], ignored: 0 });
  assert.equal(parseProbes(Array.from({ length: 20 }, (_, i) => `p${i}=https://h${i}.test/`).join(',')).probes.length, 12);
  assert.deepEqual(parseProbes(undefined).probes.map(p => p.host), ['api.pandapath.site', 'auth.pandapath.site']);
});

test('status reports jobs the role may read, marks overdue/failed/unavailable, and never reads probe bodies', async () => {
  const fetched = [];
  const fetchImpl = async (url, init) => {
    const record = { url, redirect: init.redirect, method: init.method };
    fetched.push(record);
    if (url.includes('down')) throw Object.assign(new Error('t'), { name: 'TimeoutError' });
    return { status: 200, body: { cancel: async () => { record.cancelled = true; } } };
  };
  const handler = createSystemStatus({
    env: { ADMIN_HEALTH_PROBES: 'api=https://api.example.test/ready,auth=https://down.example.test/ready' },
    fetchImpl, repoRoot: os.tmpdir(), clock: () => NOW, startedAt: new Date(NOW - HOUR),
  });
  const log = [];
  const withAdminClient = fakeDb({
    backup_runs: { last_run_at: new Date(NOW - 30 * HOUR), last_status: 'success', last_success_at: new Date(NOW - 30 * HOUR) },
    anonymization_audit_runs: {},
  }, { failTables: ['scrape_runs'], log });

  const res = fakeResponse();
  await handler({ admin: { permissions: ['operations.read', 'admin.audit.read', 'learning.read'] } }, res, { withAdminClient });
  const body = res.body;

  assert.equal(res.headers['Cache-Control'], 'no-store');
  assert.equal(body.database.ok, true);
  assert.equal(body.database.version, 'PostgreSQL 18.4');
  const jobs = Object.fromEntries(body.jobs.map(j => [j.key, j.state]));
  assert.deepEqual(jobs, { backup: 'overdue', privacy_audit: 'never', scraper: 'unavailable' });
  assert.ok(log.includes('ROLLBACK TO SAVEPOINT system_status_job'), 'failed job query is isolated');

  assert.deepEqual(body.checks.map(c => [c.key, c.ok, c.error || null]), [['api', true, null], ['auth', false, 'timeout']]);
  assert.ok(fetched.every(f => f.redirect === 'manual' && f.method === 'GET'));
  assert.equal(fetched[0].cancelled, true);
  assert.equal(body.release.source, 'unknown');
  assert.equal(body.repository, null, 'no git checkout, no branch list');
  assert.ok(body.services.some(s => s.key === 'admin-api'));
  assert.ok(!JSON.stringify(body).includes('postgres://'));

  // A readonly role sees no audit/learning jobs, and probes are cached.
  const res2 = fakeResponse();
  await handler({ admin: { permissions: ['operations.read'] } }, res2, { withAdminClient: fakeDb({ scrape_runs: {} }) });
  assert.deepEqual(res2.body.jobs.map(j => j.key), ['scraper']);
  assert.equal(fetched.length, 2, 'second request within the cache window makes no new probes');
});

test('database failure is reported without failing the whole status', async () => {
  const handler = createSystemStatus({ env: { ADMIN_HEALTH_PROBES: 'none' }, repoRoot: os.tmpdir(), clock: () => NOW });
  const res = fakeResponse();
  await handler({ admin: { permissions: ['operations.read'] } }, res, { withAdminClient: async () => { throw new Error('down'); } });
  assert.deepEqual(res.body.database, { ok: false, error: 'unreachable' });
  assert.deepEqual(res.body.checks, []);
});

test('deploy metadata wins over the checkout, and branches come from local refs and reflogs', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'status-git-'));
  const git = path.join(root, '.git');
  const a = 'a'.repeat(40); const b = 'b'.repeat(40); const c = 'c'.repeat(40);
  fs.mkdirSync(path.join(git, 'refs/heads/feature'), { recursive: true });
  fs.mkdirSync(path.join(git, 'refs/remotes/origin'), { recursive: true });
  fs.mkdirSync(path.join(git, 'logs/refs/heads'), { recursive: true });
  fs.writeFileSync(path.join(git, 'HEAD'), 'ref: refs/heads/master\n');
  fs.writeFileSync(path.join(git, 'refs/heads/master'), `${a}\n`);
  fs.writeFileSync(path.join(git, 'refs/heads/feature/x'), `${b}\n`);
  fs.writeFileSync(path.join(git, 'refs/remotes/origin/master'), `${a}\n`);
  fs.writeFileSync(path.join(git, 'packed-refs'), `# pack-refs\n${c} refs/remotes/origin/release\n${c} refs/heads/bad..name\n`);
  fs.writeFileSync(path.join(git, 'logs/refs/heads/master'),
    `${'0'.repeat(40)} ${a} Dev <dev@example.test> 1762340000 +0530\tcommit (initial): first\n`);

  const info = readGitInfo(root);
  assert.equal(info.branch, 'master');
  assert.equal(info.commit, a);
  const byName = Object.fromEntries(info.branches.map(x => [x.name, x]));
  assert.deepEqual(Object.keys(byName).sort(), ['feature/x', 'master', 'release']);
  assert.equal(byName.master.location, 'in_sync');
  assert.equal(byName['feature/x'].location, 'local_only');
  assert.equal(byName.release.location, 'remote_only');
  assert.equal(byName.master.lastAction, 'commit (initial): first');
  assert.ok(!JSON.stringify(info).includes('dev@example.test'), 'author emails are not exposed');

  const handler = createSystemStatus({
    env: { ADMIN_HEALTH_PROBES: 'none', PANDAPAY_GIT_SHA: c, PANDAPAY_GIT_REF: 'master', PANDAPAY_DEPLOYED_AT: '2026-11-05T10:00:00Z' },
    repoRoot: root, clock: () => NOW,
  });
  const res = fakeResponse();
  await handler({ admin: { permissions: ['operations.read'] } }, res, { withAdminClient: fakeDb({}) });
  assert.deepEqual(
    { source: res.body.release.source, commit: res.body.release.commit, branch: res.body.release.branch, deployedAt: res.body.release.deployedAt },
    { source: 'deploy', commit: c, branch: 'master', deployedAt: '2026-11-05T10:00:00.000Z' },
  );
  assert.equal(res.body.repository.total, 3);
  fs.rmSync(root, { recursive: true, force: true });
});
