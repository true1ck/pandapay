const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

process.env.DB_ACCESS_LOGGING_ENABLED = 'true';
process.env.DB_ACCESS_LOG_LEVEL = 'all';

function load(relativePath) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

test('DB access logger uses only injected DML and omits every parameter value and SQL text', async () => {
  const loggerSource = fs.readFileSync(path.resolve(__dirname, '../src/middleware/dbAccessLogger.js'), 'utf8');
  assert.doesNotMatch(loggerSource, /require\(['"]\.\.\/db['"]\)/);
  const logger = load('../src/middleware/dbAccessLogger.js');
  const queries = [];
  const executor = {
    async query(sql, args = []) {
      queries.push({ sql, args });
      return { rows: [{ result: 1 }] };
    },
  };
  await logger.loggedQuery("SELECT $1::text AS result /* private@example.test */", ['4826', 'private@example.test', { token: 'short' }, 918765432100], {}, executor);
  await new Promise(resolve => setImmediate(resolve));
  const auditInsert = queries.find(call => call.sql.includes('INSERT INTO public.db_access_log'));
  assert.ok(auditInsert);
  assert.deepEqual(JSON.parse(auditInsert.args[3]), { count: 4, truncated: false });
  assert.equal(auditInsert.args[2], '[query omitted]');
  assert.doesNotMatch(JSON.stringify(auditInsert), /private@example|4826|short|918765/);
  assert.equal(queries.some(call => call.sql.includes('SELECT $1::text AS result')), true);
  assert.equal(queries.some(call => /\b(CREATE|ALTER|DROP)\b/.test(call.sql)), false);
});

test('missing audit table or permissions do not change primary query success or failure', async () => {
  const logger = load('../src/middleware/dbAccessLogger.js');
  const originalError = console.error;
  const logs = [];
  console.error = (...args) => logs.push(args);
  try {
    for (const code of ['42P01', '42501']) {
      const mainError = new Error('private primary failure');
      const executor = { async query(sql) {
        if (sql.startsWith('INSERT INTO public.db_access_log')) throw Object.assign(new Error('private audit failure'), { code });
        if (sql === 'SELECT fail') throw mainError;
        return { rows: [{ ok: true }] };
      } };
      assert.deepEqual(await logger.loggedQuery('SELECT ok', [], {}, executor), { rows: [{ ok: true }] });
      await assert.rejects(logger.loggedQuery('SELECT fail', [], {}, executor), error => error === mainError);
    }
    await new Promise(resolve => setImmediate(resolve));
    assert.doesNotMatch(JSON.stringify(logs), /private/);
  } finally { console.error = originalError; }
});

test('prepared query configuration retains its arguments and logs only the value count', async () => {
  const logger = load('../src/middleware/dbAccessLogger.js');
  const config = { text: 'SELECT $1', values: ['private@example.test'] };
  const calls = [];
  await logger.loggedQuery(config, [], {}, { async query(...args) { calls.push(args); return { rows: [] }; } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls[0][0], config);
  const audit = calls.find(([sql]) => typeof sql === 'string' && sql.startsWith('INSERT INTO public.db_access_log'));
  assert.deepEqual(JSON.parse(audit[1][3]), { count: 1, truncated: false });
  assert.equal(JSON.stringify(audit).includes('private@example.test'), false);
});
