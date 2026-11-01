const crypto = require('node:crypto');

const DEFAULT_PAGE_SIZE = 200;
const MAX_PAGE_SIZE = 500;
const CURSOR_VERSION = 1;

function normalizePageRequest(query, { secret, scope }) {
  const pageSizeRaw = query?.pageSize;
  const cursorRaw = query?.cursor;
  const paged = pageSizeRaw != null || cursorRaw != null;
  if (!paged) return { paged: false, pageSize: null, cursor: null };
  if (typeof secret !== 'string' || secret.length === 0) {
    throw new Error('transaction paging secret is not configured');
  }
  if (typeof scope !== 'string' || scope.length === 0) {
    throw new Error('transaction paging scope is required');
  }
  let pageSize = DEFAULT_PAGE_SIZE;
  if (pageSizeRaw != null) {
    if (Array.isArray(pageSizeRaw) || !/^\d+$/.test(String(pageSizeRaw))) {
      return { error: 'invalid_page_size' };
    }
    pageSize = Number(pageSizeRaw);
    if (!Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
      return { error: 'invalid_page_size' };
    }
  }
  let cursor = null;
  if (cursorRaw != null) {
    if (Array.isArray(cursorRaw) || typeof cursorRaw !== 'string' || cursorRaw.length > 2048) {
      return { error: 'invalid_cursor' };
    }
    cursor = decodeCursor(cursorRaw, { secret, scope });
    if (cursor == null) return { error: 'invalid_cursor' };
  }
  return { paged: true, pageSize, cursor };
}

function encodeCursor({ occurredAt, id }, { secret, scope }) {
  if (typeof secret !== 'string' || !secret || typeof scope !== 'string' || !scope) {
    throw new Error('transaction paging cursor requires secret and scope');
  }
  const timestamp = new Date(occurredAt);
  if (Number.isNaN(timestamp.getTime()) || !isUuid(id)) {
    throw new Error('transaction paging cursor values are invalid');
  }
  const payload = Buffer.from(JSON.stringify({
    v: CURSOR_VERSION,
    scope,
    occurredAt: timestamp.toISOString(),
    id: String(id).toLowerCase(),
  })).toString('base64url');
  return `${payload}.${sign(payload, secret)}`;
}

function decodeCursor(value, { secret, scope }) {
  try {
    const [payload, supplied] = String(value).split('.');
    if (!payload || !supplied || supplied.length > 128) return null;
    const expected = sign(payload, secret);
    const left = Buffer.from(supplied);
    const right = Buffer.from(expected);
    if (left.length !== right.length || !crypto.timingSafeEqual(left, right)) return null;
    const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (decoded?.v !== CURSOR_VERSION || decoded.scope !== scope || !isUuid(decoded.id)) return null;
    const timestamp = new Date(decoded.occurredAt);
    if (Number.isNaN(timestamp.getTime())) return null;
    return { occurredAt: timestamp.toISOString(), id: String(decoded.id).toLowerCase() };
  } catch (_) {
    return null;
  }
}

function cursorPredicate(cursor, parameterStart) {
  if (!cursor) return { sql: '', params: [] };
  const occurredAtParam = parameterStart;
  const idParam = parameterStart + 1;
  return {
    sql: `(t.occurred_at, t.id) < ($${occurredAtParam}::timestamptz, $${idParam}::uuid)`,
    params: [cursor.occurredAt, cursor.id],
  };
}

function pageInfo(rows, pageSize, { secret, scope }) {
  const hasMore = rows.length > pageSize;
  const visible = hasMore ? rows.slice(0, pageSize) : rows;
  const last = visible[visible.length - 1];
  return {
    rows: visible,
    pageInfo: {
      hasMore,
      nextCursor: hasMore && last
        ? encodeCursor({ occurredAt: last.occurred_at, id: last.id }, { secret, scope })
        : null,
    },
  };
}

function sign(payload, secret) {
  return crypto.createHmac('sha256', secret).update(payload).digest('base64url');
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ''));
}

module.exports = {
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
  cursorPredicate,
  decodeCursor,
  encodeCursor,
  normalizePageRequest,
  pageInfo,
};
