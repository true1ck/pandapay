'use strict';

const {
  PortableRestoreError,
  cancelRestore,
  commitRestore,
  createRestoreSession,
  previewRestore,
  readRequestBody,
  restoreStatus,
  uploadRestoreSection,
} = require('./restore');

const RESTORE_BASE_PATH = '/portable-backups/restore-sessions';

function errorResponse(res, error) {
  const status = error instanceof PortableRestoreError ? error.status : 503;
  const code = error instanceof PortableRestoreError ? error.code : 'restore_storage_unavailable';
  if (status >= 500) console.error('Portable restore failed', { code });
  return res.status(status).json({ error: code, ...(error?.details ? { details: error.details } : {}) });
}

function bodyObject(body) {
  if (body === undefined || body === null || body === '') return {};
  if (Buffer.isBuffer(body)) {
    try { return JSON.parse(body.toString('utf8')); } catch (_) { throw new PortableRestoreError('invalid_json'); }
  }
  if (typeof body === 'string') {
    try { return JSON.parse(body); } catch (_) { throw new PortableRestoreError('invalid_json'); }
  }
  if (typeof body !== 'object' || Array.isArray(body)) throw new PortableRestoreError('invalid_json');
  return body;
}

function headerValue(req, name) {
  if (typeof req.get === 'function') return req.get(name);
  const headers = req.headers || {};
  return headers[name.toLowerCase()] || headers[name] || null;
}

function registerPortableBackupRestoreRoutes(app, { requireAuth, pool } = {}) {
  if (!app || typeof app.post !== 'function' || typeof app.put !== 'function'
    || typeof app.get !== 'function' || typeof app.delete !== 'function') {
    throw new TypeError('app is required');
  }
  if (typeof requireAuth !== 'function') throw new TypeError('requireAuth is required');
  if (!pool || typeof pool.connect !== 'function') throw new TypeError('pool is required');

  app.post(RESTORE_BASE_PATH, requireAuth, async (req, res) => {
    try {
      const result = await createRestoreSession({ pool, profileId: req.userId, input: bodyObject(req.body) });
      return res.status(result.resumed ? 200 : 201).json(result);
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  app.put(`${RESTORE_BASE_PATH}/:id/sections/:section`, requireAuth, async (req, res) => {
    try {
      const body = await readRequestBody(req);
      const result = await uploadRestoreSection({
        pool,
        profileId: req.userId,
        sessionId: req.params.id,
        sectionName: req.params.section,
        input: body,
      });
      return res.status(result.idempotent ? 200 : 201).json(result);
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  app.get(`${RESTORE_BASE_PATH}/:id/preview`, requireAuth, async (req, res) => {
    try {
      return res.json(await previewRestore({ pool, profileId: req.userId, sessionId: req.params.id }));
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  app.post(`${RESTORE_BASE_PATH}/:id/commit`, requireAuth, async (req, res) => {
    try {
      const body = bodyObject(req.body);
      const previewRevision = headerValue(req, 'if-match')?.replace(/^"|"$/g, '') || body.preview_revision;
      return res.json(await commitRestore({
        pool,
        profileId: req.userId,
        sessionId: req.params.id,
        previewRevision,
      }));
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  app.get(`${RESTORE_BASE_PATH}/:id/status`, requireAuth, async (req, res) => {
    try {
      return res.json(await restoreStatus({ pool, profileId: req.userId, sessionId: req.params.id }));
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  app.delete(`${RESTORE_BASE_PATH}/:id`, requireAuth, async (req, res) => {
    try {
      return res.json(await cancelRestore({ pool, profileId: req.userId, sessionId: req.params.id }));
    } catch (error) {
      return errorResponse(res, error);
    }
  });

  return app;
}

module.exports = { RESTORE_BASE_PATH, errorResponse, registerPortableBackupRestoreRoutes };
