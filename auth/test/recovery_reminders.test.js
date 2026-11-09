const test = require('node:test');
const assert = require('node:assert/strict');
const { sendDueReminderEmails, startRecoveryReminderJob, REMINDER } = require('../src/services/recoveryReminders');

function fakePool({ rows = [], locked = true } = {}) {
  const log = { statements: [], released: 0, args: null };
  const client = {
    async query(sql, args) {
      log.statements.push(sql.replace(/\s+/g, ' ').trim().slice(0, 40));
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ locked }] };
      if (sql.includes('UPDATE users SET recovery_reminder_email_sent_at')) { log.args = args; return { rows }; }
      return { rows: [] };
    },
    release() { log.released++; },
  };
  return { pool: { async connect() { return client; } }, log };
}

test('due accounts are claimed in a batch, then emailed the one reminder with no link or code', async () => {
  const { pool, log } = fakePool({ rows: [{ id: 'a', email: 'a@x.test' }, { id: 'b', email: 'b@x.test' }] });
  const sent = [];
  const out = await sendDueReminderEmails({ pool, sendNotice: async n => { sent.push(n); return { success: true }; } });
  assert.deepEqual(out, { claimed: 2, sent: 2, failed: 0 });
  assert.deepEqual(log.args, [25, 7]);
  assert.deepEqual(sent.map(n => n.to), ['a@x.test', 'b@x.test']);
  assert.equal(sent[0].subject, REMINDER.subject);
  assert.doesNotMatch(sent[0].text, /https?:|\d{6}/);
  assert.match(sent[0].text, /only once/);
  assert.equal(log.released, 1);
});

test('a failed or throwing send is counted, never retried, and never stops the rest', async () => {
  const { pool } = fakePool({ rows: [{ id: 'a', email: 'a@x.test' }, { id: 'b', email: 'b@x.test' }, { id: 'c', email: 'c@x.test' }] });
  let n = 0;
  const out = await sendDueReminderEmails({ pool, sendNotice: async () => { n++; if (n === 1) throw new Error('smtp'); if (n === 2) return { success: false }; return { success: true }; } });
  assert.deepEqual(out, { claimed: 3, sent: 1, failed: 2 });
});

test('another instance holding the lock means nothing is claimed or sent', async () => {
  const { pool } = fakePool({ locked: false, rows: [{ id: 'a', email: 'a@x.test' }] });
  let sends = 0;
  const out = await sendDueReminderEmails({ pool, sendNotice: async () => { sends++; return { success: true }; } });
  assert.deepEqual(out, { claimed: 0, sent: 0, failed: 0, skipped: 'another_instance_running' });
  assert.equal(sends, 0);
});

test('the batch size and the wait are bounded', async () => {
  const { pool } = fakePool();
  await assert.rejects(sendDueReminderEmails({ pool, sendNotice() {}, batch: 0 }), /batch/);
  await assert.rejects(sendDueReminderEmails({ pool, sendNotice() {}, batch: 500 }), /batch/);
  await assert.rejects(sendDueReminderEmails({ pool, sendNotice() {}, afterDays: 0 }), /afterDays/);
  await assert.rejects(sendDueReminderEmails({ pool, sendNotice() {}, batch: 1.5 }), /batch/);
});

test('the timer job never overlaps itself, never keeps the process alive and can be stopped', async () => {
  let tick; let unrefd = false; let cleared = false; let sends = 0;
  const { pool } = fakePool({ rows: [{ id: 'a', email: 'a@x.test' }] });
  const stop = startRecoveryReminderJob({
    getPool: async () => pool, intervalMs: 1000, logger: { info() {}, error() {} },
    sendNotice: async () => { sends++; await new Promise(r => setTimeout(r, 20)); return { success: true }; },
    setIntervalFn: fn => { tick = fn; return { unref() { unrefd = true; } }; },
  });
  const first = tick(); const second = tick();
  await Promise.all([first, second]);
  assert.equal(sends, 1, 'a tick that fires while one is running is skipped');
  assert.equal(unrefd, true);
  const realClear = global.clearInterval; global.clearInterval = () => { cleared = true; };
  try { stop(); } finally { global.clearInterval = realClear; }
  assert.equal(cleared, true);
});
