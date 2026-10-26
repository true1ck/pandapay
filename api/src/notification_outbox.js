'use strict';

// Called by the inbox writer before its surrounding user transaction commits.
// The outbox stores the inbox row identity. The database captures a bounded,
// immutable content revision only when this is called inside the user write.
async function enqueueNotification(client, notificationId) {
  if (!client || typeof client.query !== 'function') throw new TypeError('client.query is required');
  if (!notificationId) throw new TypeError('notificationId is required');
  const result = await client.query('SELECT notification_delivery.enqueue($1::uuid) AS enqueued', [notificationId]);
  return result.rows[0]?.enqueued === true;
}

module.exports = { enqueueNotification };
