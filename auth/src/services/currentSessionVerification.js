'use strict';

const db = require('../db');
const { verifyAccessToken } = require('./accessTokenVerification');
const { decryptPhoneNumber } = require('../utils/fieldEncryption');
const { phoneGateRequiredFor } = require('../utils/phoneGate');

async function verifyCurrentSession(token, executor = db) {
  const payload = verifyAccessToken(token);
  const base = {
    token_valid: true,
    subject: payload.sub,
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

  let rows;
  try {
    const result = await executor.query(
      `SELECT id, email, phone_number, is_email_verified, is_phone_verified, claimed_phone_enc,
              is_active, deleted, created_at, COALESCE(token_version, 1) AS token_version
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
  // A typed (unverified) phone is reported apart from verified contacts, so
  // nothing can mistake it for proof. The gate is "an account must have a phone"
  // when REQUIRE_PHONE_AT_SIGNUP is on; a verified phone also satisfies it.
  const claimedPhone = active && Boolean(user?.claimed_phone_enc);
  const verifiedPhone = active && Boolean(user?.phone_number) && user.is_phone_verified === true;
  // The number we hold for this account, whether or not it was ever confirmed by a code.
  // Split uses it only to find a friend by the number you already have for them.
  let phoneOnFile = null;
  if (active) {
    try {
      if (user?.phone_number) phoneOnFile = decryptPhoneNumber(user.phone_number);
      else if (user?.claimed_phone_enc) phoneOnFile = decryptPhoneNumber(user.claimed_phone_enc);
    } catch (_) {
      phoneOnFile = null;
    }
  }

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
    claimed_contacts: {
      phone: {
        claimed: claimedPhone,
        value: claimedPhone ? decryptPhoneNumber(user.claimed_phone_enc) : null,
      },
    },
    phone_on_file: { present: typeof phoneOnFile === 'string' && phoneOnFile !== '', value: phoneOnFile || null },
    phone_gate: {
      required: phoneGateRequiredFor(user?.created_at),
      satisfied: claimedPhone || verifiedPhone,
    },
  };
}

module.exports = { verifyCurrentSession };
