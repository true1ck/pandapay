'use strict';

// Schedule for the SMS v2 rule job when it runs as a long-lived service
// (`rule_jobs_main.js --loop`) on the private admin host. Served rule sets expire
// 7 days after signing (BUNDLE_TTL_MS), so this loop is what keeps them fresh.

const HOUR_MS = 3_600_000;

// Milliseconds from `now` until the next minute `minute` of an hour (UTC).
function nextRunDelayMs(now, minute = 7) {
  const next = new Date(now.getTime());
  next.setUTCMinutes(minute, 0, 0);
  if (next.getTime() <= now.getTime()) next.setTime(next.getTime() + HOUR_MS);
  return next.getTime() - now.getTime();
}

const count = (value) => (Array.isArray(value) ? value.length : undefined);

// Runs once at start-up, then at minute 7 of every hour. A failed run is logged
// and retried at the next slot; it never ends the loop.
async function runRuleJobsLoop({ runOnce, now = () => new Date(), sleep, log, stopped }) {
  while (!stopped()) {
    try {
      const result = await runOnce();
      // Metadata only: never log bundle bodies, rules or keys.
      log({ event: 'sms_v2_rule_jobs', status: 'ok', refreshed: count(result?.refreshed), paused: count(result?.paused) });
    } catch (error) {
      log({ event: 'sms_v2_rule_jobs', status: 'failed', code: error?.code || error?.name || 'Error' });
    }
    if (stopped()) break;
    await sleep(nextRunDelayMs(now()));
  }
}

module.exports = { nextRunDelayMs, runRuleJobsLoop };
