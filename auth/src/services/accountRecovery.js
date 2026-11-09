'use strict';

// "Can't sign in?" — getting back into an account after losing the sign-in email.
//
// The person proves they know the account: the lost sign-in email, the registered
// phone, and one fact from their own data (a card's last four, or the month they
// signed up when there is no card). Every start gets the same reply whether or not
// the details match, so nothing can be learned by guessing.
//
//   With a recovery email  ->  a code goes to it, then they give a new sign-in
//                              email (proved by a code). Access is immediate; every
//                              other device is signed out; the old email gets a
//                              notice with a 24-hour undo that freezes the account.
//   Without one            ->  the same checks, no code, then a 24-hour hold. The
//                              old email and any signed-in device can cancel it.
//                              After the hold the person finishes and gets in.
//
// This file is the state machine. The routes only shape requests and replies.

const { randomUUID, randomBytes, createHash, timingSafeEqual } = require('node:crypto');
const { parseClaimedPhone } = require('../utils/claimedPhone');
const { phoneLookupHash } = require('../utils/encryptedPhoneSearch');
const { canonicalEmail, isDisposableEmail } = require('../utils/emailIdentity');
const { maskEmail } = require('../utils/recoveryContacts');

const STATUS_BY_CODE = Object.freeze({
  invalid_request: 400,
  recovery_failed: 400, // the one answer for every "that does not match"
  too_many_attempts: 429,
  email_invalid: 400,
  email_not_allowed: 400,
  same_as_old_email: 400,
  email_unavailable: 409,
  code_invalid: 400,
  hold_not_over: 409,
  delivery_failed: 503,
  nothing_pending: 404,
  account_unavailable: 409,
});

class RecoveryError extends Error {
  constructor(code, extra = {}) {
    super(code);
    this.name = 'RecoveryError';
    this.code = code;
    this.status = STATUS_BY_CODE[code] || 400;
    Object.assign(this, extra);
  }
}

const DEVICE = /^[A-Za-z0-9:_-]{4,128}$/;
const EMAIL_SHAPE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const sha256 = value => createHash('sha256').update(value).digest('hex');
const deviceHash = deviceId => sha256(`pandapay-recovery-device-v1\0${deviceId}`);
const token = () => randomBytes(32).toString('base64url');
const sameHash = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));

/**
 * The one fact from the person's own data. A card's last four ("4821"), or a month
 * ("2026-11", "11/2026"). Returns null when it is neither.
 */
function parseFact(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim();
  if (/^\d{4}$/.test(value)) {
    // Four digits alone is a card, never a year: a year needs a month with it.
    return { kind: 'card', last4: value };
  }
  let match = value.match(/^(\d{4})[-/](\d{1,2})$/);
  let year; let month;
  if (match) { year = Number(match[1]); month = Number(match[2]); }
  else if ((match = value.match(/^(\d{1,2})[-/](\d{4})$/))) { month = Number(match[1]); year = Number(match[2]); }
  else return null;
  if (month < 1 || month > 12 || year < 2020 || year > 2100) return null;
  return { kind: 'month', year, month };
}

/** The year and month a timestamp falls in, in India time (where people sign up). */
function signUpMonthIst(createdAt) {
  const shifted = new Date(new Date(createdAt).getTime() + 330 * 60 * 1000);
  return { year: shifted.getUTCFullYear(), month: shifted.getUTCMonth() + 1 };
}

function createAccountRecovery(deps) {
  const {
    query, transaction, otp, mail, cardFact, issueSession, budget,
    now = () => new Date(), sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
    publicBaseUrl = null, holdHours = 24, stopHours = 24, attemptMinutes = 30, minStartMs = 600,
    logger = console,
  } = deps;

  const fail = () => new RecoveryError('recovery_failed');

  async function loadAttempt(attemptId, deviceId, { states, matchedOnly = true }) {
    if (typeof attemptId !== 'string' || !/^[0-9a-f-]{36}$/i.test(attemptId) || typeof deviceId !== 'string' || !DEVICE.test(deviceId)) return null;
    const { rows } = await query(
      `SELECT * FROM recovery_attempts WHERE id = $1 AND device_hash = $2 AND expires_at > NOW()
        AND state = ANY($3::text[])`,
      [attemptId, deviceHash(deviceId), states],
    );
    const attempt = rows[0];
    if (!attempt || (matchedOnly && !attempt.matched)) return null;
    return attempt;
  }

  async function loadUser(userId, executor = query) {
    const { rows } = await executor(
      `SELECT id, email, email_canonical, recovery_email, token_version, is_email_verified, name, role
         FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
      [userId],
    );
    return rows[0] || null;
  }

  async function bumpFailures(attempt) {
    await query(
      `UPDATE recovery_attempts
          SET failed_attempts = failed_attempts + 1,
              state = CASE WHEN failed_attempts + 1 >= 5 THEN 'failed' ELSE state END
        WHERE id = $1`,
      [attempt.id],
    );
  }

  /** Similar work for a request that cannot succeed, so timing tells nothing. */
  async function decoyWork(code, deviceId) {
    try { await otp.verifyOtpV2(`decoy-${randomUUID()}@recovery.invalid`, String(code || '000000'), 'email', 'recovery', deviceId, randomUUID()); } catch (_) { /* decoy only */ }
  }

  // ---------------------------------------------------------------- start

  async function start({ lostEmail, phone, fact, deviceId, ip }) {
    if (typeof lostEmail !== 'string' || typeof phone !== 'string' || typeof fact !== 'string' ||
        typeof deviceId !== 'string' || !DEVICE.test(deviceId) || lostEmail.length > 320 || phone.length > 40 || fact.length > 20) {
      throw new RecoveryError('invalid_request');
    }
    const startedAt = Date.now();
    const typedMailbox = canonicalEmail(lostEmail) || lostEmail.trim().toLowerCase();
    // Counted for every start, matched or not, so the limit itself tells nothing.
    await budget('recovery-start-mailbox', sha256(typedMailbox).slice(0, 40), 3, 86400);
    await budget('recovery-start-ip', ip || 'unknown', 10, 86400);
    await budget('recovery-start-device', deviceHash(deviceId).slice(0, 40), 5, 86400);

    const { rows } = await query(
      `SELECT id, email, email_canonical, recovery_email, claimed_phone_hash, phone_lookup_hash,
              is_phone_verified, created_at
         FROM users WHERE email_canonical = $1 AND deleted = FALSE AND is_active = TRUE AND is_email_verified = TRUE`,
      [typedMailbox],
    );
    const user = rows[0] || null;

    // Every check runs for every start, so a missing account costs the same as a wrong phone.
    const parsedPhone = parseClaimedPhone(phone);
    const phoneHash = parsedPhone.ok ? phoneLookupHash(parsedPhone.phone) : null;
    const phoneOk = Boolean(user && phoneHash &&
      (user.claimed_phone_hash === phoneHash || (user.is_phone_verified === true && user.phone_lookup_hash === phoneHash)));
    const parsedFact = parseFact(fact);
    let factOk = false;
    if (user && parsedFact) {
      let cards = null;
      try { cards = await cardFact({ userId: user.id, last4: parsedFact.kind === 'card' ? parsedFact.last4 : null }); }
      catch (error) { logger.warn?.('[recovery] card fact unavailable', error?.code || error?.name); }
      if (cards) {
        factOk = cards.has_cards
          ? parsedFact.kind === 'card' && cards.matched === true
          : parsedFact.kind === 'month' && (() => {
            const m = signUpMonthIst(user.created_at);
            return m.year === parsedFact.year && m.month === parsedFact.month;
          })();
      }
    }
    const matched = Boolean(user) && phoneOk && factOk;
    const path = matched ? (user.recovery_email ? 'strong' : 'weak') : null;

    const attemptId = randomUUID();
    let state = 'started';
    let codeIdentifier = null;
    let codeRequestId = null;
    if (matched && path === 'strong') {
      codeIdentifier = `recovery-code-${randomUUID()}@recovery.invalid`;
      try {
        const issued = await otp.createOtpV2(codeIdentifier, 'email', 'recovery', deviceId);
        codeRequestId = issued.requestId;
        const sent = await mail.sendOtpEmail(user.recovery_email, issued.code, { purpose: 'recovery-code' });
        if (!sent?.success) {
          await otp.discardUndeliveredOtpV2(codeIdentifier, 'email', issued.requestId, 'recovery', deviceId).catch(() => {});
          state = 'failed';
        }
      } catch (error) {
        logger.warn?.('[recovery] code delivery failed', error?.code || error?.name);
        state = 'failed';
      }
    }
    await query(
      `INSERT INTO recovery_attempts (id, user_id, matched, path, state, device_hash, ip_address, expires_at,
                                      code_identifier, code_request_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, NOW() + ($8::integer * INTERVAL '1 minute'), $9, $10)`,
      [attemptId, matched ? user.id : null, matched, path, state, deviceHash(deviceId), ip || null, attemptMinutes, codeIdentifier, codeRequestId],
    );
    if (matched) {
      // The owner is told, at the sign-in email, that recovery began.
      try {
        await mail.sendSecurityNotice({
          to: user.email,
          subject: 'Someone started recovering your PandaPay account',
          text: 'Someone entered your email, phone and account details to recover your PandaPay account.\n\n' +
            'If this was you, carry on in the app. If it was not, your account is safe so far: nothing has changed. ' +
            'If you are asked to confirm anything you did not start, contact support from the Help screen.',
        });
      } catch (_) { /* a notice is best effort */ }
    }
    const waited = Date.now() - startedAt;
    if (waited < minStartMs) await sleep(minStartMs - waited);
    return { ok: true, attempt_id: attemptId, version: 2, code_length: 6, expires_in: 60 };
  }

  // ------------------------------------------------------------ proofs

  async function verifyCode({ attemptId, code, deviceId }) {
    const attempt = await loadAttempt(attemptId, deviceId, { states: ['started'] });
    if (!attempt || attempt.path !== 'strong' || typeof code !== 'string' || !/^\d{6}$/.test(code)) {
      await decoyWork(code, deviceId);
      throw fail();
    }
    const verified = await otp.verifyOtpV2(attempt.code_identifier, code, 'email', 'recovery', deviceId, attempt.code_request_id);
    if (!verified.ok) {
      await bumpFailures(attempt);
      throw fail();
    }
    await query("UPDATE recovery_attempts SET state = 'proven' WHERE id = $1 AND state = 'started'", [attempt.id]);
    return { ok: true, next: 'new_email', can_use_recovery_email: true };
  }

  async function noRecoveryEmail({ attemptId, deviceId }) {
    const attempt = await loadAttempt(attemptId, deviceId, { states: ['started'] });
    if (!attempt || attempt.path !== 'weak') {
      await decoyWork('000000', deviceId);
      throw fail();
    }
    await query("UPDATE recovery_attempts SET state = 'proven' WHERE id = $1 AND state = 'started'", [attempt.id]);
    return { ok: true, next: 'new_email', hold_hours: holdHours, can_use_recovery_email: false };
  }

  // ------------------------------------------------------- new email

  async function checkNewEmail(user, typed) {
    if (typeof typed !== 'string') throw new RecoveryError('email_invalid');
    const email = typed.trim().toLowerCase();
    if (email.length < 6 || email.length > 255 || !EMAIL_SHAPE.test(email)) throw new RecoveryError('email_invalid');
    if (isDisposableEmail(email)) throw new RecoveryError('email_not_allowed');
    const mailbox = canonicalEmail(email) || email;
    if (mailbox === user.email_canonical) throw new RecoveryError('same_as_old_email');
    const taken = await query('SELECT 1 FROM users WHERE email_canonical = $1 AND deleted = FALSE AND id <> $2 LIMIT 1', [mailbox, user.id]);
    if (taken.rows.length > 0) throw new RecoveryError('email_unavailable');
    return email;
  }

  async function setNewEmail({ attemptId, deviceId, newEmail, useRecoveryEmail = false }) {
    const attempt = await loadAttempt(attemptId, deviceId, { states: ['proven'] });
    if (!attempt) throw fail();
    const user = await loadUser(attempt.user_id);
    if (!user) throw new RecoveryError('account_unavailable');
    if (useRecoveryEmail === true) {
      if (attempt.path !== 'strong' || !user.recovery_email) throw fail();
      await query(
        `UPDATE recovery_attempts SET new_email = $2, use_recovery_email = TRUE, state = 'ready' WHERE id = $1 AND state = 'proven'`,
        [attempt.id, user.recovery_email],
      );
      return { ok: true, needs_code: false, new_email_hint: maskEmail(user.recovery_email) };
    }
    const email = await checkNewEmail(user, newEmail);
    const identifier = `recovery-new-${randomUUID()}@recovery.invalid`;
    const issued = await otp.createOtpV2(identifier, 'email', 'recovery', deviceId);
    const sent = await mail.sendOtpEmail(email, issued.code, { purpose: 'recovery-new-email' });
    if (!sent?.success) {
      await otp.discardUndeliveredOtpV2(identifier, 'email', issued.requestId, 'recovery', deviceId).catch(() => {});
      throw new RecoveryError('delivery_failed');
    }
    await query(
      `UPDATE recovery_attempts
          SET new_email = $2, new_email_identifier = $3, new_email_request_id = $4, use_recovery_email = FALSE, state = 'new_email_sent'
        WHERE id = $1 AND state = 'proven'`,
      [attempt.id, email, identifier, issued.requestId],
    );
    return { ok: true, needs_code: true, new_email_hint: maskEmail(email), expires_in: 60 };
  }

  // -------------------------------------------------------- complete

  async function complete({ attemptId, deviceId, newEmailCode, ip, userAgent }) {
    const attempt = await loadAttempt(attemptId, deviceId, { states: ['new_email_sent', 'ready'] });
    if (!attempt) throw fail();
    if (attempt.state === 'new_email_sent') {
      if (typeof newEmailCode !== 'string' || !/^\d{6}$/.test(newEmailCode)) throw new RecoveryError('code_invalid');
      const verified = await otp.verifyOtpV2(attempt.new_email_identifier, newEmailCode, 'email', 'recovery', deviceId, attempt.new_email_request_id);
      if (!verified.ok) {
        await bumpFailures(attempt);
        throw new RecoveryError('code_invalid');
      }
    }
    if (attempt.path === 'strong') return finishNow(attempt, { deviceId, ip, userAgent });
    return startHold(attempt);
  }

  async function startHold(attempt) {
    const user = await loadUser(attempt.user_id);
    if (!user) throw new RecoveryError('account_unavailable');
    const resumeToken = token();
    const stopToken = token();
    const stamp = now();
    const holdUntil = new Date(stamp.getTime() + holdHours * 3600 * 1000);
    const updated = await query(
      `UPDATE recovery_attempts
          SET state = 'pending_hold', hold_until = $2::timestamptz, resume_token_hash = $3, stop_token_hash = $4,
              stop_until = $2::timestamptz, old_email = $5, expires_at = $2::timestamptz + INTERVAL '7 days'
        WHERE id = $1 AND state IN ('new_email_sent', 'ready') RETURNING id`,
      [attempt.id, holdUntil, sha256(resumeToken), sha256(stopToken), user.email],
    );
    if (updated.rows.length === 0) throw fail();
    const link = publicBaseUrl ? `\n\nTo cancel it now, open: ${publicBaseUrl}/auth/recovery/stop?token=${stopToken}` : '';
    const text = `Someone asked to change the sign-in email on your PandaPay account to ${maskEmail(attempt.new_email)}. ` +
      `It will happen in ${holdHours} hours, unless you cancel it.${link}\n\n` +
      'You can also cancel it from PandaPay on any device you are signed in on, under Settings. ' +
      'If this was you, there is nothing to do.';
    try { await mail.sendSecurityNotice({ to: user.email, subject: 'Your PandaPay sign-in email will change in 24 hours', text }); } catch (_) { /* best effort */ }
    return { ok: true, pending: true, hold_until: holdUntil.toISOString(), resume_token: resumeToken };
  }

  async function finish({ attemptId, deviceId, resumeToken, ip, userAgent }) {
    const attempt = await loadAttempt(attemptId, deviceId, { states: ['pending_hold'] });
    if (!attempt || typeof resumeToken !== 'string' || !sameHash(attempt.resume_token_hash, sha256(resumeToken))) throw fail();
    if (now() < new Date(attempt.hold_until)) throw new RecoveryError('hold_not_over', { hold_until: new Date(attempt.hold_until).toISOString() });
    return finishNow(attempt, { deviceId, ip, userAgent });
  }

  /** The change itself: new email, every other session ended, this device signed in. */
  async function finishNow(attempt, { deviceId, ip, userAgent }) {
    const stopToken = token();
    let outcome;
    try {
      outcome = await transaction(async client => {
        const q = (sql, args) => client.query(sql, args);
        const locked = await q(
          `SELECT id, email, email_canonical, recovery_email, token_version, name, role
             FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE FOR UPDATE`,
          [attempt.user_id],
        );
        const user = locked.rows[0];
        if (!user) throw new RecoveryError('account_unavailable');
        const current = await q(
          `SELECT state, new_email, use_recovery_email FROM recovery_attempts WHERE id = $1 FOR UPDATE`, [attempt.id]);
        if (!current.rows[0] || !['new_email_sent', 'ready', 'pending_hold'].includes(current.rows[0].state)) throw fail();
        const { new_email: newEmail, use_recovery_email: useRecovery } = current.rows[0];
        const updated = await q(
          `UPDATE users
              SET email = $2, is_email_verified = TRUE,
                  recovery_email = CASE WHEN $3 THEN NULL ELSE recovery_email END,
                  recovery_email_added_at = CASE WHEN $3 THEN NULL ELSE recovery_email_added_at END,
                  token_version = COALESCE(token_version, 1) + 1, updated_at = NOW()
            WHERE id = $1
            RETURNING id, email, name, role, token_version`,
          [user.id, newEmail, useRecovery === true],
        );
        await q('UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL', [user.id]);
        await q('UPDATE user_devices SET is_active = FALSE WHERE user_id = $1 AND is_active = TRUE', [user.id]);
        await q(
          `INSERT INTO user_devices (user_id, device_identifier, device_platform, last_seen_at, is_active)
           VALUES ($1, $2, 'unknown', NOW(), TRUE)
           ON CONFLICT (user_id, device_identifier) DO UPDATE SET is_active = TRUE, last_seen_at = NOW()`,
          [user.id, deviceId],
        );
        const session = await issueSession({ client, user: updated.rows[0], deviceId, ip, userAgent });
        await q(
          `UPDATE recovery_attempts
              SET state = 'completed', completed_at = NOW(), old_email = $2, stop_token_hash = $3,
                  stop_until = NOW() + ($4::integer * INTERVAL '1 hour'), resume_token_hash = NULL
            WHERE id = $1`,
          [attempt.id, user.email, sha256(stopToken), stopHours],
        );
        return { session, oldEmail: user.email, recoveryEmail: useRecovery ? null : user.recovery_email, newEmail };
      });
    } catch (error) {
      if (error && error.code === '23505') {
        await query("UPDATE recovery_attempts SET state = 'failed' WHERE id = $1", [attempt.id]);
        throw new RecoveryError('email_unavailable');
      }
      throw error;
    }
    const link = publicBaseUrl ? `\n\nIf this was not you, freeze the account now: ${publicBaseUrl}/auth/recovery/stop?token=${stopToken}` : '\n\nIf this was not you, contact support from the Help screen right away.';
    const text = `The sign-in email on your PandaPay account was changed to ${maskEmail(outcome.newEmail)} after a recovery. ` +
      'Every other device was signed out.' + link;
    for (const to of [outcome.oldEmail, outcome.recoveryEmail].filter(Boolean)) {
      try { await mail.sendSecurityNotice({ to, subject: 'The sign-in email on your PandaPay account changed', text }); } catch (_) { /* best effort */ }
    }
    return { ok: true, pending: false, ...outcome.session, new_email_hint: maskEmail(outcome.newEmail) };
  }

  // ------------------------------------------------- stop (cancel or freeze)

  /** From the link in an email: cancels a waiting recovery, or freezes the account after one. */
  async function stopByToken({ token: stopToken }) {
    if (typeof stopToken !== 'string' || stopToken.length < 20 || stopToken.length > 100) return { outcome: 'unknown' };
    const { rows } = await query('SELECT * FROM recovery_attempts WHERE stop_token_hash = $1', [sha256(stopToken)]);
    const attempt = rows[0];
    if (!attempt) return { outcome: 'unknown' };
    if (attempt.state === 'pending_hold' && now() < new Date(attempt.stop_until)) {
      await query("UPDATE recovery_attempts SET state = 'cancelled', stopped_at = NOW() WHERE id = $1 AND state = 'pending_hold'", [attempt.id]);
      return { outcome: 'cancelled' };
    }
    if (attempt.state === 'completed' && now() < new Date(attempt.stop_until)) {
      await transaction(async client => {
        await client.query('UPDATE users SET is_active = FALSE, token_version = COALESCE(token_version, 1) + 1, updated_at = NOW() WHERE id = $1', [attempt.user_id]);
        await client.query('UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL', [attempt.user_id]);
        await client.query("UPDATE recovery_attempts SET state = 'undone', stopped_at = NOW() WHERE id = $1", [attempt.id]);
      });
      return { outcome: 'frozen' };
    }
    return { outcome: 'expired' };
  }

  // --------------------------------------- from a signed-in device

  async function pendingForUser(userId) {
    const { rows } = await query(
      `SELECT id, hold_until FROM recovery_attempts WHERE user_id = $1 AND state = 'pending_hold' AND hold_until > NOW() ORDER BY created_at DESC LIMIT 1`,
      [userId],
    );
    return rows[0] ? { pending: true, hold_until: new Date(rows[0].hold_until).toISOString() } : { pending: false, hold_until: null };
  }

  async function cancelForUser(userId) {
    const { rows } = await query(
      `UPDATE recovery_attempts SET state = 'cancelled', stopped_at = NOW()
        WHERE user_id = $1 AND state = 'pending_hold' RETURNING id`,
      [userId],
    );
    if (rows.length === 0) throw new RecoveryError('nothing_pending');
    return { ok: true, cancelled: rows.length };
  }

  return { start, verifyCode, noRecoveryEmail, setNewEmail, complete, finish, stopByToken, pendingForUser, cancelForUser };
}

module.exports = { createAccountRecovery, RecoveryError, parseFact, signUpMonthIst, deviceHash };
