'use strict';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const READ_BACKUP_STATUS_SQL = 'SELECT backup_status.read_status($1::uuid) AS status';
const READ_CONFLICTS_SQL = `
  SELECT id, entity, field, strategy, user_acknowledged, created_at,
         local_value, server_value, chosen_value
    FROM public.sync_conflicts
   WHERE profile_id = $1
   ORDER BY created_at DESC, id DESC
   LIMIT 50`;

function unavailableStatus(reason = 'verified_status_not_published') {
  return {
    latestBackup: null,
    latestRestoreDrill: null,
    backupAvailability: 'unavailable',
    backupStatusReason: reason,
    backupVerification: null,
  };
}

function isoDate(value) {
  if (!(typeof value === 'string' || value instanceof Date)) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

// The database RPC is already a projection, but maintain an independent
// allowlist at the HTTP boundary so new operational columns never leak.
function sanitizeStatus(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return unavailableStatus();
  if (!['available', 'stale'].includes(value.backupAvailability)) return unavailableStatus();
  const backup = value.latestBackup;
  const drill = value.latestRestoreDrill;
  const proof = value.backupVerification;
  const completed = isoDate(backup?.ran_at);
  const verified = isoDate(drill?.ran_at);
  const published = isoDate(proof?.publishedAt);
  if (!completed || !verified || !published || drill?.restored_ok !== true ||
      proof?.protocol !== 'paired_v5' || proof?.databaseRestoreVerified !== true ||
      !['passed', 'not_run'].includes(proof.applicationCheck) ||
      !['passed', 'not_run'].includes(proof.upgradeCheck) ||
      !['local', 'offhost'].includes(proof.storage) ||
      !['success', 'stale'].includes(backup.status)) return unavailableStatus();
  const size = Number(backup.size_bytes);
  if (!Number.isSafeInteger(size) || size <= 0) return unavailableStatus();
  return {
    latestBackup: { ran_at: completed, status: value.backupAvailability === 'stale' ? 'stale' : 'success', size_bytes: size },
    latestRestoreDrill: { ran_at: verified, restored_ok: true },
    backupAvailability: value.backupAvailability,
    backupStatusReason: value.backupAvailability === 'stale' ? 'verified_status_stale' : null,
    backupVerification: {
      protocol: 'paired_v5', databaseRestoreVerified: true,
      applicationCheck: proof.applicationCheck, upgradeCheck: proof.upgradeCheck,
      storage: proof.storage, publishedAt: published,
    },
  };
}

function sanitizeConflict(row) {
  return {
    id: row.id, entity: row.entity, field: row.field, strategy: row.strategy,
    user_acknowledged: row.user_acknowledged, created_at: row.created_at,
    local_value: row.local_value, server_value: row.server_value, chosen_value: row.chosen_value,
  };
}

function createBackupStatusHandlers({ withUserClient, logger = console } = {}) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  async function readStatus(profileId, includeConflicts) {
    try {
      return await withUserClient(profileId, async (client) => {
        const response = await client.query(READ_BACKUP_STATUS_SQL, [profileId]);
        const status = sanitizeStatus(response.rows[0]?.status);
        if (!includeConflicts) return status;
        const conflicts = await client.query(READ_CONFLICTS_SQL, [profileId]);
        return { ...status, conflicts: conflicts.rows.slice(0, 50).map(sanitizeConflict), conflictAvailability: 'available' };
      });
    } catch (_) {
      // No raw SQL error, object paths, customer values or identifiers.
      if (logger && typeof logger.error === 'function') logger.error('Backup status projection unavailable');
      return { ...unavailableStatus('status_service_unavailable'),
        ...(includeConflicts ? { conflicts: [], conflictAvailability: 'unavailable' } : {}) };
    }
  }

  function hasIdentity(req, res) {
    if (typeof req.userId === 'string' && UUID_RE.test(req.userId)) return true;
    res.status(401).json({ error: 'session_invalid' });
    return false;
  }

  return {
    async getBackupStatus(req, res) {
      if (!hasIdentity(req, res)) return;
      const status = await readStatus(req.userId, true);
      // Older clients do not understand conflictAvailability. Preserve
      // their retry/error screen rather than rendering an unavailable
      // conflict log as an empty one.
      return res.status(status.conflictAvailability === 'unavailable' ? 503 : 200).json(status);
    },
    async postBackupRuns(req, res) {
      if (!hasIdentity(req, res)) return;
      const status = await readStatus(req.userId, false);
      return res.status(409).json({
        error: 'manual_backup_not_supported',
        message: 'Backups run automatically on a schedule and cannot be triggered from the app.',
        lastSuccessfulBackup: status.latestBackup?.status === 'success' ? status.latestBackup : null,
        backupAvailability: status.backupAvailability,
        backupStatusReason: status.backupStatusReason,
      });
    },
  };
}

module.exports = {
  READ_BACKUP_STATUS_SQL, READ_CONFLICTS_SQL, createBackupStatusHandlers,
  sanitizeStatus, unavailableStatus,
};
