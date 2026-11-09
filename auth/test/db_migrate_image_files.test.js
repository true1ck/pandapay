const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// The db-migrate image (db/migrate/Dockerfile) ships only some of auth/. deploy.sh runs
// auditContactUniqueness.js in it before taking anything down, and the support tools run
// from it. A script that imports a file the image lacks crashes there, and for the audit
// that stops every deploy. This builds the image's file set from the Dockerfile's COPY
// lines and loads each script from it.

const root = path.join(__dirname, '..', '..');
const dockerfile = fs.readFileSync(path.join(root, 'db/migrate/Dockerfile'), 'utf8');

function copyLines(text) {
  const joined = text.replace(/\\\n/g, ' ');
  return joined.split('\n').map(line => line.trim()).filter(line => /^COPY\s/.test(line))
    .map(line => line.replace(/^COPY\s+/, '').split(/\s+/));
}

function buildImage(target) {
  for (const parts of copyLines(dockerfile)) {
    const dest = parts.pop();
    for (const source of parts.filter(part => part.startsWith('auth/'))) {
      const from = path.join(root, source);
      const rel = dest.replace(/^\.\//, '');
      const to = dest.endsWith('/') ? path.join(target, rel, path.basename(source)) : path.join(target, rel);
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.cpSync(from, to, { recursive: true });
    }
  }
}

const SCRIPTS = ['auditContactUniqueness', 'recovery_support', 'account_clusters', 'migrate', 'runtimePermissions'];

test('every script that runs from the db-migrate image loads with only the files that image copies', () => {
  const image = fs.mkdtempSync(path.join(os.tmpdir(), 'db-migrate-image-'));
  try {
    buildImage(image);
    fs.symlinkSync(path.join(root, 'auth/node_modules'), path.join(image, 'node_modules'));
    for (const name of SCRIPTS) {
      const run = spawnSync(process.execPath, ['-e', `require('./scripts/${name}.js')`], { cwd: image, encoding: 'utf8', env: { PATH: process.env.PATH, NODE_ENV: 'test' } });
      assert.equal(run.status, 0, `${name} does not load in the db-migrate image:\n${run.stderr.split('\n').slice(0, 4).join('\n')}`);
    }
  } finally {
    fs.rmSync(image, { recursive: true, force: true });
  }
});

test('the image copies the scripts directory and the migrations, so new scripts and migrations need no Dockerfile change', () => {
  const sources = copyLines(dockerfile).flat();
  assert.ok(sources.includes('auth/scripts'));
  assert.ok(sources.includes('auth/db/migrations'));
});

// The build context is an allow-list: `**` excludes everything, then `!path` lines let
// files in, and every parent directory must be let in as well. A file the Dockerfile
// copies but the list omits makes the image build fail, before the deploy's downtime.
test('every file the Dockerfile copies from auth/ is let into the build context', () => {
  const ignore = fs.readFileSync(path.join(root, 'db/migrate/Dockerfile.dockerignore'), 'utf8')
    .split('\n').map(line => line.trim()).filter(line => line.startsWith('!')).map(line => line.slice(1));
  const allowed = target => ignore.some(entry => entry === target || entry === `${target}/` ||
    (entry.endsWith('/**') && target.startsWith(entry.slice(0, -2))));
  const missing = [];
  for (const parts of copyLines(dockerfile)) {
    parts.pop();
    for (const source of parts.filter(part => part.startsWith('auth/'))) {
      const segments = source.split('/');
      for (let i = 1; i <= segments.length; i++) {
        const prefix = segments.slice(0, i).join('/');
        if (!allowed(prefix)) { missing.push(prefix); break; }
      }
    }
  }
  assert.deepEqual(missing, [], `not allowed by db/migrate/Dockerfile.dockerignore: ${missing.join(', ')}`);
});
