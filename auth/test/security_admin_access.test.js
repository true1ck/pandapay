'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { setSecurityAdminAccess } = require('../scripts/security_admin_access');
const USER = '10000000-0000-4000-8000-000000000001';
const NOW = Date.parse('2026-10-24T12:00:00Z');

function clientDouble({ exists = true, error = null, changed = true } = {}) {
  const calls = [];
  return { calls, async query(sql, params) {
    calls.push({ sql, params });
    if (sql.startsWith('SELECT id FROM public.users')) return { rows: exists ? [{ id: USER }] : [] };
    if (/^(INSERT|UPDATE)/.test(sql)) {
      if (error) throw error;
      return { rows: [], rowCount: changed ? 1 : 0 };
    }
    return { rows: [] };
  } };
}

test('dashboard grants retain the active verified existing-account lock and explicit expiry', async () => {
  const client = clientDouble();
  await setSecurityAdminAccess(client, { action: 'grant', userId: USER, expiresAt: '2026-10-24T13:00:00Z', now: NOW });
  const lock = client.calls.find(call => call.sql.startsWith('SELECT id'));
  assert.match(lock.sql,/deleted=false AND is_active=true/);
  assert.match(lock.sql,/is_email_verified=true OR is_phone_verified=true/);
  assert.match(lock.sql,/FOR UPDATE/);
  const insert = client.calls.find(call => call.sql.startsWith('INSERT'));
  assert.deepEqual(insert.params,[USER,'2026-10-24T13:00:00.000Z']);
  assert.equal(client.calls.at(-1).sql,'COMMIT');
});

test('dashboard revocation locks only the existing UUID without account-state restrictions', async () => {
  const client = clientDouble();
  await setSecurityAdminAccess(client,{action:'revoke',userId:USER});
  const lock=client.calls.find(call=>call.sql.startsWith('SELECT id'));
  assert.equal(lock.sql,'SELECT id FROM public.users WHERE id=$1 FOR UPDATE');
  assert.deepEqual(lock.params,[USER]);
  const update=client.calls.find(call=>call.sql.startsWith('UPDATE'));
  assert.match(update.sql,/WHERE user_id=\$1 AND revoked_at IS NULL$/);
  assert.deepEqual(update.params,[USER]);
  assert.equal(client.calls.some(call=>call.sql.startsWith('INSERT')),false);
  assert.equal(client.calls.at(-1).sql,'COMMIT');
});

test('repeated revocation or absent grant still commits without creating access', async () => {
  const client=clientDouble({changed:false});
  await setSecurityAdminAccess(client,{action:'revoke',userId:USER});
  assert.equal(client.calls.at(-1).sql,'COMMIT');
  assert.equal(client.calls.some(call=>call.sql.startsWith('INSERT')),false);
});

test('unknown grant/revoke subjects fail before changing capability state', async () => {
  for(const action of ['grant','revoke']) {
    const client=clientDouble({exists:false});
    await assert.rejects(setSecurityAdminAccess(client,{action,userId:USER,expiresAt:'2026-10-24T13:00:00Z',now:NOW}),/existing account is required/);
    assert.equal(client.calls.some(call=>/^(INSERT|UPDATE)/.test(call.sql)),false);
    assert.equal(client.calls.at(-1).sql,'ROLLBACK');
  }
});

test('invalid operator commands and expired grants never query the database', async () => {
  for(const command of [
    {action:'promote',userId:USER}, {action:'revoke',userId:'not-a-uuid'},
    {action:'grant',userId:USER,expiresAt:'2026-10-24T11:00:00Z',now:NOW},
  ]) {
    const client=clientDouble();
    await assert.rejects(setSecurityAdminAccess(client,command));
    assert.equal(client.calls.length,0);
  }
});

test('a capability write failure rolls back', async () => {
  const client=clientDouble({error:new Error('synthetic database error')});
  await assert.rejects(setSecurityAdminAccess(client,{action:'revoke',userId:USER}),/synthetic database error/);
  assert.equal(client.calls.at(-1).sql,'ROLLBACK');
  assert.equal(client.calls.some(call=>call.sql==='COMMIT'),false);
});
