'use strict';
const { safeErrorCode } = require('./safeErrorCode');

function createReadinessHandler({ checkDependencies, isDraining = () => false, logger = console }) {
  if (typeof checkDependencies !== 'function' || typeof isDraining !== 'function') throw new TypeError('Readiness callbacks required');
  return async (_req, res) => {
    res.set?.('Cache-Control', 'no-store');
    const draining = () => res.status(503).json({ ok: false, database: 'draining' });
    if (isDraining()) return draining();
    try {
      await checkDependencies();
      if (isDraining()) return draining();
      return res.json({ ok: true, database: 'ready' });
    } catch (error) {
      logger.error('GET /ready error', safeErrorCode(error));
      return res.status(503).json({ ok: false, database: 'unavailable' });
    }
  };
}
module.exports = { createReadinessHandler };
