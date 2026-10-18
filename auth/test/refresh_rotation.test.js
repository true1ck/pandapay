const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost/unused';
process.env.JWT_ACCESS_SECRET = 'test-access-secret';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret';

const db = require('../src/db');
const service = require('../src/services/tokenService');
const requestId = 'c13d2edf-9e05-4002-a1d1-b5630a0832aa';

function database() {
  let rows = [];
  let snapshot;
  let failInsert = false;
  const commands = [];
  async function query(sql, args = []) {
    commands.push(sql.trim().split(/\s+/).slice(0, 3).join(' '));
    if (sql === 'BEGIN') { snapshot = structuredClone(rows); return {}; }
    if (sql === 'COMMIT') { snapshot = null; return {}; }
    if (sql === 'ROLLBACK') { rows = snapshot; snapshot = null; return {}; }
    if (sql.includes('INSERT INTO refresh_tokens')) {
      if (failInsert) throw new Error('insert failed');
      rows.push({ id: String(rows.length + 1), user_id: args[0], device_id: args[1],
        token_id: args[2], token_hash: args[3], expires_at: args[6],
        rotated_from_id: args[7], last_used_at: new Date(), revoked_at: null });
      return { rows: [] };
    }
    if (sql.startsWith('SELECT *')) {
      return { rows: rows.filter(row => sql.includes('WHERE id =') ? row.id === args[0] :
        row.token_id === args[0] && (!sql.includes('rotated_from_id =') || row.rotated_from_id === args[1]))
        .map(row => ({ ...row })) };
    }
    if (sql.includes('SET last_used_at')) return { rows: [] };
    if (sql.includes('UPDATE refresh_tokens')) {
      for (const row of rows) {
        if (sql.includes('WHERE id =') ? row.id === args[0] : row.user_id === args[0] && row.device_id === args[1]) {
          row.revoked_at = new Date();
        }
      }
      return { rows: [] };
    }
    throw new Error(`Unexpected SQL: ${sql}`);
  }
  db.query = query;
  Object.defineProperty(db, 'pool', { configurable: true, get: () => ({
    connect: async () => ({ query, release() {} }),
  }) });
  return { get rows() { return rows; }, commands, fail() { failInsert = true; } };
}

test('lost rotation response and process retry recover exactly the committed successor', async () => {
  const memory = database();
  const original = await service.issueRefreshToken({ userId: 'user-1', deviceId: 'phone-1' });
  const verified = await service.verifyRefreshToken(original, { requestId });
  const first = await service.rotateRefreshToken({ tokenRow: verified.row, requestId });
  const recovered = await service.verifyRefreshToken(original, { requestId });
  assert.equal(recovered.recovered, first);
  assert.equal(await service.rotateRefreshToken({ tokenRow: recovered.row, requestId }), first);
  // A second caller that verified before the first committed also gets the same token.
  assert.equal(await service.rotateRefreshToken({ tokenRow: verified.row, requestId }), first);
  assert.equal(memory.rows.length, 2);
  assert.equal(jwt.verify(first, process.env.JWT_REFRESH_SECRET).sub, 'user-1');
});

test('failed successor insert rolls back without consuming the old credential', async () => {
  const memory = database();
  const original = await service.issueRefreshToken({ userId: 'user-1', deviceId: 'phone-1' });
  const verified = await service.verifyRefreshToken(original);
  memory.fail();
  await assert.rejects(service.rotateRefreshToken({ tokenRow: verified.row, requestId }), /insert failed/);
  assert.equal(memory.rows.length, 1);
  assert.equal(memory.rows[0].revoked_at, null);
  assert.ok(memory.commands.includes('ROLLBACK'));
  assert.ok(await service.verifyRefreshToken(original));
});

test('different request IDs cannot recover a consumed credential', async () => {
  database();
  const original = await service.issueRefreshToken({ userId: 'user-1', deviceId: 'phone-1' });
  const verified = await service.verifyRefreshToken(original);
  const child = await service.rotateRefreshToken({ tokenRow: verified.row, requestId });
  const result = await service.verifyRefreshToken(original, {
    requestId: '9343df8c-37d0-494f-8063-241d0dc0cdd3',
  });
  assert.equal(result.reuseDetected, true);
  assert.equal((await service.verifyRefreshToken(child)).reuseDetected, true);
});

test('logout revokes recovery as well as the current refresh token', async () => {
  database();
  const original = await service.issueRefreshToken({ userId: 'user-1', deviceId: 'phone-1' });
  const verified = await service.verifyRefreshToken(original);
  await service.rotateRefreshToken({ tokenRow: verified.row, requestId });
  await service.revokeRefreshToken('user-1', 'phone-1');
  assert.equal((await service.verifyRefreshToken(original, { requestId })).reuseDetected, true);
});

test('legacy callers still rotate, without allowing reuse recovery', async () => {
  database();
  const original = await service.issueRefreshToken({ userId: 'user-1', deviceId: 'phone-1' });
  const verified = await service.verifyRefreshToken(original);
  const child = await service.rotateRefreshToken({ tokenRow: verified.row });
  assert.ok(await service.verifyRefreshToken(child));
  assert.equal((await service.verifyRefreshToken(original)).reuseDetected, true);
});

test('refresh request identity must be a UUID v4 when provided', () => {
  const { validateRefreshTokenBody } = require('../src/middleware/validation');
  for (const id of [null, {}, 'invalid', 'x'.repeat(2001)]) {
    let status;
    validateRefreshTokenBody({ body: { refresh_token: 'token', refresh_request_id: id } }, {
      status(value) { status = value; return this; }, json() {},
    }, () => assert.fail('invalid identity accepted'));
    assert.equal(status, 400);
  }
  let accepted = false;
  validateRefreshTokenBody({ body: { refresh_token: 'token', refresh_request_id: requestId } }, {}, () => accepted = true);
  assert.equal(accepted, true);
});
