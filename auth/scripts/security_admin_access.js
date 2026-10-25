'use strict';

// Explicit operator action only. Never loads .env or provisions a user from
// a token role/email match. The optional dashboard stays disabled by default.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function setSecurityAdminAccess(client, { action, userId, expiresAt, now = Date.now() }) {
  if (!['grant', 'revoke'].includes(action) || !UUID.test(userId || '')) throw new Error('Invalid security-dashboard access command');
  let expiry;
  if (action === 'grant') {
    expiry = new Date(expiresAt);
    if (typeof expiresAt !== 'string' || Number.isNaN(expiry.getTime()) || expiry.getTime() <= now) {
      throw new Error('A future explicit expiry is required');
    }
  }
  await client.query('BEGIN');
  try {
    await client.query("SET LOCAL statement_timeout='5000ms'");
    if (action === 'grant') {
      const user = await client.query(
        `SELECT id FROM public.users WHERE id=$1 AND deleted=false AND is_active=true
           AND (is_email_verified=true OR is_phone_verified=true) FOR UPDATE`, [userId]);
      if (!user.rows?.length) throw new Error('An active verified existing account is required');
      await client.query(`INSERT INTO auth_private.security_admins(user_id,expires_at)
        VALUES ($1,$2) ON CONFLICT(user_id) DO UPDATE
        SET granted_at=now(),expires_at=EXCLUDED.expires_at,revoked_at=NULL`, [userId, expiry.toISOString()]);
    } else {
      // Revocation must remain available while an account is disabled,
      // deleted or unverified. Restoring the account must not restore this
      // separately revoked capability. Repeated revokes retain the first
      // revocation timestamp and do not create an access record.
      const user = await client.query('SELECT id FROM public.users WHERE id=$1 FOR UPDATE', [userId]);
      if (!user.rows?.length) throw new Error('An existing account is required');
      await client.query('UPDATE auth_private.security_admins SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL', [userId]);
    }
    await client.query('COMMIT');
    return { changed: true, action };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 2 || args.length > 3) throw new Error('Usage: security_admin_access.js grant UUID EXPIRY_ISO | revoke UUID');
  const connection = process.env.AUTH_SECURITY_ADMIN_DATABASE_URL;
  if (!connection) throw new Error('AUTH_SECURITY_ADMIN_DATABASE_URL is required');
  const { Client } = require('pg');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const resolved = resolveDatabaseTls(connection);
  const client = new Client({ connectionString: resolved.connectionString, ssl: resolved.ssl, connectionTimeoutMillis: 5000 });
  await client.connect();
  try {
    await setSecurityAdminAccess(client, { action: args[0], userId: args[1], expiresAt: args[2] });
    console.log('Security dashboard access updated');
  } finally { await client.end(); }
}
if (require.main === module) main().catch(() => { console.error('Security dashboard access update failed'); process.exitCode=1; });
module.exports = { setSecurityAdminAccess };
