'use strict';

// Adding or changing the phone number on an account. A code goes to the person's
// sign-in email and the number is saved only when it is entered. That code proves
// control of the EMAIL, not of the phone: nothing is sent to the number, so the
// number stays "claimed" (never verified) exactly like one typed at sign-up.
// Real phone verification is a separate, later feature.
//
// The old number is released at once when the new one is saved. (Holding it for a
// while is a planned anti-abuse step for when subscriptions launch.)

const { randomUUID, createHash } = require('node:crypto');
const { parseClaimedPhone } = require('../utils/claimedPhone');
const { phoneLookupHash } = require('../utils/encryptedPhoneSearch');
const { maskPhone, maskEmail } = require('../utils/recoveryContacts');
const { claimPhone, PhoneClaimError } = require('./phoneClaim');

const STATUS_BY_CODE = Object.freeze({
  phone_invalid: 400,
  phone_country_unsupported: 400,
  phone_unavailable: 409,
  phone_already_set: 409,
  same_phone: 400,
  sign_in_email_required: 409,
  delivery_failed: 503,
  challenge_invalid: 400,
  code_invalid: 400,
  account_unavailable: 401,
});

class PhoneChangeError extends Error {
  constructor(code) {
    super(code);
    this.name = 'PhoneChangeError';
    this.code = code;
    this.status = STATUS_BY_CODE[code] || 400;
  }
}

const deviceHash = deviceId => createHash('sha256').update(`pandapay-phone-change-device-v1\0${deviceId}`).digest('hex');

async function loadUser(query, userId) {
  const { rows } = await query(
    `SELECT id, email, is_email_verified, claimed_phone_hash, phone_lookup_hash, phone_number, is_phone_verified
       FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  if (!rows[0]) throw new PhoneChangeError('account_unavailable');
  return rows[0];
}

function parsePhone(phone, countries) {
  const parsed = parseClaimedPhone(phone, countries ? { countries } : undefined);
  if (!parsed.ok) {
    throw new PhoneChangeError(parsed.reason === 'unsupported_country' ? 'phone_country_unsupported' : 'phone_invalid');
  }
  return parsed.phone;
}

/** The number is checked before any email is sent, so nobody is mailed a code for a number that cannot be used. */
async function checkCandidate(query, user, phone, countries) {
  const canonical = parsePhone(phone, countries);
  const hash = phoneLookupHash(canonical);
  if (user.claimed_phone_hash === hash ||
      (user.phone_number && user.is_phone_verified === true && user.phone_lookup_hash === hash)) {
    throw new PhoneChangeError('same_phone');
  }
  // A verified sign-in phone belongs to the account's identity; support moves it.
  if (user.phone_number && user.is_phone_verified === true) throw new PhoneChangeError('phone_already_set');
  const taken = await query(
    `SELECT 1 FROM users
      WHERE id <> $1 AND deleted = FALSE AND (claimed_phone_hash = $2 OR phone_lookup_hash = $2)
      LIMIT 1`,
    [user.id, hash],
  );
  if (taken.rows.length > 0) throw new PhoneChangeError('phone_unavailable');
  return canonical;
}

/** Step one: send a code to the sign-in email and return a signed challenge. */
async function startChange({ query, userId, phone, deviceId, countries, otp, mail, jwtApi, ttlSeconds }) {
  const user = await loadUser(query, userId);
  if (!user.email || user.is_email_verified !== true) throw new PhoneChangeError('sign_in_email_required');
  const canonical = await checkCandidate(query, user, phone, countries);

  const otpId = `phone-change-${randomUUID()}@recovery.invalid`;
  const issued = await otp.createOtpV2(otpId, 'email', 'replacement', deviceId);
  let sent;
  try {
    sent = await mail.sendOtpEmail(user.email, issued.code, { purpose: 'phone-change' });
  } catch (_) {
    sent = null;
  }
  if (!sent?.success) {
    await Promise.allSettled([otp.discardUndeliveredOtpV2(otpId, 'email', issued.requestId, 'replacement', deviceId)]);
    const error = new PhoneChangeError('delivery_failed');
    error.busy = sent?.code || null;
    throw error;
  }
  const challenge = jwtApi.sign({
    sub: user.id,
    value: canonical,
    a: { id: otpId, rid: issued.requestId },
    device_binding_hash: deviceHash(deviceId),
  }, ttlSeconds);
  return { challenge, email_hint: maskEmail(user.email), phone_hint: maskPhone(canonical), expires_in: ttlSeconds };
}

/** Step two: the code must be right. The number is saved, replacing any earlier one. */
async function finishChange({ query, pool, userId, deviceId, countries, challenge, code, otp, mail, jwtApi }) {
  let proof;
  try {
    proof = jwtApi.verify(challenge);
  } catch (_) {
    throw new PhoneChangeError('challenge_invalid');
  }
  if (!proof || proof.sub !== userId || proof.device_binding_hash !== deviceHash(deviceId) ||
      typeof proof.value !== 'string' || !proof.a?.id) {
    throw new PhoneChangeError('challenge_invalid');
  }
  const user = await loadUser(query, userId);
  // Everything is checked again: the account or the number may have changed since step one.
  await checkCandidate(query, user, proof.value, countries);

  const verified = await otp.verifyOtpV2(proof.a.id, code, 'email', 'replacement', deviceId, proof.a.rid);
  if (!verified.ok) throw new PhoneChangeError('code_invalid');

  let result;
  try {
    result = await claimPhone({ pool, userId, phone: proof.value, countries, replace: true });
  } catch (error) {
    if (error instanceof PhoneClaimError) throw new PhoneChangeError(error.code);
    throw error;
  }

  // Best effort: the change already happened, so a failed notice must not undo it.
  try {
    await mail.sendSecurityNotice({
      to: user.email,
      subject: 'The phone number on your PandaPay account was changed',
      text: `The phone number on your PandaPay account was set to ${result.phone_hint}.\n\n` +
        'If this was you, there is nothing to do. If it was not, open PandaPay, sign out of every device ' +
        'from Settings, and contact support from the Help screen.',
    });
  } catch (_) { /* notice is best effort */ }
  return { phone_hint: result.phone_hint, had_phone: Boolean(user.claimed_phone_hash) };
}

module.exports = { PhoneChangeError, startChange, finishChange, deviceHash };
