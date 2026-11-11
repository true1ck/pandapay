'use strict';

// How many accounts one phone has held, to stop one person opening account after
// account on the same phone for a free trial. It starts in log-only mode: past the
// limit a sign-up is recorded in the audit log and let through, so the numbers can be
// read before anything is refused. Switch enforcement on with DEVICE_ACCOUNT_LIMIT_ENFORCE.
//
// What counts as "one phone" depends on the app build:
//  * A build with the phone id (app 1.0.18 build 154 and later) sends `k2-...` on iOS
//    (a Keychain id that survives deleting the app) or `a2-...` on Android (a hash of the
//    Android ID, which survives a reinstall). Both last until the phone is reset.
//  * Older builds send a per-install random id, which a reinstall replaces. That is a
//    weak signal: it is still counted, but it cannot be trusted to stop anyone.
// With DEVICE_REQUIRE_STRONG_ID on (and enforcement on), a new account from a weak id is
// refused, so an old build cannot be used to dodge the limit.
//
// Deleted accounts count by default (DEVICE_ACCOUNT_LIMIT_COUNT_DELETED), because deleting
// an account and making a new one is exactly how a second free trial is taken.
//
// Both ids come from the app, so this stops an ordinary person, not someone who rewrites
// the app or roots the phone. Real device attestation (Play Integrity, App Attest) is what
// would bind accounts to the hardware.
//
// It never blocks on its own failure. If the count cannot be read the sign-up carries on.

// Every install before the per-install id sent the same literal, and a missing id
// becomes 'unknown-device'. Counting those would call everyone one phone.
const SHARED_PLACEHOLDERS = new Set(['unknown-device', 'app-mobile']);

const ACTION = 'device_account_limit';

// k2- is the iOS Keychain id, a2- the Android one (a 32-character hash).
const STRONG_DEVICE_ID = /^(?:k2-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|a2-[0-9a-f]{32})$/i;

function isStrongDeviceId(deviceId) {
  return typeof deviceId === 'string' && STRONG_DEVICE_ID.test(deviceId);
}

function createDeviceAccountLimit({
  query, audit, limit = 3, enforce = false, countDeleted = true, requireStrongId = false, logger = console,
}) {
  const active = Number.isInteger(limit) && limit > 0;

  const usable = deviceId => active && typeof deviceId === 'string' && deviceId.length > 0 && !SHARED_PLACEHOLDERS.has(deviceId);

  async function accountsOn(deviceId) {
    const { rows } = await query(
      `SELECT COUNT(DISTINCT d.user_id)::int AS accounts
         FROM user_devices d JOIN users u ON u.id = d.user_id
        WHERE d.device_identifier = $1${countDeleted ? '' : ' AND u.deleted = FALSE'}`,
      [deviceId],
    );
    return rows[0]?.accounts ?? 0;
  }

  async function record(status, { userId = null, deviceId, ip, userAgent, accounts, reason }) {
    try {
      await audit({
        userId, action: ACTION, status, riskLevel: 'SUSPICIOUS', deviceId, ipAddress: ip || null, userAgent: userAgent || null,
        meta: { accounts, limit, enforced: enforce === true, ...(reason ? { reason } : {}) },
      });
    } catch (error) {
      logger.warn?.('[device-limit] audit failed', error?.code || error?.name);
    }
  }

  /**
   * Before a new account is created on this device. `allowed: false` only when
   * enforcement is on and either the device already holds `limit` accounts or
   * (with requireStrongId) the build did not send a phone id. `reason` says which.
   */
  async function admitNewAccount({ deviceId, ip, userAgent }) {
    if (active && enforce && requireStrongId && !isStrongDeviceId(deviceId)) {
      await record('blocked', {
        deviceId: typeof deviceId === 'string' && deviceId ? deviceId : 'unknown-device',
        ip, userAgent, accounts: null, reason: 'weak_device_id',
      });
      return { allowed: false, accounts: null, reason: 'weak_device_id' };
    }
    if (!usable(deviceId)) return { allowed: true, accounts: null };
    let accounts;
    try { accounts = await accountsOn(deviceId); } catch (error) {
      logger.warn?.('[device-limit] count failed', error?.code || error?.name);
      return { allowed: true, accounts: null };
    }
    if (accounts < limit) return { allowed: true, accounts };
    await record(enforce ? 'blocked' : 'flagged', { deviceId, ip, userAgent, accounts });
    return enforce ? { allowed: false, accounts, reason: ACTION } : { allowed: true, accounts };
  }

  /** After an account was created some other way (Google). Records only; never refuses. */
  async function flagNewAccount({ userId, deviceId, ip, userAgent }) {
    if (!usable(deviceId)) return { flagged: false };
    let accounts;
    try { accounts = await accountsOn(deviceId); } catch (error) {
      logger.warn?.('[device-limit] count failed', error?.code || error?.name);
      return { flagged: false };
    }
    if (accounts <= limit) return { flagged: false, accounts };
    await record('flagged', { userId, deviceId, ip, userAgent, accounts });
    return { flagged: true, accounts };
  }

  return { admitNewAccount, flagNewAccount, liveAccountsOn: accountsOn, accountsOn };
}

module.exports = { createDeviceAccountLimit, isStrongDeviceId, SHARED_PLACEHOLDERS, ACTION };
