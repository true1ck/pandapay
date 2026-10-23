require('dotenv').config();

const { Pool } = require('pg');
const { resolveDatabaseTls } = require('./db_tls');
const { safeErrorCode } = require('./safeErrorCode');
const {
  DEFAULT_SMS_LEARNING_WORKER_ROLE,
  startAutonomousWorker,
} = require('./sms_autonomous_worker');

const databaseUrl = process.env.SMS_LEARNING_DATABASE_URL;
if (!databaseUrl) {
  console.error('SMS_LEARNING_DATABASE_URL is required for the SMS learning worker');
  process.exit(1);
}
if (!process.env.SMS_LEARNING_HMAC_KEY || process.env.SMS_LEARNING_HMAC_KEY.length < 32) {
  console.error('SMS_LEARNING_HMAC_KEY must be at least 32 characters');
  process.exit(1);
}

let pool;
try {
  pool = new Pool({
    ...resolveDatabaseTls(databaseUrl, process.env),
    max: 2,
    connectionTimeoutMillis: 5000,
  });
} catch (error) {
  console.error('SMS learning worker database configuration failed', safeErrorCode(error));
  process.exit(1);
}
pool.on('error', error => {
  console.error('SMS learning worker idle database error', safeErrorCode(error));
});

const worker = startAutonomousWorker(pool, {
  runImmediately: true,
  intervalMs: Number(process.env.SMS_AUTONOMOUS_WORKER_INTERVAL_MS) || 300000,
  workerRole: process.env.SMS_LEARNING_WORKER_ROLE || DEFAULT_SMS_LEARNING_WORKER_ROLE,
});

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  worker.stop();
  await pool.end();
  process.exit(0);
}
process.once('SIGTERM', stop);
process.once('SIGINT', stop);
