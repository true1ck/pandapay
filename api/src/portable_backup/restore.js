'use strict';

const crypto = require('node:crypto');
const { EXCLUDED_FIELDS, PORTABLE_SECTIONS, canonicalJson, canonicalize } = require('./contract');

const MAX_SECTION_BYTES = 64 * 1024 * 1024;
const MAX_SECTION_RECORDS = 200_000;
const SESSION_TTL_HOURS = 24;
const SHA256_EMPTY = crypto.createHash('sha256').update('').digest('hex');
const SECTION_BY_NAME = new Map(PORTABLE_SECTIONS.map((section) => [section.name, section]));

class PortableRestoreError extends Error {
  constructor(code, status = 400, details = undefined) {
    super(code);
    this.name = 'PortableRestoreError';
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

function assertUuid(value, code = 'invalid_backup_id') {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new PortableRestoreError(code);
  }
  return value.toLowerCase();
}

function sectionDeclaration(manifest, name) {
  const sections = manifest?.sections;
  if (sections && !Array.isArray(sections) && sections[name]) return sections[name];
  if (Array.isArray(sections)) return sections.find((section) => section?.name === name) || null;
  if (manifest?.section_digests?.[name]) {
    return {
      count: manifest.section_counts?.[name],
      plaintext_bytes: manifest.section_bytes?.[name],
      sha256: manifest.section_digests[name],
    };
  }
  return null;
}

function declaredCount(declaration) {
  return Number(declaration?.count ?? declaration?.record_count);
}

function declaredBytes(declaration) {
  return Number(declaration?.plaintext_bytes ?? declaration?.byte_length);
}

function validateManifest({ manifest, backupId, profileId, snapshotRevision }) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw new PortableRestoreError('manifest_required');
  }
  const accountBinding = manifest.account_binding ?? manifest.account_id;
  if (accountBinding !== profileId) throw new PortableRestoreError('account_mismatch', 409);
  const schemaVersion = String(manifest.schema_version ?? '');
  const schemaMajor = Number(schemaVersion.match(/\d+/)?.[0] || 0);
  if (Number(manifest.format_version) !== 1 || schemaMajor !== 1) {
    throw new PortableRestoreError('unsupported_backup_version');
  }
  if (!manifest.complete) throw new PortableRestoreError('backup_incomplete', 409);
  if (manifest.backup_id && assertUuid(manifest.backup_id) !== backupId) {
    throw new PortableRestoreError('backup_id_mismatch');
  }
  const revision = String(snapshotRevision || manifest.snapshot_revision || manifest.server_revision || '').trim();
  if (!revision) throw new PortableRestoreError('snapshot_revision_required');
  for (const section of PORTABLE_SECTIONS) {
    const declaration = sectionDeclaration(manifest, section.name);
    if (!declaration || !Number.isSafeInteger(declaredCount(declaration))
      || declaredCount(declaration) < 0
      || !Number.isSafeInteger(declaredBytes(declaration))
      || declaredBytes(declaration) < 0
      || typeof declaration.sha256 !== 'string'
      || !/^[0-9a-f]{64}$/.test(declaration.sha256)) {
      throw new PortableRestoreError('manifest_section_invalid', 422, { section: section.name });
    }
  }
  return {
    formatVersion: Number(manifest.format_version),
    schemaVersion,
    snapshotRevision: revision,
    snapshotAt: manifest.snapshot_at || null,
  };
}

function stableId(sectionName, record, ordinal) {
  if (sectionName === 'transaction_tag_links') {
    if (!record.transaction_id || !record.tag_id) throw new PortableRestoreError('record_id_required', 422);
    return `${record.transaction_id}:${record.tag_id}`;
  }
  if (sectionName === 'settings') {
    if (!record.profile_id) throw new PortableRestoreError('record_id_required', 422, { section: sectionName, ordinal });
    return record.profile_id;
  }
  if (typeof record.id !== 'string' || !record.id) {
    throw new PortableRestoreError('record_id_required', 422, { section: sectionName, ordinal });
  }
  return record.id;
}

function normalizeRecord(record, profileId, sectionName, ordinal) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw new PortableRestoreError('record_invalid', 422, { section: sectionName, ordinal });
  }
  if (record.profile_id !== undefined && record.profile_id !== profileId) {
    throw new PortableRestoreError('record_ownership_mismatch', 409, { section: sectionName, ordinal });
  }
  const canonical = JSON.parse(canonicalJson(record));
  return { record: canonical, stableId: stableId(sectionName, canonical, ordinal) };
}

function parseSectionNdjson(input, sectionName, profileId) {
  if (!SECTION_BY_NAME.has(sectionName)) throw new PortableRestoreError('unknown_section', 404);
  const text = Buffer.isBuffer(input) ? input.toString('utf8') : String(input || '');
  const size = Buffer.byteLength(text);
  if (size > MAX_SECTION_BYTES) throw new PortableRestoreError('section_too_large', 413);
  if (text.includes('\u0000')) throw new PortableRestoreError('section_invalid_utf8', 422);
  const records = [];
  const ids = new Set();
  const digest = crypto.createHash('sha256');
  let bytes = 0;
  for (const [ordinal, line] of text.split('\n').entries()) {
    if (!line) continue;
    const parsed = (() => {
      try { return JSON.parse(line); } catch (_) { throw new PortableRestoreError('section_invalid_ndjson', 422, { ordinal }); }
    })();
    if (parsed?.type === 'record') {
      if (parsed.section !== sectionName) throw new PortableRestoreError('section_name_mismatch', 422, { ordinal });
      if (parsed.record === undefined) throw new PortableRestoreError('record_invalid', 422, { ordinal });
    }
    const inputRecord = parsed?.type === 'record' ? parsed.record : parsed;
    const normalized = normalizeRecord(inputRecord, profileId, sectionName, records.length);
    if (ids.has(normalized.stableId)) throw new PortableRestoreError('duplicate_record_id', 409, { section: sectionName, id: normalized.stableId });
    ids.add(normalized.stableId);
    const canonicalLine = `${canonicalJson(normalized.record)}\n`;
    digest.update(canonicalLine);
    bytes += Buffer.byteLength(canonicalLine);
    records.push({ ordinal: records.length, stableId: normalized.stableId, record: normalized.record, canonicalSha256: crypto.createHash('sha256').update(canonicalLine).digest('hex') });
    if (records.length > MAX_SECTION_RECORDS) throw new PortableRestoreError('section_record_limit', 413);
  }
  return { records, count: records.length, bytes, sha256: digest.digest('hex') };
}

async function readRequestBody(req, maxBytes = MAX_SECTION_BYTES) {
  if (req.body !== undefined && req.body !== null) {
    if (Buffer.isBuffer(req.body) || typeof req.body === 'string') return req.body;
    return JSON.stringify(req.body);
  }
  if (!req || typeof req.on !== 'function') return '';
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    total += buffer.length;
    if (total > maxBytes) throw new PortableRestoreError('section_too_large', 413);
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

async function inTransaction(pool, profileId, fn) {
  const client = await pool.connect();
  let done = false,discard;
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [profileId]);
    if(pool.accountAccessFence)await pool.accountAccessFence(client,profileId);
    const result = await fn(client);
    await client.query('COMMIT');
    done = true;
    return result;
  } catch (error) {
    try{await client.query('ROLLBACK');}catch(rollbackError){discard=rollbackError;}
    throw error;
  } finally {
    if (!done)try{await client.query('ROLLBACK');}catch(error){discard=error;}
    client.release(discard);
  }
}

async function serverRevision(client, profileId) {
  const result = await client.query(
    'SELECT COALESCE(max(server_seq), 0)::text AS server_revision FROM public.change_log WHERE profile_id = $1',
    [profileId],
  );
  return String(result.rows[0]?.server_revision || '0');
}

function sessionResponse(row, extra = {}) {
  return {
    session_id: row.id,
    backup_id: row.backup_id,
    state: row.state,
    expires_at: row.expires_at,
    ...extra,
  };
}

async function createRestoreSession({ pool, profileId, input }) {
  const backupId = assertUuid(input?.backup_id || input?.manifest?.backup_id);
  const idempotencyKey = typeof input?.idempotency_key === 'string' ? input.idempotency_key.trim() : '';
  if (!idempotencyKey || idempotencyKey.length > 200) throw new PortableRestoreError('idempotency_key_required');
  const manifest = input.manifest;
  const metadata = validateManifest({ manifest, backupId, profileId, snapshotRevision: input.snapshot_revision });
  return inTransaction(pool, profileId, async (client) => {
    const existing = await client.query(
      `SELECT * FROM portable_restore_sessions
        WHERE profile_id = $1 AND (idempotency_key = $2 OR backup_id = $3)
        ORDER BY created_at DESC LIMIT 1`,
      [profileId, idempotencyKey, backupId],
    );
    if (existing.rows[0]) {
      const row = existing.rows[0];
      if (row.backup_id !== backupId) {
        throw new PortableRestoreError('restore_session_identity_conflict', 409);
      }
      return sessionResponse(row, { resumed: true });
    }
    const ledger = await client.query(
      'SELECT session_id, result, committed_at FROM portable_backup_ledger WHERE profile_id = $1 AND backup_id = $2',
      [profileId, backupId],
    );
    if (ledger.rows[0]) return { session_id: ledger.rows[0].session_id, backup_id: backupId, state: 'committed', resumed: true, result: ledger.rows[0].result, committed_at: ledger.rows[0].committed_at };
    const inserted = await client.query(
      `INSERT INTO portable_restore_sessions
         (profile_id, backup_id, idempotency_key, format_version, schema_version,
          manifest, snapshot_revision, snapshot_at, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, now() + ($9::text || ' hours')::interval)
       ON CONFLICT DO NOTHING
       RETURNING *`,
      [profileId, backupId, idempotencyKey, metadata.formatVersion, metadata.schemaVersion,
        manifest, metadata.snapshotRevision, metadata.snapshotAt, SESSION_TTL_HOURS],
    );
    if (inserted.rows[0]) return sessionResponse(inserted.rows[0], { resumed: false });
    const raced = await client.query(
      `SELECT * FROM portable_restore_sessions
        WHERE profile_id = $1 AND (idempotency_key = $2 OR backup_id = $3)
        ORDER BY created_at DESC LIMIT 1`,
      [profileId, idempotencyKey, backupId],
    );
    if (raced.rows[0]?.backup_id === backupId) return sessionResponse(raced.rows[0], { resumed: true });
    throw new PortableRestoreError('restore_session_identity_conflict', 409);
  });
}

async function loadSession(client, profileId, sessionId, forUpdate = false) {
  const id = assertUuid(sessionId, 'invalid_session_id');
  const result = await client.query(
    `SELECT * FROM portable_restore_sessions
      WHERE id = $1 AND profile_id = $2${forUpdate ? ' FOR UPDATE' : ''}`,
    [id, profileId],
  );
  const row = result.rows[0];
  if (!row) throw new PortableRestoreError('restore_session_not_found', 404);
  if (row.state === 'staging' && row.expires_at && new Date(row.expires_at).getTime() <= Date.now()) {
    await client.query("UPDATE portable_restore_sessions SET state = 'expired', updated_at = now() WHERE id = $1", [id]);
    throw new PortableRestoreError('restore_session_expired', 410);
  }
  return row;
}

async function uploadRestoreSection({ pool, profileId, sessionId, sectionName, input }) {
  if (!SECTION_BY_NAME.has(sectionName)) throw new PortableRestoreError('unknown_section', 404);
  const parsed = parseSectionNdjson(input, sectionName, profileId);
  return inTransaction(pool, profileId, async (client) => {
    const session = await loadSession(client, profileId, sessionId, true);
    if (session.state !== 'staging') throw new PortableRestoreError('restore_session_not_writable', 409);
    const declaration = sectionDeclaration(session.manifest, sectionName);
    if (declaredCount(declaration) !== parsed.count
      || declaredBytes(declaration) !== parsed.bytes
      || declaration.sha256 !== parsed.sha256) {
      throw new PortableRestoreError('section_digest_mismatch', 422, { section: sectionName });
    }
    const existing = await client.query(
      'SELECT * FROM portable_restore_sections WHERE session_id = $1 AND section_name = $2 FOR UPDATE',
      [session.id, sectionName],
    );
    if (existing.rows[0]) {
      if (existing.rows[0].received_sha256 === parsed.sha256 && Number(existing.rows[0].received_count) === parsed.count) {
        return { session_id: session.id, section: sectionName, state: 'uploaded', idempotent: true, count: parsed.count, sha256: parsed.sha256 };
      }
      throw new PortableRestoreError('section_upload_conflict', 409, { section: sectionName });
    }
    await client.query(
      `INSERT INTO portable_restore_sections
         (session_id, profile_id, section_name, declared_count, declared_bytes,
          declared_sha256, received_count, received_bytes, received_sha256)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [session.id, profileId, sectionName, parsed.count, parsed.bytes, parsed.sha256, parsed.count, parsed.bytes, parsed.sha256],
    );
    for (const row of parsed.records) {
      await client.query(
        `INSERT INTO portable_restore_records
           (session_id, profile_id, section_name, ordinal, stable_id, record, canonical_sha256)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)`,
        [session.id, profileId, sectionName, row.ordinal, row.stableId, row.record, row.canonicalSha256],
      );
    }
    await client.query('UPDATE portable_restore_sessions SET updated_at = now() WHERE id = $1', [session.id]);
    return { session_id: session.id, section: sectionName, state: 'uploaded', idempotent: false, count: parsed.count, sha256: parsed.sha256 };
  });
}

function existingRecordQuery(sectionName, stableIdValue, profileId) {
  const section = SECTION_BY_NAME.get(sectionName);
  if (sectionName === 'transaction_tag_links') {
    const [transactionId, tagId] = String(stableIdValue).split(':');
    return {
      text: `SELECT to_jsonb(t) - ARRAY[${EXCLUDED_FIELDS.map((field) => `'${field}'`).join(', ')}]::text[] AS record
               FROM public.transaction_tag_links t
              WHERE t.profile_id = $1 AND t.transaction_id = $2 AND t.tag_id = $3`,
      values: [profileId, transactionId, tagId],
    };
  }
  if (sectionName === 'transaction_splits') {
    return {
      text: `SELECT to_jsonb(t) - ARRAY[${EXCLUDED_FIELDS.map((field) => `'${field}'`).join(', ')}]::text[] AS record
               FROM public.transaction_splits t
              WHERE t.id = $1
                AND EXISTS (SELECT 1 FROM public.transactions owner_txn WHERE owner_txn.id = t.transaction_id AND owner_txn.profile_id = $2)`,
      values: [stableIdValue, profileId],
    };
  }
  if (sectionName === 'settings') {
    return {
      text: `SELECT to_jsonb(t) - ARRAY[${EXCLUDED_FIELDS.map((field) => `'${field}'`).join(', ')}]::text[] AS record
               FROM public.user_settings t
              WHERE t.profile_id = $1`,
      values: [profileId],
    };
  }
  const alias = section.alias;
  const filter = sectionName === 'profile' ? `${alias}.id = $1` : `${alias}.id = $2 AND ${alias}.profile_id = $1`;
  return {
    text: `SELECT to_jsonb(${alias}) - ARRAY[${EXCLUDED_FIELDS.map((field) => `'${field}'`).join(', ')}]::text[] AS record
             FROM public.${section.table} ${alias}
            WHERE ${filter}`,
    values: sectionName === 'profile' ? [profileId] : [profileId, stableIdValue],
  };
}

async function currentRecord(client, profileId, sectionName, stableIdValue) {
  const result = await client.query(existingRecordQuery(sectionName, stableIdValue, profileId));
  return result.rows[0]?.record || null;
}

async function buildRestorePlan(client, profileId, session) {
  const sectionRows = await client.query(
    'SELECT * FROM portable_restore_sections WHERE session_id = $1 AND profile_id = $2 ORDER BY section_name',
    [session.id, profileId],
  );
  const byName = new Map(sectionRows.rows.map((row) => [row.section_name, row]));
  const missingSections = PORTABLE_SECTIONS.map(({ name }) => name).filter((name) => !byName.has(name));
  const noops = [];
  const missing = [];
  const conflicts = [];
  for (const section of PORTABLE_SECTIONS) {
    const stagedSection = byName.get(section.name);
    if (!stagedSection) continue;
    const records = await client.query(
      `SELECT ordinal, stable_id, record FROM portable_restore_records
        WHERE session_id = $1 AND profile_id = $2 AND section_name = $3 ORDER BY ordinal`,
      [session.id, profileId, section.name],
    );
    for (const row of records.rows) {
      const current = await currentRecord(client, profileId, section.name, row.stable_id);
      if (!current) {
        missing.push({ section: section.name, id: row.stable_id });
        continue;
      }
      const expected = canonicalJson(row.record);
      const actual = canonicalJson(current);
      if (expected === actual) {
        noops.push({ section: section.name, id: row.stable_id });
      } else {
        conflicts.push({ section: section.name, id: row.stable_id, reason: 'digest_mismatch' });
      }
    }
  }
  return { missingSections, noops, missing, conflicts, serverRevision: await serverRevision(client, profileId) };
}

function assertNoConflicts(plan) {
  if (plan.missingSections.length || plan.conflicts.length) {
    throw new PortableRestoreError('restore_conflict', 409, plan);
  }
}

async function previewRestore({ pool, profileId, sessionId }) {
  return inTransaction(pool, profileId, async (client) => {
    const session = await loadSession(client, profileId, sessionId, false);
    if (session.state === 'committed') return { ...sessionResponse(session), result: session.result, idempotent: true };
    if (session.state !== 'staging') throw new PortableRestoreError('restore_session_not_previewable', 409);
    const plan = await buildRestorePlan(client, profileId, session);
    const previewRevision = plan.serverRevision;
    await client.query('UPDATE portable_restore_sessions SET preview_revision = $2, updated_at = now() WHERE id = $1', [session.id, previewRevision]);
    return {
      ...sessionResponse(session, { state: 'staging' }),
      preview_revision: previewRevision,
      sections: PORTABLE_SECTIONS.map(({ name }) => ({ name, uploaded: !plan.missingSections.includes(name) })),
      missing_sections: plan.missingSections,
      no_ops: plan.noops,
      missing: plan.missing,
      conflicts: plan.conflicts,
    };
  });
}

function insertRecordQuery(sectionName, record) {
  const section = SECTION_BY_NAME.get(sectionName);
  const keys = Object.keys(record).filter((key) => /^[a-z_][a-z0-9_]*$/.test(key) && !EXCLUDED_FIELDS.includes(key)).sort();
  if (!keys.length) throw new PortableRestoreError('record_empty', 422, { section: sectionName });
  const placeholders = keys.map((_, index) => `$${index + 1}`).join(', ');
  return {
    text: `INSERT INTO public.${section.table} (${keys.join(', ')}) VALUES (${placeholders}) ON CONFLICT DO NOTHING`,
    values: keys.map((key) => record[key]),
  };
}

async function commitRestore({ pool, profileId, sessionId, previewRevision }) {
  return inTransaction(pool, profileId, async (client) => {
    const session = await loadSession(client, profileId, sessionId, true);
    const ledger = await client.query(
      'SELECT result, committed_at FROM portable_backup_ledger WHERE profile_id = $1 AND backup_id = $2',
      [profileId, session.backup_id],
    );
    if (ledger.rows[0]) return { ...sessionResponse(session, { state: 'committed' }), result: ledger.rows[0].result, idempotent: true };
    if (session.state !== 'staging') throw new PortableRestoreError('restore_session_not_committable', 409);
    if (!previewRevision || String(previewRevision) !== String(session.preview_revision || '')) {
      throw new PortableRestoreError('preview_required_or_stale', 409);
    }
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))', [`portable-restore:${profileId}`]);
    const currentRevision = await serverRevision(client, profileId);
    if (String(currentRevision) !== String(session.preview_revision)) throw new PortableRestoreError('preview_required_or_stale', 409);
    const plan = await buildRestorePlan(client, profileId, session);
    assertNoConflicts(plan);
    let insertedCount = 0;
    for (const section of PORTABLE_SECTIONS) {
      const records = await client.query(
        `SELECT stable_id, record FROM portable_restore_records
          WHERE session_id = $1 AND profile_id = $2 AND section_name = $3 ORDER BY ordinal`,
        [session.id, profileId, section.name],
      );
      for (const row of records.rows) {
        if (!plan.missing.some((item) => item.section === section.name && item.id === row.stable_id)) continue;
        const result = await client.query(insertRecordQuery(section.name, row.record));
        insertedCount += result.rowCount || 0;
      }
    }
    const result = {
      inserted: insertedCount,
      no_ops: plan.noops.length,
      backup_id: session.backup_id,
      server_revision: currentRevision,
    };
    await client.query(
      'INSERT INTO portable_backup_ledger (profile_id, backup_id, session_id, result) VALUES ($1, $2, $3, $4::jsonb)',
      [profileId, session.backup_id, session.id, result],
    );
    await client.query(
      "UPDATE portable_restore_sessions SET state = 'committed', result = $2::jsonb, updated_at = now() WHERE id = $1",
      [session.id, result],
    );
    return { ...sessionResponse(session, { state: 'committed' }), result, idempotent: false };
  });
}

async function restoreStatus({ pool, profileId, sessionId }) {
  return inTransaction(pool, profileId, async (client) => {
    const session = await loadSession(client, profileId, sessionId, false);
    const sections = await client.query(
      `SELECT section_name, declared_count, received_count, declared_bytes,
              received_bytes, declared_sha256, received_sha256, uploaded_at
         FROM portable_restore_sections WHERE session_id = $1 AND profile_id = $2
        ORDER BY section_name`,
      [session.id, profileId],
    );
    return { ...sessionResponse(session), preview_revision: session.preview_revision, sections: sections.rows };
  });
}

async function cancelRestore({ pool, profileId, sessionId }) {
  return inTransaction(pool, profileId, async (client) => {
    const session = await loadSession(client, profileId, sessionId, true);
    if (session.state === 'committed') throw new PortableRestoreError('restore_already_committed', 409);
    await client.query("UPDATE portable_restore_sessions SET state = 'cancelled', updated_at = now() WHERE id = $1", [session.id]);
    return sessionResponse(session, { state: 'cancelled' });
  });
}

module.exports = {
  MAX_SECTION_BYTES,
  MAX_SECTION_RECORDS,
  PortableRestoreError,
  SHA256_EMPTY,
  SECTION_BY_NAME,
  assertUuid,
  buildRestorePlan,
  cancelRestore,
  commitRestore,
  createRestoreSession,
  insertRecordQuery,
  normalizeRecord,
  parseSectionNdjson,
  previewRestore,
  readRequestBody,
  restoreStatus,
  sectionDeclaration,
  stableId,
  assertNoConflicts,
  uploadRestoreSection,
  validateManifest,
};
