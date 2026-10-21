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

test('DB access logger uses the injected pool and redacts OTP-like parameters', async () => {
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
  await logger.loggedQuery('SELECT $1::text AS result', ['4826'], {}, executor);
  await new Promise(resolve => setImmediate(resolve));
  const auditInsert = queries.find(call => call.sql.includes('INSERT INTO db_access_log'));
  assert.ok(auditInsert);
  assert.deepEqual(JSON.parse(auditInsert.args[3]), ['[REDACTED_OTP]']);
  assert.equal(queries.some(call => call.sql.includes('SELECT $1::text AS result')), true);
});
