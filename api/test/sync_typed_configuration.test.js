'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('actual runtime config keeps typed sync on unless explicitly false', () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'sync-config-'));
  try {
    for (const value of [undefined, '', 'false', 'FALSE', '0', 'off', ' Off ', '1', 'TRUE', 'true', 'no']) {
      const env = {
        NODE_ENV: 'test',
        DOTENV_CONFIG_QUIET: 'true',
        API_DATABASE_URL: 'postgresql://fixture:fixture@127.0.0.1/synthetic_config_only',
        JWT_ACCESS_SECRET: 'synthetic-config-only',
      };
      if (value !== undefined) env.SYNC_TYPED_WRITES_ENABLED = value;
      const output = execFileSync(process.execPath, ['-e',
        'process.stdout.write(JSON.stringify(require(process.argv[1]).syncTypedWritesEnabled))',
        require.resolve('../src/config'),
      ], { cwd, env, encoding: 'utf8', timeout: 5000 });
      const off = ['false', '0', 'off'].includes(String(value ?? '').trim().toLowerCase());
      assert.equal(JSON.parse(output), !off);
    }
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});
