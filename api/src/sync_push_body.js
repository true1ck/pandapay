'use strict';

const express = require('express');

// /sync/push accepts up to 200 changes and a user_commitments document can be
// 16 KiB, so a legitimate batch can exceed the global 100 KiB JSON limit
// (request_limits.js). 1 MiB comfortably fits 200 changes at that size while
// staying a small, explicit bound; the 200-change count limit in
// sync_request_validation.js still applies.
const SYNC_PUSH_BODY_LIMIT_BYTES = 1024 * 1024;
const parseSyncPushJson = express.json({ limit: SYNC_PUSH_BODY_LIMIT_BYTES, strict: true });

/**
 * Mounted on /sync/push BEFORE the global JSON parser: a body that has been
 * parsed here is skipped by the global one. Only requests that already carry
 * a validly signed access token get the larger limit, so unauthenticated
 * traffic is still capped at the global 100 KiB (requireAuth then answers
 * 401). Errors flow to jsonBodyErrorHandler like any other body error.
 */
function syncPushBodyParser(req, res, next) {
  if (req.method !== 'POST' || !req.userId) return next();
  return parseSyncPushJson(req, res, next);
}

module.exports = { SYNC_PUSH_BODY_LIMIT_BYTES, syncPushBodyParser };
