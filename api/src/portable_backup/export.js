'use strict';

const crypto = require('node:crypto');
const { canonicalJson, EXCLUDED_FIELDS, FORMAT_VERSION, MEDIA_TYPE, PORTABLE_SECTIONS, SCHEMA_VERSION } = require('./contract');

const DEFAULT_BATCH_SIZE = 256;
const DEFAULT_STATEMENT_TIMEOUT_MS = 120_000;
const DEFAULT_MAX_EXPORT_DURATION_MS = 10 * 60_000;
const DEFAULT_BACKPRESSURE_TIMEOUT_MS = 30_000;
// These caps bound total unencrypted NDJSON response bytes and record count.
// The separate encrypted paired SQL backup path is not governed here.
const DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const DEFAULT_MAX_RECORDS = 1_000_000;
const MAX_BATCH_SIZE = 2_000;

class PortableBackupExportError extends Error {
  constructor(code, cause) {
    super(code);
    this.name = 'PortableBackupExportError';
    this.code = code;
    this.cause = cause;
  }
}

function sqlForSection(section, batchSize, cursor, offset = 0) {
  const exclusion = EXCLUDED_FIELDS.map((field) => `'${field}'`).join(', ');
  const cursorClause = section.cursor && cursor !== null
    ? ` AND ${section.cursor} > $3`
    : '';
  const offsetClause = section.cursor ? '' : ' OFFSET $3';
  return {
    text: `SELECT to_jsonb(${section.alias}) - ARRAY[${exclusion}]::text[] AS record
             FROM public.${section.table} ${section.alias}
            WHERE ${section.filter}${cursorClause}
            ORDER BY ${section.orderBy}
            LIMIT $2${offsetClause}`,
    values: cursorClause ? [null, batchSize, cursor] : section.cursor ? [null, batchSize] : [null, batchSize, offset],
  };
}

function setProfileValue(query, profileId) {
  query.values[0] = profileId;
  return query;
}

async function writeChunk(res, chunk, state) {
  if (state.cancelled) throw new PortableBackupExportError('export_cancelled');
  const chunkBytes = Buffer.byteLength(chunk);
  if (state.outputBytes + chunkBytes > state.maxOutputBytes) {
    throw new PortableBackupExportError('export_limit_exceeded');
  }
  state.outputBytes += chunkBytes;
  const remainingMs = state.deadline - state.now();
  if (remainingMs <= 0) throw new PortableBackupExportError('export_timeout');
  if (res.write(chunk)) return;
  await new Promise((resolve, reject) => {
    const timeoutMs = Math.min(state.backpressureTimeoutMs, remainingMs);
    const timer = setTimeout(() => {
      cleanup();
      reject(new PortableBackupExportError(state.deadline - state.now() <= 0 ? 'export_timeout' : 'export_backpressure_timeout'));
    }, timeoutMs);
    const onDrain = () => { cleanup(); resolve(); };
    const onClose = () => { cleanup(); reject(new PortableBackupExportError('export_cancelled')); };
    const cleanup = () => {
      clearTimeout(timer);
      res.off('drain', onDrain);
      res.off('close', onClose);
    };
    res.once('drain', onDrain);
    res.once('close', onClose);
  });
}

function envelopeLine(value) {
  return `${canonicalJson(value)}\n`;
}

async function readSnapshotMetadata(client, profileId) {
  const result = await client.query({
    text: `SELECT txid_current_snapshot()::text AS snapshot_revision,
                  now()::text AS snapshot_at,
                  $1::uuid AS account_id`,
    values: [profileId],
  });
  const row = result.rows[0];
  if (!row?.snapshot_revision || !row.snapshot_at) {
    throw new PortableBackupExportError('snapshot_metadata_unavailable');
  }
  return row;
}

async function exportSnapshot({ client, res, profileId, batchSize = DEFAULT_BATCH_SIZE,
  maxDurationMs = DEFAULT_MAX_EXPORT_DURATION_MS,
  backpressureTimeoutMs = DEFAULT_BACKPRESSURE_TIMEOUT_MS,
  maxOutputBytes = DEFAULT_MAX_OUTPUT_BYTES,
  maxRecords = DEFAULT_MAX_RECORDS,
  now = () => Date.now(), backupId = crypto.randomUUID() }) {
  if (!client || typeof client.query !== 'function') throw new TypeError('client is required');
  if (!res || typeof res.write !== 'function') throw new TypeError('writable response is required');
  if (typeof profileId !== 'string' || !profileId) throw new PortableBackupExportError('account_required');
  if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > MAX_BATCH_SIZE) {
    throw new PortableBackupExportError('invalid_batch_size');
  }
  if (!Number.isSafeInteger(maxDurationMs) || maxDurationMs < 1 ||
      !Number.isSafeInteger(backpressureTimeoutMs) || backpressureTimeoutMs < 1 ||
      !Number.isSafeInteger(maxOutputBytes) || maxOutputBytes < 1 ||
      !Number.isSafeInteger(maxRecords) || maxRecords < 1) {
    throw new PortableBackupExportError('invalid_export_timeout');
  }

  const startedAt = now();
  const state = {
    cancelled: false,
    finished: false,
    startedAt,
    deadline: startedAt + maxDurationMs,
    backpressureTimeoutMs,
    maxOutputBytes,
    maxRecords,
    outputBytes: 0,
    totalRecords: 0,
    now,
  };
  const onClose = () => { if (!state.finished) state.cancelled = true; };
  res.once?.('close', onClose);
  const sectionStats = {};
  try {
    const metadata = await readSnapshotMetadata(client, profileId);
    await writeChunk(res, envelopeLine({
      type: 'header',
      media_type: MEDIA_TYPE,
      format_version: FORMAT_VERSION,
      schema_version: SCHEMA_VERSION,
      backup_id: backupId,
      account_id: metadata.account_id || profileId,
      snapshot_at: new Date(metadata.snapshot_at).toISOString(),
      snapshot_revision: String(metadata.snapshot_revision),
      sections: PORTABLE_SECTIONS.map(({ name }) => name),
      complete: false,
    }), state);

    for (const section of PORTABLE_SECTIONS) {
      const hash = crypto.createHash('sha256');
      let count = 0;
      let bytes = 0;
      let cursor = null;
      let offset = 0;
      for (;;) {
        if (state.cancelled) throw new PortableBackupExportError('export_cancelled');
        if (now() >= state.deadline) throw new PortableBackupExportError('export_timeout');
        const query = setProfileValue(sqlForSection(section, batchSize, cursor, offset), profileId);
        const result = await client.query(query);
        if (!Array.isArray(result.rows)) throw new PortableBackupExportError('section_query_invalid');
        for (const row of result.rows) {
          if (now() >= state.deadline) throw new PortableBackupExportError('export_timeout');
          if (state.totalRecords >= state.maxRecords) throw new PortableBackupExportError('export_limit_exceeded');
          const record = row?.record ?? row;
          if (!record || typeof record !== 'object' || Array.isArray(record)) {
            throw new PortableBackupExportError('section_record_invalid');
          }
          // The footer digest describes the canonical section plaintext the
          // client stages, while the transport line carries the type/section
          // envelope needed to demultiplex one stream.
          const sectionLine = `${canonicalJson(record)}\n`;
          const line = envelopeLine({ type: 'record', section: section.name, record });
          const bytesForLine = Buffer.byteLength(sectionLine);
          hash.update(sectionLine);
          bytes += bytesForLine;
          count += 1;
          state.totalRecords += 1;
          await writeChunk(res, line, state);
          if (section.cursor) {
            const cursorField = section.cursor.slice(section.cursor.lastIndexOf('.') + 1);
            cursor = record?.[cursorField] ?? row?.[cursorField] ?? null;
          }
        }
        if (result.rows.length < batchSize) break;
        if (section.cursor && cursor === null) throw new PortableBackupExportError('section_cursor_missing');
        if (!section.cursor) offset += result.rows.length;
      }
      sectionStats[section.name] = {
        count,
        plaintext_bytes: bytes,
        sha256: hash.digest('hex'),
      };
    }

    const footer = {
      type: 'footer',
      complete: true,
      sections: sectionStats,
      total_records: Object.values(sectionStats).reduce((sum, section) => sum + section.count, 0),
      total_plaintext_bytes: Object.values(sectionStats).reduce((sum, section) => sum + section.plaintext_bytes, 0),
      duration_ms: now() - startedAt,
    };
    await writeChunk(res, envelopeLine(footer), state);
    state.finished = true;
    res.end();
    return { backupId, sections: sectionStats, durationMs: footer.duration_ms };
  } catch (error) {
    state.finished = true;
    if (error instanceof PortableBackupExportError) throw error;
    throw new PortableBackupExportError('export_failed', error);
  } finally {
    res.off?.('close', onClose);
  }
}

function databaseErrorCode(error) {
  if (error instanceof PortableBackupExportError) return error.code;
  if (error?.code === '57014') return 'export_timeout';
  if (error?.code === '42P01') return 'export_schema_unavailable';
  return 'export_failed';
}

module.exports = {
  DEFAULT_BATCH_SIZE,
  DEFAULT_STATEMENT_TIMEOUT_MS,
  DEFAULT_MAX_EXPORT_DURATION_MS,
  DEFAULT_BACKPRESSURE_TIMEOUT_MS,
  DEFAULT_MAX_OUTPUT_BYTES,
  DEFAULT_MAX_RECORDS,
  MAX_BATCH_SIZE,
  PortableBackupExportError,
  databaseErrorCode,
  exportSnapshot,
  sqlForSection,
};
