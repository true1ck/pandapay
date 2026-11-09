'use strict';

// The recovery email: a second address that can get a person back into the account
// if they lose their sign-in email. Adding or changing it needs TWO codes: one to the
// sign-in email (a stolen session alone cannot do this) and one to the new address
// (proves the person controls it). It is active at once, and the sign-in email gets
// a notice. It is never used to sign in.

const { randomUUID, createHash } = require('node:crypto');
const { canonicalEmail, isDisposableEmail } = require('../utils/emailIdentity');
const { maskEmail } = require('../utils/recoveryContacts');

const STATUS_BY_CODE = Object.freeze({
  email_invalid: 400,
  email_not_allowed: 400,
  same_as_sign_in: 400,
  email_unavailable: 409,
  sign_in_email_required: 409,
  delivery_failed: 503,
  challenge_invalid: 400,
  code_invalid: 400,
  account_unavailable: 401,
  nothing_to_remove: 404,
});

class RecoveryEmailError extends Error {
  constructor(code) {
    super(code);
    this.name = 'RecoveryEmailError';
    this.code = code;
    this.status = STATUS_BY_CODE[code] || 400;
  }
}

const EMAIL_SHAPE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const deviceHash = deviceId => createHash('sha256').update(`pandapay-recovery-email-device-v1\0${deviceId}`).digest('hex');

async function loadUser(query, userId) {
  const { rows } = await query(
    `SELECT id, email, email_canonical, is_email_verified, recovery_email
       FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  if (!rows[0]) throw new RecoveryEmailError('account_unavailable');
  return rows[0];
}

/** Checks a typed address and returns it normalised, or throws why it cannot be used. */
async function checkCandidate(query, user, typed) {
  if (typeof typed !== 'string') throw new RecoveryEmailError('email_invalid');
  const email = typed.trim().toLowerCase();
  if (email.length < 6 || email.length > 255 || !EMAIL_SHAPE.test(email)) throw new RecoveryEmailError('email_invalid');
  if (isDisposableEmail(email)) throw new RecoveryEmailError('email_not_allowed');
  const mailbox = canonicalEmail(email) || email;
  if (user.email_canonical && mailbox === user.email_canonical) throw new RecoveryEmailError('same_as_sign_in');
  // Another account's sign-in address cannot be someone else's recovery address.
  const taken = await query(
    'SELECT 1 FROM users WHERE email_canonical = $1 AND deleted = FALSE AND id <> $2 LIMIT 1',
    [mailbox, user.id],
  );
  if (taken.rows.length > 0) throw new RecoveryEmailError('email_unavailable');
  return email;
}

async function getStatus({ query, userId }) {
  const { rows } = await query(
    `SELECT recovery_email, recovery_email_added_at FROM users
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  if (!rows[0]) throw new RecoveryEmailError('account_unavailable');
  return {
    has_recovery_email: Boolean(rows[0].recovery_email),
    recovery_email_hint: rows[0].recovery_email ? maskEmail(rows[0].recovery_email) : null,
    added_at: rows[0].recovery_email_added_at || null,
  };
}

/**
 * Step one: send a code to the sign-in email and a code to the new address, and
 * return a signed challenge that ties both to this person and this device.
 */
async function startChange({ query, userId, email, deviceId, otp, mail, jwtApi, ttlSeconds }) {
  const user = await loadUser(query, userId);
  if (!user.email || user.is_email_verified !== true) throw new RecoveryEmailError('sign_in_email_required');
  const candidate = await checkCandidate(query, user, email);

  const signInId = `recovery-email-signin-${randomUUID()}@recovery.invalid`;
  const newId = `recovery-email-new-${randomUUID()}@recovery.invalid`;
  const a = await otp.createOtpV2(signInId, 'email', 'replacement', deviceId);
  const b = await otp.createOtpV2(newId, 'email', 'replacement', deviceId);
  const discard = async () => {
    await Promise.allSettled([
      otp.discardUndeliveredOtpV2(signInId, 'email', a.requestId, 'replacement', deviceId),
      otp.discardUndeliveredOtpV2(newId, 'email', b.requestId, 'replacement', deviceId),
    ]);
  };
  let sentToSignIn;
  let sentToNew;
  try {
    [sentToSignIn, sentToNew] = await Promise.all([
      mail.sendOtpEmail(user.email, a.code, { purpose: 'recovery-email-signin' }),
      mail.sendOtpEmail(candidate, b.code, { purpose: 'recovery-email-new' }),
    ]);
  } catch (_) {
    await discard();
    throw new RecoveryEmailError('delivery_failed');
  }
  if (!sentToSignIn?.success || !sentToNew?.success) {
    await discard();
    const error = new RecoveryEmailError('delivery_failed');
    error.busy = sentToSignIn?.code || sentToNew?.code || null;
    throw error;
  }
  const challenge = jwtApi.sign({
    sub: user.id,
    value: candidate,
    a: { id: signInId, rid: a.requestId },
    b: { id: newId, rid: b.requestId },
    device_binding_hash: deviceHash(deviceId),
  }, ttlSeconds);
  return { challenge, contact_hint: maskEmail(candidate), expires_in: ttlSeconds };
}

/** Step two: both codes must be right. The change is active at once. */
async function finishChange({ query, userId, deviceId, challenge, signInCode, newCode, otp, mail, jwtApi }) {
  let proof;
  try {
    proof = jwtApi.verify(challenge);
  } catch (_) {
    throw new RecoveryEmailError('challenge_invalid');
  }
  if (!proof || proof.sub !== userId || proof.device_binding_hash !== deviceHash(deviceId) ||
      typeof proof.value !== 'string' || !proof.a?.id || !proof.b?.id) {
    throw new RecoveryEmailError('challenge_invalid');
  }
  const user = await loadUser(query, userId);
  // Everything is checked again: the account may have changed since step one.
  const candidate = await checkCandidate(query, user, proof.value);

  const first = await otp.verifyOtpV2(proof.a.id, signInCode, 'email', 'replacement', deviceId, proof.a.rid);
  if (!first.ok) throw new RecoveryEmailError('code_invalid');
  const second = await otp.verifyOtpV2(proof.b.id, newCode, 'email', 'replacement', deviceId, proof.b.rid);
  if (!second.ok) throw new RecoveryEmailError('code_invalid');

  let updated;
  try {
    updated = await query(
      `UPDATE users
          SET recovery_email = $2, recovery_email_added_at = NOW(), updated_at = NOW()
        WHERE id = $1 AND deleted = FALSE AND is_active = TRUE
        RETURNING id`,
      [userId, candidate],
    );
  } catch (error) {
    if (error && error.code === '23514') throw new RecoveryEmailError('same_as_sign_in');
    throw error;
  }
  if (updated.rows.length === 0) throw new RecoveryEmailError('account_unavailable');

  // Best effort: the change already happened, so a failed notice must not undo it.
  try {
    await mail.sendSecurityNotice({
      to: user.email,
      subject: 'A recovery email was added to your PandaPay account',
      text: `A recovery email (${maskEmail(candidate)}) was added to your PandaPay account.\n\n` +
        'If this was you, there is nothing to do. If it was not, open PandaPay, sign out of every device ' +
        'from Settings, and contact support from the Help screen.',
    });
  } catch (_) { /* notice is best effort */ }
  return { recovery_email_hint: maskEmail(candidate) };
}

async function removeRecoveryEmail({ query, userId, mail }) {
  const user = await loadUser(query, userId);
  const removed = await query(
    `UPDATE users SET recovery_email = NULL, recovery_email_added_at = NULL, updated_at = NOW()
      WHERE id = $1 AND recovery_email IS NOT NULL RETURNING id`,
    [userId],
  );
  if (removed.rows.length === 0) throw new RecoveryEmailError('nothing_to_remove');
  try {
    await mail.sendSecurityNotice({
      to: user.email,
      subject: 'The recovery email was removed from your PandaPay account',
      text: 'The recovery email on your PandaPay account was removed.\n\n' +
        'If this was you, there is nothing to do. If it was not, open PandaPay, sign out of every device ' +
        'from Settings, and contact support from the Help screen.',
    });
  } catch (_) { /* notice is best effort */ }
  return { removed: true };
}

module.exports = { RecoveryEmailError, getStatus, startChange, finishChange, removeRecoveryEmail, deviceHash };
