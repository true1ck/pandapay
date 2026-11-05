'use strict';

// Console controls for the learning loop: admin-adjustable settings and
// per-user limit overrides. Reads need learning.read; every change needs
// learning.publish with fresh MFA, a written reason, and writes admin_audit_log.
const { HttpError } = require('./rules_admin_route');
const {
  SETTINGS, USER_LIMIT_KEYS, SettingError, validateSetting, listSettings, storedSettings, clearSettingsCache,
} = require('./settings');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_OVERRIDE_DAYS = 90;
const UPDATED_AT = `to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

function reasonOf(body) {
  const reason = typeof body?.reason === 'string' ? body.reason.trim() : '';
  if (reason.length < 3 || reason.length > 500) throw new HttpError(400, 'reason_required');
  return reason;
}

function audit(client, adminId, action, entity, before, after, reason) {
  return client.query(
    'INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason) VALUES ($1,$2,$3,NULL,$4,$5,$6)',
    [adminId, action, entity,
      before == null ? null : JSON.stringify(before), after == null ? null : JSON.stringify(after), reason],
  );
}

async function putSetting(client, { adminId, key, body, env }) {
  if (!Object.hasOwn(SETTINGS, key)) throw new HttpError(404, 'setting_unknown');
  const reason = reasonOf(body);
  const value = validateSetting(key, body?.value, env);
  const expected = body?.expectedUpdatedAt ?? null;
  if (expected !== null && typeof expected !== 'string') throw new HttpError(400, 'expected_updated_at_invalid');
  const current = (await client.query(
    `SELECT value, ${UPDATED_AT} AS "updatedAt" FROM sms_v2_settings WHERE key = $1 FOR UPDATE`, [key])).rows[0];
  // Two admins editing one setting: the second saw an older version.
  if ((current?.updatedAt ?? null) !== expected) throw new HttpError(409, 'setting_stale');
  await client.query(
    `INSERT INTO sms_v2_settings (key, value, updated_by, reason) VALUES ($1, $2::jsonb, $3, $4)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by,
       reason = EXCLUDED.reason, updated_at = clock_timestamp()`,
    [key, JSON.stringify(value), adminId, reason]);
  await audit(client, adminId, 'sms_v2_setting', 'sms_v2_setting',
    { key, value: current ? current.value : SETTINGS[key].default }, { key, value }, reason);
  clearSettingsCache();
  return listSettings(await storedSettings(client), env).find((row) => row.key === key);
}

async function listUserLimits(client) {
  const rows = (await client.query(
    `SELECT profile_id AS "profileId", key, value, expires_at AS "expiresAt", created_at AS "createdAt",
            updated_by AS "updatedBy", reason, (expires_at > now()) AS active
       FROM sms_v2_user_limits ORDER BY expires_at DESC, profile_id, key LIMIT 200`)).rows;
  return { limits: rows };
}

async function putUserLimit(client, { adminId, profileId, key, body, env, now = new Date() }) {
  if (!UUID.test(profileId)) throw new HttpError(400, 'profile_id_invalid');
  if (!USER_LIMIT_KEYS.includes(key)) throw new HttpError(404, 'limit_key_unknown');
  const reason = reasonOf(body);
  const value = validateSetting(key, body?.value, env);
  const expiresAt = new Date(body?.expiresAt);
  if (typeof body?.expiresAt !== 'string' || Number.isNaN(expiresAt.getTime()) ||
      expiresAt <= now || expiresAt > new Date(now.getTime() + MAX_OVERRIDE_DAYS * 86400000 - 60000)) {
    throw new HttpError(422, 'limit_expiry_invalid');
  }
  const before = (await client.query(
    'SELECT value, expires_at AS "expiresAt" FROM sms_v2_user_limits WHERE profile_id = $1 AND key = $2', [profileId, key])).rows[0] || null;
  try {
    await client.query(
      `INSERT INTO sms_v2_user_limits (profile_id, key, value, expires_at, updated_by, reason)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (profile_id, key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at,
         created_at = clock_timestamp(), updated_by = EXCLUDED.updated_by, reason = EXCLUDED.reason`,
      [profileId, key, value, expiresAt.toISOString(), adminId, reason]);
  } catch (error) {
    if (error.code === '23503') throw new HttpError(404, 'profile_not_found');
    if (error.code === '23514') throw new HttpError(422, 'limit_expiry_invalid');
    throw error;
  }
  await audit(client, adminId, 'sms_v2_user_limit', 'sms_v2_user_limit',
    before && { profileId, key, ...before }, { profileId, key, value, expiresAt: expiresAt.toISOString() }, reason);
  return { limit: { profileId, key, value, expiresAt: expiresAt.toISOString() } };
}

async function deleteUserLimit(client, { adminId, profileId, key, body }) {
  if (!UUID.test(profileId)) throw new HttpError(400, 'profile_id_invalid');
  if (!USER_LIMIT_KEYS.includes(key)) throw new HttpError(404, 'limit_key_unknown');
  const reason = reasonOf(body);
  const removed = (await client.query(
    'DELETE FROM sms_v2_user_limits WHERE profile_id = $1 AND key = $2 RETURNING value, expires_at AS "expiresAt"', [profileId, key])).rows[0];
  if (!removed) throw new HttpError(404, 'limit_not_found');
  await audit(client, adminId, 'sms_v2_user_limit', 'sms_v2_user_limit', { profileId, key, ...removed }, null, reason);
  return { deleted: true };
}

function registerPrivateSettingsRoutes(api, deps = {}) {
  const env = deps.env || process.env;
  const register = (method, path, operation) =>
    api.route(method, path, async (req, res, ctx) => {
      try {
        return res.json(await operation(req, ctx));
      } catch (error) {
        if (error instanceof HttpError) return res.status(error.status).json({ error: error.code });
        if (error instanceof SettingError) return res.status(422).json({ error: 'setting_invalid', key: error.key });
        if (error.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({ error: 'admin_permission_required' });
        console.error('sms_v2 settings admin failed', error.code || error.name);
        return res.status(500).json({ error: 'settings_unavailable' });
      }
    });

  register('GET', '/admin/sms/v2/settings', (_req, ctx) =>
    ctx.withAdminClient(async (client) => ({ settings: listSettings(await storedSettings(client), env) })));
  register('PUT', '/admin/sms/v2/settings/:key', (req, ctx) =>
    ctx.withAdminClient(async (client) => ({
      setting: await putSetting(client, { adminId: req.admin.userId, key: req.params.key, body: req.body, env }),
    })));
  register('GET', '/admin/sms/v2/user-limits', (_req, ctx) => ctx.withAdminClient(listUserLimits));
  register('PUT', '/admin/sms/v2/user-limits/:profileId/:key', (req, ctx) =>
    ctx.withAdminClient((client) => putUserLimit(client, {
      adminId: req.admin.userId, profileId: req.params.profileId, key: req.params.key, body: req.body, env,
      now: deps.now ? deps.now() : new Date(),
    })));
  register('DELETE', '/admin/sms/v2/user-limits/:profileId/:key', (req, ctx) =>
    ctx.withAdminClient((client) => deleteUserLimit(client, {
      adminId: req.admin.userId, profileId: req.params.profileId, key: req.params.key, body: req.body,
    })));
}

module.exports = { registerPrivateSettingsRoutes, putSetting, listUserLimits, putUserLimit, deleteUserLimit };
