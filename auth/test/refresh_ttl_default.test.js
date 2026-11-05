const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const configPath = path.resolve(__dirname, '..', 'src', 'config.js');

function refreshTtl(overrides = {}) {
  const env = {
    ...process.env,
    JWT_ACCESS_SECRET: 'test-access-secret-test-access-secret',
    JWT_REFRESH_SECRET: 'test-refresh-secret-test-refresh-secret',
    DATABASE_URL: 'postgres://x:y@127.0.0.1:1/z',
    ...overrides,
  };
  if (overrides.JWT_REFRESH_TTL === undefined) delete env.JWT_REFRESH_TTL;
  const result = spawnSync(
    process.execPath,
    ['-e', `process.stdout.write(require(${JSON.stringify(configPath)}).jwtRefreshTtl)`],
    { env, encoding: 'utf8', cwd: path.resolve(__dirname, '..', 'test') },
  );
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split('\n').pop();
}

test('refresh tokens last 90 days unless the environment says otherwise', () => {
  assert.equal(refreshTtl(), '90d');
});

test('JWT_REFRESH_TTL still overrides the default', () => {
  assert.equal(refreshTtl({ JWT_REFRESH_TTL: '30d' }), '30d');
});
