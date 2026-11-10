'use strict';

// The phone lock. A person types a phone number; we keep it, locked to their
// account, so the same number cannot back a second live account. The number is
// not verified (no code is sent), so it is stored in its own fields and is
// never treated as proof of anything.

const { parseClaimedPhone } = require('../utils/claimedPhone');
const { phoneLookupHash } = require('../utils/encryptedPhoneSearch');
const { encryptPhoneNumber, decryptPhoneNumber } = require('../utils/fieldEncryption');
const { maskPhone } = require('../utils/recoveryContacts');
const { phoneGateRequiredFor } = require('../utils/phoneGate');

const STATUS_BY_CODE = Object.freeze({
  phone_invalid: 400,
  phone_country_unsupported: 400,
  phone_unavailable: 409,
  phone_already_set: 409,
  account_unavailable: 401,
});

class PhoneClaimError extends Error {
  constructor(code) {
    super(code);
    this.name = 'PhoneClaimError';
    this.code = code;
    this.status = STATUS_BY_CODE[code] || 400;
  }
}

function hintFor(storedPhone) {
  if (!storedPhone) return null;
  return maskPhone(decryptPhoneNumber(storedPhone));
}

/**
 * What the app needs to know: is a phone on this account, and does the lock
 * require one. A verified phone (older accounts) counts the same as a claimed one.
 */
async function getPhoneClaimStatus({ query, userId, env = process.env }) {
  const { rows } = await query(
    `SELECT claimed_phone_enc, phone_number, is_phone_verified, created_at
       FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  const user = rows[0];
  if (!user) throw new PhoneClaimError('account_unavailable');
  const claimed = Boolean(user.claimed_phone_enc);
  const verified = Boolean(user.phone_number) && user.is_phone_verified === true;
  const required = phoneGateRequiredFor(user.created_at, env);
  return {
    claimed,
    verified,
    required,
    needs_phone: required && !claimed && !verified,
    phone_hint: claimed ? hintFor(user.claimed_phone_enc) : verified ? hintFor(user.phone_number) : null,
  };
}

/**
 * Lock a typed phone number to this account. One live account per number, and a
 * person cannot change their own number afterwards (support does that).
 * `pool` needs connect(); every step runs in one transaction so two sign-ups
 * cannot both take the same number.
 */
async function claimPhone({ pool, userId, phone, countries }) {
  const parsed = parseClaimedPhone(phone, countries ? { countries } : undefined);
  if (!parsed.ok) throw new PhoneClaimError(parsed.reason === 'unsupported_country' ? 'phone_country_unsupported' : 'phone_invalid');
  const hash = phoneLookupHash(parsed.phone);

  const client = await pool.connect();
  let began = false;
  let releaseError;
  try {
    await client.query('BEGIN');
    began = true;
    await client.query("SET LOCAL statement_timeout = '5s'");
    await client.query("SET LOCAL lock_timeout = '3s'");

    const found = await client.query(
      `SELECT id, claimed_phone_hash, phone_lookup_hash, phone_number, is_phone_verified
         FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE FOR UPDATE`,
      [userId],
    );
    const user = found.rows[0];
    if (!user) throw new PhoneClaimError('account_unavailable');

    const sameClaimed = user.claimed_phone_hash === hash;
    const sameVerified = Boolean(user.phone_number) && user.is_phone_verified === true && user.phone_lookup_hash === hash;
    if (sameClaimed || sameVerified) {
      await client.query('COMMIT');
      began = false;
      return { phone_hint: maskPhone(parsed.phone), already: true };
    }
    // This account already has a different number. The person cannot swap it.
    if (user.claimed_phone_hash || (user.phone_number && user.is_phone_verified === true)) {
      throw new PhoneClaimError('phone_already_set');
    }

    // Serialise everyone claiming this number, then look for another live account.
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [`claimed-phone:${hash}`]);
    const taken = await client.query(
      `SELECT 1 FROM users
        WHERE id <> $1 AND deleted = FALSE
          AND (claimed_phone_hash = $2 OR phone_lookup_hash = $2)
        LIMIT 1`,
      [userId, hash],
    );
    if (taken.rows.length > 0) throw new PhoneClaimError('phone_unavailable');

    await client.query(
      `UPDATE users
          SET claimed_phone_enc = $2, claimed_phone_hash = $3, claimed_phone_at = NOW(), updated_at = NOW()
        WHERE id = $1`,
      [userId, encryptPhoneNumber(parsed.phone), hash],
    );
    await client.query('COMMIT');
    began = false;
    return { phone_hint: maskPhone(parsed.phone), already: false };
  } catch (error) {
    if (began) {
      try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
    }
    // The unique index is the last line of defence if two requests ever race past the lock.
    if (error && error.code === '23505') throw new PhoneClaimError('phone_unavailable');
    throw error;
  } finally {
    client.release(releaseError);
  }
}

/**
 * Support action: free a number so its real owner can claim it. Needs a named
 * actor and a written reason, and leaves an audit row. The account that held it
 * goes back to "needs a phone".
 */
async function releaseClaimedPhone({ pool, userId, actor, reason }) {
  if (typeof actor !== 'string' || actor.trim().length < 2 || actor.length > 120) throw new TypeError('A named actor is required');
  if (typeof reason !== 'string' || reason.trim().length < 8 || reason.length > 500) throw new TypeError('A written reason of at least 8 characters is required');
  const client = await pool.connect();
  let began = false;
  let releaseError;
  try {
    await client.query('BEGIN');
    began = true;
    const released = await client.query(
      `UPDATE users
          SET claimed_phone_enc = NULL, claimed_phone_hash = NULL, claimed_phone_at = NULL, updated_at = NOW()
        WHERE id = $1 AND claimed_phone_hash IS NOT NULL
        RETURNING id`,
      [userId],
    );
    if (released.rows.length === 0) {
      await client.query('ROLLBACK');
      began = false;
      return { released: false };
    }
    await client.query(
      `INSERT INTO auth_audit (user_id, action, status, meta)
       VALUES ($1, 'phone_claim_released', 'success', $2)`,
      [userId, JSON.stringify({ actor: actor.trim(), reason: reason.trim() })],
    );
    await client.query('COMMIT');
    began = false;
    return { released: true };
  } catch (error) {
    if (began) {
      try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
    }
    throw error;
  } finally {
    client.release(releaseError);
  }
}

module.exports = { PhoneClaimError, claimPhone, getPhoneClaimStatus, releaseClaimedPhone };
