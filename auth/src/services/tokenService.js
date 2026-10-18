// src/services/tokenService.js
const jwt = require('jsonwebtoken');
const bcrypt = require('bcrypt');
const { randomUUID, createHmac } = require('crypto');
const db = require('../db');
const config = require('../config');
const {
  getActiveKey,
  getIssuer,
  getAudience,
} = require('./jwtKeys');

const REFRESH_SECRET = config.jwtRefreshSecret;
const ACCESS_TTL = config.jwtAccessTtl;
const REFRESH_TTL = config.jwtRefreshTtl;
const REFRESH_MAX_IDLE_MS = config.refreshMaxIdleMinutes * 60 * 1000;

function signAccessToken(user, options = {}) {
  const payload = {
    sub: user.id,
    phone_number: user.phone_number,
    // authMiddleware verifies these claims on protected auth-service routes.
    // Hard-coding `authenticated` here contradicted its `mobile-app` default.
    role: 'authenticated',
    // Our custom app role:
    user_role: user.role,
    // === SECURITY HARDENING: GLOBAL LOGOUT ===
    // Include token_version to support logout-all-devices functionality
    token_version: user.token_version || 1,
    // === GUEST LOGIN SUPPORT ===
    // Include is_guest flag (defaults to false for backward compatibility)
    is_guest: user.is_guest || false,
  };

  // Attach device identifier if provided (per-device token invalidation)
  if (options.deviceId) {
    payload.device_id = options.deviceId;
  }

  // === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
  // Include high_assurance flag if requested (for step-up authentication)
  if (options.highAssurance === true) {
    payload.high_assurance = true;
  }
  if (['email', 'phone'].includes(options.recoveryChannel)) {
    payload.recovery_channel = options.recoveryChannel;
    payload.recovery_verified_at = Math.floor(Date.now() / 1000);
  }

  // === GUEST LOGIN SUPPORT ===
  // Allow custom expiration time (defaults to ACCESS_TTL for backward compatibility)
  const expiresIn = options.expiresIn || ACCESS_TTL;

  const activeKey = getActiveKey();
  const token = jwt.sign(payload, activeKey.secret, {
    expiresIn,
    issuer: getIssuer(),
    audience: getAudience(),
    keyid: activeKey.keyId,
  });
  console.log(
    `[TOKEN_SERVICE] signAccessToken: Generated access token - userId=${user.id}, tokenVersion=${payload.token_version}, deviceId=${payload.device_id || 'none'}, isGuest=${payload.is_guest}, expiresIn=${expiresIn}`
  );
  return token;
}


async function issueRefreshToken({
  userId,
  deviceId,
  userAgent,
  ip,
  rotatedFromId = null,
  tokenId = randomUUID(),
  executor = db,
}) {
  const token = jwt.sign(
    {
      sub: userId,
      device_id: deviceId,
      jti: tokenId,
    },
    REFRESH_SECRET,
    // Explicit expiry, without an issued-at claim, lets an identical request
    // recover the committed successor from its existing hashed DB record.
    { expiresIn: REFRESH_TTL, noTimestamp: true }
  );
  const decoded = jwt.decode(token);
  const expiresAt = new Date(decoded.exp * 1000);

  await storeRefreshToken({
    userId,
    deviceId,
    token,
    tokenId,
    expiresAt,
    userAgent,
    ip,
    rotatedFromId,
    executor,
  });

  return token;
}

async function storeRefreshToken({
  userId,
  deviceId,
  token,
  tokenId,
  expiresAt,
  userAgent,
  ip,
  rotatedFromId = null,
  executor = db,
}) {
  const tokenHash = await bcrypt.hash(token, 10);

  await executor.query(
    `
    INSERT INTO refresh_tokens (
      user_id,
      device_id,
      token_id,
      token_hash,
      user_agent,
      ip_address,
      expires_at,
      rotated_from_id
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
    `,
    [
      userId,
      deviceId,
      tokenId,
      tokenHash,
      userAgent || null,
      ip || null,
      expiresAt,
      rotatedFromId,
    ]
  );
}

async function verifyRefreshToken(rawToken, { requestId } = {}) {
  console.log('[TOKEN_SERVICE] verifyRefreshToken: Starting verification');
  let payload;
  try {
    payload = jwt.verify(rawToken, REFRESH_SECRET);
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: JWT verified - userId=${payload.sub}, deviceId=${payload.device_id}, tokenId=${payload.jti}`);
  } catch (err) {
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: JWT verification failed - ${err.message}`);
    return null;
  }

  const { sub: userId, device_id: deviceId, jti: tokenId } = payload;
  if (!tokenId) {
    console.log('[TOKEN_SERVICE] verifyRefreshToken: No tokenId in payload');
    return null;
  }

  const { rows } = await db.query(
    `SELECT * FROM refresh_tokens WHERE token_id = $1`,
    [tokenId]
  );

  if (rows.length === 0) {
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token not found in database - tokenId=${tokenId}`);
    return null;
  }

  const tokenRow = rows[0];
  console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token found in DB - userId=${tokenRow.user_id}, deviceId=${tokenRow.device_id}, revoked=${!!tokenRow.revoked_at}`);

  if (tokenRow.user_id !== userId || tokenRow.device_id !== deviceId) {
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: User/device mismatch - expected userId=${userId}, deviceId=${deviceId}, got userId=${tokenRow.user_id}, deviceId=${tokenRow.device_id}`);
    await handleReuse(tokenRow);
    return { reuseDetected: true };
  }

  const match = await bcrypt.compare(rawToken, tokenRow.token_hash);
  if (!match) {
    console.log('[TOKEN_SERVICE] verifyRefreshToken: Token hash mismatch - possible reuse');
    await handleReuse(tokenRow);
    return { reuseDetected: true };
  }

  if (tokenRow.revoked_at) {
    const recovered = await recoverRotation(tokenRow, requestId, db);
    if (recovered) return { userId, deviceId, row: tokenRow, recovered };
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token revoked at ${tokenRow.revoked_at}`);
    await handleReuse(tokenRow);
    return { reuseDetected: true };
  }

  const now = new Date();
  if (tokenRow.expires_at <= now) {
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token expired - expiresAt=${tokenRow.expires_at}, now=${now}`);
    await revokeToken(tokenRow.id);
    return null;
  }

  if (
    tokenRow.last_used_at &&
    now.getTime() - new Date(tokenRow.last_used_at).getTime() > REFRESH_MAX_IDLE_MS
  ) {
    console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token idle timeout exceeded - lastUsedAt=${tokenRow.last_used_at}`);
    await revokeToken(tokenRow.id);
    return null;
  }

  await db.query(
    `UPDATE refresh_tokens SET last_used_at = NOW() WHERE id = $1`,
    [tokenRow.id]
  );
  console.log(`[TOKEN_SERVICE] verifyRefreshToken: Token verified successfully - userId=${userId}, deviceId=${deviceId}`);

  return { userId, deviceId, row: tokenRow };
}

function successorId(tokenRow, requestId) {
  if (!requestId) return null;
  const hex = createHmac('sha256', REFRESH_SECRET)
    .update(`refresh-rotation-v1:${tokenRow.token_id}:${requestId}`)
    .digest('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

async function recoverRotation(tokenRow, requestId, executor) {
  const tokenId = successorId(tokenRow, requestId);
  if (!tokenId) return null; // Older clients retain single-use semantics.
  const { rows } = await executor.query(
    `SELECT * FROM refresh_tokens WHERE token_id = $1 AND rotated_from_id = $2`,
    [tokenId, tokenRow.id]
  );
  const child = rows[0];
  if (!child || child.revoked_at || new Date(child.expires_at) <= new Date() ||
      child.user_id !== tokenRow.user_id || child.device_id !== tokenRow.device_id ||
      (child.last_used_at && Date.now() - new Date(child.last_used_at).getTime() > REFRESH_MAX_IDLE_MS)) return null;
  const token = jwt.sign({
    sub: child.user_id,
    device_id: child.device_id,
    jti: child.token_id,
    exp: Math.floor(new Date(child.expires_at).getTime() / 1000),
  }, REFRESH_SECRET, { noTimestamp: true });
  // Never return a reconstructed credential unless it matches the saved hash.
  return await bcrypt.compare(token, child.token_hash) ? token : null;
}

async function rotateRefreshToken({ tokenRow, userAgent, ip, requestId }) {
  const pool = await db.pool;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'SELECT * FROM refresh_tokens WHERE id = $1 FOR UPDATE', [tokenRow.id]
    );
    const current = rows[0];
    if (!current || new Date(current.expires_at) <= new Date()) {
      throw Object.assign(new Error('Invalid refresh token'), { statusCode: 401 });
    }
    if (current.revoked_at) {
      const recovered = await recoverRotation(current, requestId, client);
      if (!recovered) throw Object.assign(new Error('Invalid refresh token'), { statusCode: 401 });
      await client.query('COMMIT');
      return recovered;
    }
    const token = await issueRefreshToken({
      userId: current.user_id,
      deviceId: current.device_id,
      userAgent,
      ip,
      rotatedFromId: current.id,
      tokenId: successorId(current, requestId) || randomUUID(),
      executor: client,
    });
    await client.query('UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1', [current.id]);
    await client.query('COMMIT');
    return token;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function revokeRefreshToken(userId, deviceId) {
  await revokeDeviceTokens(userId, deviceId);
}

async function revokeToken(tokenId) {
  await db.query(
    `UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1 AND revoked_at IS NULL`,
    [tokenId]
  );
}

async function revokeDeviceTokens(userId, deviceId) {
  await db.query(
    `
    UPDATE refresh_tokens
    SET revoked_at = NOW()
    WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL
    `,
    [userId, deviceId]
  );
}

async function handleReuse(tokenRow) {
  await db.query(
    `
    UPDATE refresh_tokens
    SET reuse_detected_at = NOW(),
        revoked_at = COALESCE(revoked_at, NOW())
    WHERE id = $1
    `,
    [tokenRow.id]
  );
  await revokeDeviceTokens(tokenRow.user_id, tokenRow.device_id);
}

async function revokeAllUserTokens(userId) {
  const revokedTokensResult = await db.query(
    `
    UPDATE refresh_tokens
    SET revoked_at = NOW()
    WHERE user_id = $1 AND revoked_at IS NULL
    RETURNING id
    `,
    [userId]
  );

  await db.query(
    `
    UPDATE user_devices
    SET is_active = false
    WHERE user_id = $1 AND is_active = true
    `,
    [userId]
  );

  const userResult = await db.query(
    `
    UPDATE users
    SET token_version = COALESCE(token_version, 1) + 1
    WHERE id = $1
    RETURNING token_version
    `,
    [userId]
  );

  const newTokenVersion =
    userResult.rows && userResult.rows[0] ? userResult.rows[0].token_version : 1;

  return {
    revokedTokensCount: revokedTokensResult.rows.length,
    newTokenVersion,
  };
}

module.exports = {
  signAccessToken,
  verifyRefreshToken,
  issueRefreshToken,
  rotateRefreshToken,
  revokeRefreshToken,
  revokeAllUserTokens,
};
