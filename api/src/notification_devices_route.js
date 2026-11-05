'use strict';
const { safeErrorCode } = require('./safeErrorCode');

/**
 * DELETE /notification-devices removes this phone's FCM token from the
 * caller's own notification subscriber. The subscriber is always req.userId;
 * the body only names the token to drop, so one account cannot unregister
 * another account's phone.
 */
function registerNotificationDeviceRoutes(app, { requireAuth, notificationService, logger = console }) {
  app.delete('/notification-devices', requireAuth, async (req, res) => {
    const { token } = req.body || {};
    if (typeof token !== 'string' || token.trim().length < 10 || token.length > 4096) {
      return res.status(400).json({ error: 'A valid FCM token is required' });
    }
    try {
      await notificationService.unregisterDevice({ subscriberId: req.userId, token: token.trim() });
      return res.status(204).end();
    } catch (err) {
      logger.error('DELETE /notification-devices error', safeErrorCode(err));
      return res.status(502).json({ error: 'notification_provider_unavailable' });
    }
  });
}

module.exports = { registerNotificationDeviceRoutes };
