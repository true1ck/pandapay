require('dotenv').config();

const { Pool } = require('pg');
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

const pool = new Pool({
  connectionString: databaseUrl,
  ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  max: 2,
  connectionTimeoutMillis: 5000,
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
