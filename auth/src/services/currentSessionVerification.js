'use strict';

const db = require('../db');
const { verifyAccessToken } = require('./accessTokenVerification');
const { decryptPhoneNumber } = require('../utils/fieldEncryption');

async function verifyCurrentSession(token, executor = db) {
  const payload = verifyAccessToken(token);
  const base = {
    token_valid: true,
    subject: payload.sub,
    guest: payload.is_guest === true,
    auth_proof: {
      channel: ['phone', 'email', 'google'].includes(payload.verified_channel)
        ? payload.verified_channel
        : null,
      verified_at: Number.isInteger(payload.factor_verified_at)
        ? payload.factor_verified_at
        : null,
    },
    verified_contacts: {
      email: { verified: false, value: null },
      phone: { verified: false, value: null },
    },
  };

  // Guest sessions have no user row by design and are only revocable by
  // expiration. Their signed, 24-hour access token is the source of truth.
  if (base.guest) {
    return {
      ...base,
      valid: true,
      session: {
        active: true,
        revoked: false,
        expires_at: Number.isInteger(payload.exp) ? new Date(payload.exp * 1000).toISOString() : null,
        revocation: 'stateless_guest_expires_with_token',
      },
    };
  }

  let rows;
  try {
    const result = await executor.query(
      `SELECT id, email, phone_number, is_email_verified, is_phone_verified,
              is_active, deleted, COALESCE(token_version, 1) AS token_version
         FROM users WHERE id = $1`,
      [payload.sub],
    );
    rows = result.rows;
  } catch (err) {
    if (err && err.code === '22P02') {
      rows = [];
    } else {
      throw err;
    }
  }
  const user = rows[0];
  const tokenVersionCurrent = user && (payload.token_version || 1) === user.token_version;
  let deviceActive = true;
  if (user && payload.device_id) {
    const device = await executor.query(
      `SELECT id FROM user_devices
       WHERE user_id = $1 AND device_identifier = $2 AND is_active = TRUE LIMIT 1`,
      [payload.sub, payload.device_id],
    );
    deviceActive = device.rows.length > 0;
  }
  const active = Boolean(user && user.is_active && !user.deleted && tokenVersionCurrent && deviceActive);
  const revoked = !active;

  return {
    ...base,
    valid: active,
    session: {
      active,
      revoked,
      expires_at: Number.isInteger(payload.exp) ? new Date(payload.exp * 1000).toISOString() : null,
      revocation: !user ? 'subject_not_found'
        : user.deleted ? 'account_deleted'
          : !user.is_active ? 'account_inactive'
            : !tokenVersionCurrent ? 'token_version_changed'
              : !deviceActive ? 'device_inactive' : null,
    },
    verified_contacts: {
      email: {
        verified: Boolean(user?.email && user.is_email_verified),
        value: active && user?.email && user.is_email_verified ? user.email : null,
      },
      phone: {
        verified: Boolean(user?.phone_number && user.is_phone_verified),
        value: active && user?.phone_number && user.is_phone_verified
          ? decryptPhoneNumber(user.phone_number)
          : null,
      },
    },
  };
}

module.exports = { verifyCurrentSession };
