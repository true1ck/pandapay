'use strict';

// How many live accounts one phone has held. It starts in log-only mode: past the
// limit a sign-up is recorded in the audit log and let through, so the numbers can be
// read before anything is refused. Switch enforcement on with DEVICE_ACCOUNT_LIMIT_ENFORCE.
//
// The identifier is the install's own id, so it is a speed bump and a signal, not a
// guarantee: a reinstall makes a new one. Real device attestation (Play Integrity,
// App Attest) is what would bind accounts to the hardware.
//
// It never blocks on its own failure. If the count cannot be read the sign-up carries on.

// Every install before the per-install id sent the same literal, and a missing id
// becomes 'unknown-device'. Counting those would call everyone one phone.
const SHARED_PLACEHOLDERS = new Set(['unknown-device', 'app-mobile']);

const ACTION = 'device_account_limit';

function createDeviceAccountLimit({ query, audit, limit = 3, enforce = false, logger = console }) {
  const active = Number.isInteger(limit) && limit > 0;

  const usable = deviceId => active && typeof deviceId === 'string' && deviceId.length > 0 && !SHARED_PLACEHOLDERS.has(deviceId);

  async function liveAccountsOn(deviceId) {
    const { rows } = await query(
      `SELECT COUNT(DISTINCT d.user_id)::int AS accounts
         FROM user_devices d JOIN users u ON u.id = d.user_id
        WHERE d.device_identifier = $1 AND u.deleted = FALSE`,
      [deviceId],
    );
    return rows[0]?.accounts ?? 0;
  }

  async function record(status, { userId = null, deviceId, ip, userAgent, accounts }) {
    try {
      await audit({
        userId, action: ACTION, status, riskLevel: 'SUSPICIOUS', deviceId, ipAddress: ip || null, userAgent: userAgent || null,
        meta: { accounts, limit, enforced: enforce === true },
      });
    } catch (error) {
      logger.warn?.('[device-limit] audit failed', error?.code || error?.name);
    }
  }

  /**
   * Before a new account is created on this device. `allowed: false` only when
   * enforcement is on and the device already holds `limit` live accounts.
   */
  async function admitNewAccount({ deviceId, ip, userAgent }) {
    if (!usable(deviceId)) return { allowed: true, accounts: null };
    let accounts;
    try { accounts = await liveAccountsOn(deviceId); } catch (error) {
      logger.warn?.('[device-limit] count failed', error?.code || error?.name);
      return { allowed: true, accounts: null };
    }
    if (accounts < limit) return { allowed: true, accounts };
    await record(enforce ? 'blocked' : 'flagged', { deviceId, ip, userAgent, accounts });
    return { allowed: !enforce, accounts };
  }

  /** After an account was created some other way (Google). Records only; never refuses. */
  async function flagNewAccount({ userId, deviceId, ip, userAgent }) {
    if (!usable(deviceId)) return { flagged: false };
    let accounts;
    try { accounts = await liveAccountsOn(deviceId); } catch (error) {
      logger.warn?.('[device-limit] count failed', error?.code || error?.name);
      return { flagged: false };
    }
    if (accounts <= limit) return { flagged: false, accounts };
    await record('flagged', { userId, deviceId, ip, userAgent, accounts });
    return { flagged: true, accounts };
  }

  return { admitNewAccount, flagNewAccount, liveAccountsOn };
}

module.exports = { createDeviceAccountLimit, SHARED_PLACEHOLDERS, ACTION };
