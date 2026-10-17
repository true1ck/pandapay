const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const modulePath = path.resolve(__dirname, '..', 'src', 'services', 'jwtKeys.js');

function loadInChild(overrides) {
  const env = { ...process.env };
  for (const [name, value] of Object.entries(overrides)) {
    if (value === undefined) delete env[name];
    else env[name] = value;
  }

  const script = `
    const keys = require(${JSON.stringify(modulePath)});
    process.stdout.write(JSON.stringify({
      active: keys.getActiveKey(),
      all: keys.getAllKeys(),
    }));
  `;
  return spawnSync(process.execPath, ['-e', script], {
    env,
    encoding: 'utf8',
  });
}

test('rotation configuration takes precedence over the legacy access secret', () => {
  const result = loadInChild({
    JWT_KEYS_JSON: JSON.stringify({ current: 'current-secret', previous: 'previous-secret' }),
    JWT_ACTIVE_KEY_ID: 'current',
    JWT_ACCESS_SECRET: 'stale-legacy-secret',
  });

  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.deepEqual(parsed.active, { keyId: 'current', secret: 'current-secret' });
  assert.deepEqual(parsed.all, {
    current: 'current-secret',
    previous: 'previous-secret',
  });
});

test('malformed rotation configuration fails closed', () => {
  const result = loadInChild({
    JWT_KEYS_JSON: '{not-json',
    JWT_ACCESS_SECRET: 'legacy-secret',
  });

  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /Invalid JWT_KEYS_JSON/);
});

test('an unknown active key id fails closed', () => {
  const result = loadInChild({
    JWT_KEYS_JSON: JSON.stringify({ current: 'current-secret' }),
    JWT_ACTIVE_KEY_ID: 'missing',
    JWT_ACCESS_SECRET: 'legacy-secret',
  });

  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /JWT_ACTIVE_KEY_ID missing/);
});
