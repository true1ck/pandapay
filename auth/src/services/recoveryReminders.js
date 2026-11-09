'use strict';

// One reminder email, seven days after sign-up, to people who still have no
// recovery email. (The earlier reminders, at 1 hour, 1 day and 3 days, are local
// notifications on the phone; they need no server.) It runs on a timer inside the
// auth service, only when RECOVERY_REMINDER_EMAILS_ENABLED=true, a small batch at a
// time, so switching it on never floods the mail provider.

const REMINDER_LOCK = [1346458690, 17]; // fixed application namespace, never user input
const DEFAULT_BATCH = 25;
const DEFAULT_AFTER_DAYS = 7;

const REMINDER = Object.freeze({
  subject: 'Add a recovery email to PandaPay',
  text: 'You signed up for PandaPay a week ago and have not added a recovery email yet.\n\n' +
    'If you ever lose access to your sign-in email, a recovery email is how you get back into your ' +
    'account. It takes a minute: open PandaPay, go to Settings, then Recovery email.\n\n' +
    'You will get this reminder only once.',
});

/**
 * Claims up to `batch` accounts that are due and emails each one. An account is
 * claimed (marked) before its email is sent, so two instances can never send twice;
 * a failed send is not retried, so one bad address can never block the queue.
 */
async function sendDueReminderEmails({ pool, sendNotice, batch = DEFAULT_BATCH, afterDays = DEFAULT_AFTER_DAYS }) {
  if (!Number.isInteger(batch) || batch < 1 || batch > 200) throw new TypeError('batch must be 1 to 200');
  if (!Number.isInteger(afterDays) || afterDays < 1 || afterDays > 365) throw new TypeError('afterDays must be 1 to 365');
  const client = await pool.connect();
  let claimed;
  let began = false;
  let releaseError;
  try {
    await client.query('BEGIN');
    began = true;
    const locked = await client.query('SELECT pg_try_advisory_xact_lock($1, $2) AS locked', REMINDER_LOCK);
    if (locked.rows[0]?.locked !== true) {
      await client.query('ROLLBACK');
      began = false;
      return { claimed: 0, sent: 0, failed: 0, skipped: 'another_instance_running' };
    }
    const result = await client.query(
      `UPDATE users SET recovery_reminder_email_sent_at = NOW()
        WHERE id IN (
          SELECT id FROM users
           WHERE deleted = FALSE AND is_active = TRUE AND is_email_verified = TRUE
             AND email IS NOT NULL AND recovery_email IS NULL
             AND recovery_reminder_email_sent_at IS NULL
             AND created_at <= NOW() - ($2::integer * INTERVAL '1 day')
           ORDER BY created_at
           LIMIT $1
           FOR UPDATE SKIP LOCKED)
        RETURNING id, email`,
      [batch, afterDays],
    );
    claimed = result.rows;
    await client.query('COMMIT');
    began = false;
  } catch (error) {
    if (began) {
      try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
    }
    throw error;
  } finally {
    client.release(releaseError);
  }

  let sent = 0;
  let failed = 0;
  for (const row of claimed) {
    try {
      const result = await sendNotice({ to: row.email, subject: REMINDER.subject, text: REMINDER.text });
      if (result?.success) sent++; else failed++;
    } catch (_) {
      failed++;
    }
  }
  return { claimed: claimed.length, sent, failed };
}

/** Runs the reminder job on a timer that never keeps the process alive. */
function startRecoveryReminderJob({ getPool, sendNotice, intervalMs = 15 * 60 * 1000, logger = console, setIntervalFn = setInterval }) {
  let running = false;
  const timer = setIntervalFn(async () => {
    if (running) return;
    running = true;
    try {
      const outcome = await sendDueReminderEmails({ pool: await getPool(), sendNotice });
      if (outcome.claimed > 0) logger.info(`Recovery reminder emails: ${outcome.sent} sent, ${outcome.failed} failed`);
    } catch (error) {
      logger.error('Recovery reminder job failed', error?.code || error?.name || 'error');
    } finally {
      running = false;
    }
  }, intervalMs);
  if (typeof timer?.unref === 'function') timer.unref();
  return () => clearInterval(timer);
}

module.exports = { sendDueReminderEmails, startRecoveryReminderJob, REMINDER };
