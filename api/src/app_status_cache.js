'use strict';

/**
 * Reader for the single-row app_status table behind GET /app-status.
 *
 * Every phone asks for it at launch and the reachability checks used to ask once a minute, each time through the
 * admission line and a database connection. The row changes a few times a year, so one read serves everyone for
 * `ttlMs`; concurrent callers share one read; if the database fails the last good value is served for up to
 * `staleMs` (a maintenance flag raised before the failure stays visible). With nothing to serve, the error is thrown
 * and the route answers as it always did. A missing row is cached as null (the route fails open).
 */
function createAppStatusReader({ readRow, ttlMs = 30000, staleMs = 600000, now = Date.now } = {}) {
  let value; let at = null; let inFlight = null;
  return async function readAppStatus() {
    if (at !== null && now() - at < ttlMs) return value;
    if (inFlight) return inFlight;
    inFlight = (async () => {
      try {
        const row = await readRow();
        value = row ?? null;
        at = now();
        return value;
      } catch (err) {
        if (at !== null && now() - at < staleMs) return value;
        throw err;
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  };
}

module.exports = { createAppStatusReader };
