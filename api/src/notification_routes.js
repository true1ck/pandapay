'use strict';
const { safeErrorCode } = require('./safeErrorCode');
const { enqueueNotification } = require('./notification_outbox');

function createNotificationPostHandler({ withUserClient, notificationService, outboxEnabled = false,
  enqueue = enqueueNotification, logger = console } = {}) {
  if (typeof withUserClient !== 'function' || typeof notificationService?.isConfigured !== 'function'
      || typeof notificationService?.send !== 'function' || typeof enqueue !== 'function'
      || typeof outboxEnabled !== 'boolean') throw new TypeError('notification handler dependencies required');
  return async (req, res) => {
  const { category, severity, title, body, deepLink, dedupeKey, sendRemote = false } = req.body || {};
  if (!category || !title) {
    return res.status(400).json({ error: 'category and title are required' });
  }
  if (typeof sendRemote !== 'boolean') {
    return res.status(400).json({ error: 'sendRemote must be boolean' });
  }
  if (outboxEnabled && sendRemote && (typeof category !== 'string' || Buffer.byteLength(category) > 64
      || typeof title !== 'string' || Buffer.byteLength(title) > 512
      || (body != null && (typeof body !== 'string' || Buffer.byteLength(body) > 4096))
      || (deepLink != null && (typeof deepLink !== 'string' || Buffer.byteLength(deepLink) > 1024)))) {
    return res.status(400).json({ error: 'invalid_notification_payload' });
  }
  // 'streak' and 'card_added' have no preference column — they're in-app
  // consequences of the user's own action, not push-style interruptions.
  const PREFERENCE_COLUMN = {
    location: 'category_location',
    caps: 'category_caps',
    milestones: 'category_milestones',
    fee_waivers: 'category_fee_waivers',
    bills: 'category_bills',
    expiry: 'category_expiry',
    monthly_report: 'category_monthly_report',
    needs_review: 'category_needs_review',
    transactions: 'category_transactions',
    // Two categories, not one: "over budget" is a post-mortem and
    // "running ahead of pace" is still actionable, so someone who wants
    // the early warning shouldn't be forced to take the late one too.
    budget_warning: 'category_budget_warning',
    budget_exceeded: 'category_budget_exceeded',
  };
  try {
    const inserted = await withUserClient(req.userId, async (client) => {
      const column = Object.hasOwn(PREFERENCE_COLUMN, category) ? PREFERENCE_COLUMN[category] : null;
      if (column) {
        const pref = await client.query(
          `SELECT ${column} AS enabled FROM notification_preferences WHERE profile_id = $1`,
          [req.userId]
        );
        // No preferences row yet means the user has never opted out of
        // anything; 0019's own column defaults are the intent, so deliver.
        if (pref.rowCount > 0 && pref.rows[0].enabled === false) return null;
      }
      const result = await client.query(
        `INSERT INTO notifications (profile_id, category, severity, title, body, deep_link, dedupe_key)
         VALUES ($1, $2, COALESCE($3, 'info'), $4, $5, $6, $7)
         ON CONFLICT (profile_id, dedupe_key) WHERE dedupe_key IS NOT NULL
         DO UPDATE SET title = EXCLUDED.title,
                       body = EXCLUDED.body,
                       severity = EXCLUDED.severity,
                       deep_link = EXCLUDED.deep_link,
                       created_at = now(),
                       read_at = NULL
         RETURNING *`,
        [req.userId, category, severity, title, body || null, deepLink || null, dedupeKey || null]
      );
      if (outboxEnabled && sendRemote) await enqueue(client, result.rows[0].id);
      return result.rows[0];
    });
    // 204 (not an error) when the user has that category muted — the caller
    // asked for a delivery and got a definitive "not delivered, by choice".
    if (!inserted) return res.status(204).end();

    // The enabled outbox committed atomically with the inbox. During the
    // disabled compatibility path, remote delivery remains best effort.
    if (sendRemote && !outboxEnabled && notificationService.isConfigured()) {
      notificationService
        .send({
          subscriberId: req.userId,
          title: inserted.title,
          body: inserted.body,
          category: inserted.category,
          severity: inserted.severity,
          deepLink: inserted.deep_link,
          dedupeKey: inserted.dedupe_key,
        })
        .catch((err) => logger.error('remote notification delivery failed', safeErrorCode(err)));
    }
    res.status(201).json({ notification: inserted });
  } catch (err) {
    logger.error('POST /notifications error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
  };
}
module.exports = { createNotificationPostHandler };
