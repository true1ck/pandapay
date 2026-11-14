'use strict';
// WP-S7: GET /user-state, PUT|DELETE /user-state/:kind/:key.
// Per-person local state (bill-card assignments, bank balances, subscription
// overrides) synced between phones. Last writer wins per (kind,key) by the
// phone's edit clock. `bank_balance` is stored ONLY as AES-256-GCM ciphertext
// (payload_enc); payloads are never logged.
const crypto = require('node:crypto');
const { safeErrorCode } = require('./safeErrorCode');
const { isUuid, respondDbError, parseClientClock } = require('./http_db_errors');

const KINDS = Object.freeze(['bill_card_assignment', 'bank_balance', 'subscription_override']);
const ENCRYPTED_KINDS = new Set(['bank_balance']);
const MAX_PAYLOAD_BYTES = 4096;
const PAGE = 500;
const COLS = 'kind, state_key, payload, payload_enc, client_edited_at, deleted, updated_at, server_seq';

// --- encryption: same AES-256-GCM envelope and key ring as stored IMAP passwords
// (imap_credentials.js: IMAP_ENCRYPTION_KEY[_ID] / _PREVIOUS_KEYS), with its own
// AAD label. Stored text: v1:<keyId>:<base64(nonce12 || tag16 || ciphertext)>.
const aad = (profileId, kind, key, keyId) =>
  Buffer.from(JSON.stringify(['pandapay-user-state-v1', profileId, kind, key, keyId]));

function seal(ring, profileId, kind, key, obj) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', ring.current.bytes, nonce);
  cipher.setAAD(aad(profileId, kind, key, ring.current.id));
  const body = Buffer.concat([cipher.update(JSON.stringify(obj), 'utf8'), cipher.final()]);
  return `v1:${ring.current.id}:${Buffer.concat([nonce, cipher.getAuthTag(), body]).toString('base64')}`;
}

/** Plain object, or null when unreadable (unknown key id, wrong row, tampering, no ring). */
function open(ring, profileId, kind, key, text) {
  try {
    const [v, keyId, b64] = String(text).split(':');
    const bytes = ring?.byId.get(keyId);
    const data = Buffer.from(b64 || '', 'base64');
    if (v !== 'v1' || !bytes || data.length < 29) return null;
    const d = crypto.createDecipheriv('aes-256-gcm', bytes, data.subarray(0, 12));
    d.setAAD(aad(profileId, kind, key, keyId));
    d.setAuthTag(data.subarray(12, 28));
    return JSON.parse(Buffer.concat([d.update(data.subarray(28)), d.final()]).toString('utf8'));
  } catch (_) { return null; }
}

// --- validation
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const optType = (v, t) => v === undefined || v === null || typeof v === t;
const optNum = (v) => v === undefined || v === null || (typeof v === 'number' && Number.isFinite(v));

function shapeOk(kind, p) {
  if (kind === 'bank_balance') {
    const label = p.accountLabel ?? p.label;
    return typeof p.amount === 'number' && Number.isFinite(p.amount)
      && typeof label === 'string' && label.length > 0;
  }
  if (kind === 'bill_card_assignment') return isUuid(p.userCardId) && typeof p.billKey === 'string' && p.billKey.length > 0;
  return optType(p.hidden, 'boolean') && optType(p.manual, 'boolean') && optType(p.displayName, 'string')
    && optNum(p.amountInr) && optNum(p.cadenceDays) && optType(p.nextExpectedOn, 'string')
    && optType(p.autopayStatus, 'string');
}

function parseTarget(req, res) {
  const { kind, key } = req.params;
  if (!KINDS.includes(kind)) { res.status(400).json({ error: 'invalid_kind' }); return null; }
  if (typeof key !== 'string' || key.length < 1 || key.length > 200) { res.status(400).json({ error: 'invalid_key' }); return null; }
  return { kind, key };
}

function createUserLocalStateHandlers({ withUserClient, keyring = null }) {
  const toItem = (userId, r) => {
    let payload = r.payload ?? null;
    let undecryptable;
    if (!r.deleted && r.payload_enc) {
      payload = open(keyring, userId, r.kind, r.state_key, r.payload_enc);
      if (payload === null) undecryptable = true;
    }
    const item = {
      kind: r.kind, key: r.state_key, payload, deleted: r.deleted,
      clientEditedAt: new Date(r.client_edited_at).toISOString(),
      updatedAt: new Date(r.updated_at).toISOString(),
    };
    if (undecryptable) item.undecryptable = true;
    return item;
  };

  async function write(req, res, t, { deleted, payload, clock }) {
    let enc = null;
    let plain = null;
    if (!deleted) {
      if (ENCRYPTED_KINDS.has(t.kind)) {
        if (!keyring) return res.status(503).json({ error: 'encryption_unavailable' });
        enc = seal(keyring, req.userId, t.kind, t.key, payload);
      } else {
        plain = JSON.stringify(payload);
      }
    }
    try {
      const out = await withUserClient(req.userId, async (client) => {
        const w = await client.query(
          `INSERT INTO user_local_state (profile_id, kind, state_key, payload, payload_enc, client_edited_at, deleted)
           VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7)
           ON CONFLICT (profile_id, kind, state_key) DO UPDATE
             SET payload = EXCLUDED.payload, payload_enc = EXCLUDED.payload_enc,
                 client_edited_at = EXCLUDED.client_edited_at, deleted = EXCLUDED.deleted,
                 updated_at = now(), server_seq = nextval('user_local_state_seq')
             WHERE user_local_state.client_edited_at <= EXCLUDED.client_edited_at
           RETURNING ${COLS}`,
          [req.userId, t.kind, t.key, plain, enc, clock, deleted]);
        if (w.rows.length) return { row: w.rows[0], superseded: false };
        const s = await client.query(
          `SELECT ${COLS} FROM user_local_state WHERE profile_id = $1 AND kind = $2 AND state_key = $3`,
          [req.userId, t.kind, t.key]);
        return { row: s.rows[0], superseded: true };
      });
      const item = toItem(req.userId, out.row);
      return res.status(200).json(out.superseded ? { superseded: true, item } : { item });
    } catch (err) {
      if (respondDbError(res, err)) return undefined;
      console.error('user-state write error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  }

  const put = async (req, res) => {
    const t = parseTarget(req, res); if (!t) return undefined;
    const body = req.body;
    if (!isObj(body)) return res.status(422).json({ error: 'invalid_body' });
    const clock = parseClientClock(body.clientEditedAt);
    if (!clock.ok || clock.value === null) return res.status(400).json({ error: 'invalid_client_edited_at' });
    if (body.deleted !== undefined && typeof body.deleted !== 'boolean') return res.status(422).json({ error: 'invalid_body' });
    if (body.deleted === true) return write(req, res, t, { deleted: true, payload: null, clock: clock.value });
    if (!isObj(body.payload)) return res.status(422).json({ error: 'invalid_payload' });
    if (Buffer.byteLength(JSON.stringify(body.payload), 'utf8') > MAX_PAYLOAD_BYTES) {
      return res.status(422).json({ error: 'payload_too_large' });
    }
    if (!shapeOk(t.kind, body.payload)) return res.status(422).json({ error: 'invalid_payload' });
    return write(req, res, t, { deleted: false, payload: body.payload, clock: clock.value });
  };

  const del = async (req, res) => {
    const t = parseTarget(req, res); if (!t) return undefined;
    const clock = parseClientClock(req.get('X-Client-Edited-At'));
    if (!clock.ok) return res.status(400).json({ error: 'invalid_client_edited_at' });
    return write(req, res, t, { deleted: true, payload: null, clock: clock.value ?? new Date().toISOString() });
  };

  const list = async (req, res) => {
    const { since, kind } = req.query;
    if (kind !== undefined && !KINDS.includes(kind)) return res.status(400).json({ error: 'invalid_kind' });
    const params = [req.userId];
    let where = 'profile_id = $1';
    if (kind !== undefined) { params.push(kind); where += ` AND kind = $${params.length}`; }
    if (since !== undefined && since !== '') {
      if (/^\d{1,18}$/.test(since)) { params.push(since); where += ` AND server_seq > $${params.length}::bigint`; }
      else if (/^\d{4}-\d{2}-\d{2}T/.test(since) && !Number.isNaN(Date.parse(since))) {
        params.push(new Date(since).toISOString()); where += ` AND updated_at > $${params.length}::timestamptz`;
      } else return res.status(400).json({ error: 'invalid_since' });
    }
    try {
      const rows = (await withUserClient(req.userId, (client) => client.query(
        `SELECT ${COLS} FROM user_local_state WHERE ${where} ORDER BY server_seq LIMIT ${PAGE + 1}`, params))).rows;
      const hasMore = rows.length > PAGE;
      const page = hasMore ? rows.slice(0, PAGE) : rows;
      const cursor = page.length ? String(page[page.length - 1].server_seq) : (since || '0');
      return res.json({ items: page.map((r) => toItem(req.userId, r)), cursor, hasMore });
    } catch (err) {
      if (respondDbError(res, err)) return undefined;
      console.error('user-state list error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };

  return { put, del, list };
}

function registerUserLocalStateRoutes(app, { requireAuth, withUserClient, keyring }) {
  const h = createUserLocalStateHandlers({ withUserClient, keyring });
  app.get('/user-state', requireAuth, h.list);
  app.put('/user-state/:kind/:key', requireAuth, h.put);
  app.delete('/user-state/:kind/:key', requireAuth, h.del);
}

module.exports = { createUserLocalStateHandlers, registerUserLocalStateRoutes, KINDS };
