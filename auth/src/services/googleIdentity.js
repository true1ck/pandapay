'use strict';

const { createHash } = require('node:crypto');
const { newAccountsPaused, CODE: REGISTRATION_PAUSED, MESSAGE: REGISTRATION_PAUSED_MESSAGE } = require('./newAccountAdmission');

class GoogleIdentityError extends Error {
  constructor(code, status, message) {
    super(message);
    this.name = 'GoogleIdentityError';
    this.code = code;
    this.status = status;
  }
}

function accountLinkRequired() {
  return new GoogleIdentityError('GOOGLE_ACCOUNT_LINK_REQUIRED', 409,
    'Sign in with your existing email or phone OTP to access this account.');
}

function advisoryKey(subject) {
  // Stable across hosts/processes; no provider identity in lock metadata.
  return createHash('sha256').update(`pandapay:google-identity:${subject}`).digest().readBigInt64BE(0).toString();
}

const USER_FIELDS = 'id, email, name, role, COALESCE(token_version, 1) AS token_version';

function profileMetadata(value, maxCharacters) {
  // Device metadata permits longer values than the optional profile columns.
  // Bound only the profile copy; never let informational metadata break login.
  return typeof value === 'string' ? Array.from(value).slice(0, maxCharacters).join('') || null : null;
}

async function resolveGoogleAccount({ pool, googleUser, deviceInfo = {}, linkingToken = null, verifySession, now = Date.now }) {
  if (!googleUser || !/^[A-Za-z0-9_-]{1,255}$/.test(googleUser.googleId || '') ||
      googleUser.emailVerified !== true || typeof googleUser.email !== 'string' || !googleUser.email) {
    throw new GoogleIdentityError('GOOGLE_TOKEN_INVALID', 400, 'Invalid Google token');
  }
  const email = googleUser.email.trim().toLowerCase();
  const client = await pool.connect();
  let began = false;
  let releaseError;
  try {
    await client.query('BEGIN');
    began = true;
    await client.query("SET LOCAL statement_timeout = '5s'");
    await client.query("SET LOCAL lock_timeout = '3s'");
    await client.query('SELECT pg_advisory_xact_lock($1::bigint)', [advisoryKey(googleUser.googleId)]);

    let proof = null;
    if (linkingToken) {
      if (typeof verifySession !== 'function') throw accountLinkRequired();
      // Validate to learn the subject, lock it, then recheck on the same
      // connection. No provider/network work is done while holding locks.
      const currentProof = async () => {
        try { return await verifySession(linkingToken, client); } catch (error) {
          if (error?.code && /^[0-9A-Z]{5}$/.test(error.code)) throw error;
          throw accountLinkRequired();
        }
      };
      proof = await currentProof();
      if (!proof?.valid || proof.guest || !proof.subject) throw accountLinkRequired();
      const subject = proof.subject;
      await client.query('SELECT id FROM public.users WHERE id = $1 FOR UPDATE', [subject]);
      proof = await currentProof();
      const age = Math.floor(now() / 1000) - Number(proof?.auth_proof?.verified_at);
      if (!proof?.valid || proof.guest || proof.subject !== subject || !proof.session?.active ||
          !['email', 'phone', 'google'].includes(proof.auth_proof?.channel) ||
          !Number.isInteger(proof.auth_proof?.verified_at) || age < 0 || age > 300) {
        throw accountLinkRequired();
      }
    }

    const linked = await client.query(
      `SELECT u.id, u.email, u.name, u.role, COALESCE(u.token_version, 1) AS token_version,
              u.deleted, u.is_active
         FROM public.oauth_accounts o JOIN public.users u ON u.id = o.user_id
        WHERE o.provider = 'google' AND o.provider_user_id = $1 FOR UPDATE OF u`,
      [googleUser.googleId],
    );
    let user = linked.rows[0];
    let isNewAccount = false;
    if (user) {
      if (user.deleted || !user.is_active) {
        throw new GoogleIdentityError('GOOGLE_ACCOUNT_UNAVAILABLE', 403, 'This account is unavailable.');
      }
      if (proof && proof.subject !== user.id) throw accountLinkRequired();
      // Keep the original UUID/contacts if the Google account changes email.
    } else if (proof) {
      const target = await client.query(
        `SELECT ${USER_FIELDS} FROM public.users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
        [proof.subject],
      );
      user = target.rows[0];
      if (!user) throw accountLinkRequired();
      await client.query(
        "INSERT INTO public.oauth_accounts (user_id, provider, provider_user_id) VALUES ($1, 'google', $2)",
        [user.id, googleUser.googleId],
      );
    } else {
      const existing = await client.query('SELECT id FROM public.users WHERE lower(email) = $1 AND deleted = FALSE', [email]);
      if (existing.rows.length) throw accountLinkRequired();
      if (googleUser.emailAuthoritative !== true) {
        throw new GoogleIdentityError('GOOGLE_EMAIL_PROOF_REQUIRED', 409,
          'Sign in with your email OTP to continue.');
      }
      if (newAccountsPaused()) throw new GoogleIdentityError(REGISTRATION_PAUSED, 503, REGISTRATION_PAUSED_MESSAGE);
      const created = await client.query(
        `INSERT INTO public.users (email, name, avatar_url, language, timezone, is_email_verified)
         VALUES ($1, $2, $3, $4, $5, TRUE) RETURNING ${USER_FIELDS}`,
        [email, googleUser.name, googleUser.picture,
          profileMetadata(deviceInfo?.language_code, 10), profileMetadata(deviceInfo?.timezone, 50)],
      );
      user = created.rows[0];
      await client.query(
        "INSERT INTO public.oauth_accounts (user_id, provider, provider_user_id) VALUES ($1, 'google', $2)",
        [user.id, googleUser.googleId],
      );
      isNewAccount = true;
    }
    await client.query('UPDATE public.users SET last_login_at = NOW() WHERE id = $1', [user.id]);
    await client.query('COMMIT');
    began = false;
    const { deleted, is_active, ...publicUser } = user;
    return { user: publicUser, isNewAccount };
  } catch (error) {
    if (began) {
      try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
    }
    // An email OTP signup may win the active email index concurrently. That
    // does not prove both sign-in factors own the same account.
    if (error?.code === '23505') throw accountLinkRequired();
    throw error;
  } finally {
    client.release(releaseError);
  }
}

module.exports = { resolveGoogleAccount, GoogleIdentityError, advisoryKey };
