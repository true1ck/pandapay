'use strict';

// GET /sms/v2/sync?cursor=<opaque> (WP-08).
//
// Returns the profile's instruments, events and ledger entries changed since
// the cursor (at most 1,000 rows per entity), plus AI results, correction
// status and the latest bundle version from the hook object.
//
// The sync response schema is frozen and has no `hasMore` field, so paging is
// signalled by the response header `X-Sms-Sync-Has-More: 1|0`. A client can
// equally keep calling while any entity list has exactly 1,000 rows.
//
// Hook return shape: an array, or {items, cursor}. A string `cursor` is stored
// in the sync cursor and passed back to the hook on the next call.

const storage = require('./storage');
const { safeErrorCode } = require('../safeErrorCode');

const denied = (v) => v === false || (v && typeof v === 'object' && v.ok === false);

function hookItems(out) {
  if (Array.isArray(out)) return { items: out, cursor: null };
  if (out && Array.isArray(out.items)) return { items: out.items, cursor: typeof out.cursor === 'string' ? out.cursor : null };
  return { items: [], cursor: null };
}

function createSyncHandler({ withUserClient, hooks }) {
  return async function syncHandler(req, res) {
    try {
      if (denied(await hooks.security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
      if (denied(await hooks.security.checkRate(req, 'sync', 1))) return res.status(429).json({ error: 'rate_limited' });
    } catch (err) {
      console.error('sms_v2 sync security hook failed', safeErrorCode(err));
      return res.status(503).json({ error: 'security_unavailable' });
    }
    const raw = req.query.cursor;
    const cursor = storage.decodeCursor(Array.isArray(raw) ? raw[0] : raw);
    if (!cursor) return res.status(400).json({ error: 'cursor_invalid' });
    try {
      const ai = hookItems(await hooks.aiResultsSince(req.userId, cursor.a || null));
      const corrections = hookItems(await hooks.correctionStatusSince(req.userId, cursor.c || null));
      const latestBundleVersion = Number(await hooks.latestBundleVersion(req.userId)) || 0;
      const changes = await withUserClient(req.userId, (client) => storage.readChanges(client, req.userId, cursor, {
        a: ai.cursor || cursor.a || null, c: corrections.cursor || cursor.c || null,
      }));
      res.set('X-Sms-Sync-Has-More', changes.hasMore ? '1' : '0');
      return res.status(200).json({
        cursor: changes.cursor,
        instruments: changes.instruments,
        events: changes.events,
        ledger: changes.ledger,
        facts: changes.facts,
        updatedAt: changes.updatedAt,
        aiResults: ai.items,
        corrections: corrections.items,
        latestBundleVersion,
      });
    } catch (err) {
      console.error('sms_v2 sync failed', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function registerSyncRoute(app, { requireSmsV2, requireMember, withUserClient, hooks }) {
  app.get('/sms/v2/sync', requireSmsV2, requireMember, createSyncHandler({ withUserClient, hooks }));
}

module.exports = { registerSyncRoute, createSyncHandler };
