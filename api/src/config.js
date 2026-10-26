/**
 * Central, fail-fast config — api/'s side of the pattern auth/src/config.js
 * already uses. Before this, every secret was read inline with
 * `process.env.X` at whatever point in index.js happened to need it: a typo
 * or missing var in `INBOUND_EMAIL_WEBHOOK_SECRET` surfaced as a confusing
 * 401/500 on the first webhook call in production, not as a startup failure.
 *
 * Deliberately NOT AWS SSM (that's auth/'s pattern, built for AWS — this
 * service's actual deploy target is a generic Docker-capable VM, Oracle
 * Cloud specifically, see deploy/DEPLOY.md). This module only centralizes
 * and validates process.env; it stays agnostic to *how* those env vars get
 * populated — .env locally, docker-compose.prod.yml's `environment:` block,
 * or a real secrets store fronting the container later.
 */

const path = require('path');
require('dotenv').config();
if (!process.env.JWT_ACCESS_SECRET && !process.env.DATABASE_URL) {
  require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });
}

const isProduction = process.env.NODE_ENV === 'production';
const securityFeatures = require('./security_feature_config').readSecurityFeatureConfig();

// DATABASE_URL and JWT_ACCESS_SECRET are required everywhere — api/ cannot
// do anything useful without a database or without being able to verify
// auth/'s tokens (api/src/auth.js already throws on the latter today; this
// just makes it one consistent check instead of two).
const REQUIRED_ENV = ['JWT_ACCESS_SECRET'];

// The webhook/encryption secrets are allowed to be unset in dev — several
// routes have an explicit, intentional fallback for that (imap_test.js's
// format-only check when IMAP_ENCRYPTION_KEY is absent, for example) — but
// an unset webhook secret in production means the webhook route effectively
// has no auth, and an unset encryption key means IMAP passwords never get
// tested for real. Both are silent-until-someone-hits-the-endpoint failures
// without this check.
if (isProduction) {
  REQUIRED_ENV.push(
    'INBOUND_EMAIL_WEBHOOK_SECRET',
    'PARTNER_WEBHOOK_SECRET',
    'IMAP_ENCRYPTION_KEY',
    'AUTH_INTERNAL_BASE_URL',
    'AUTH_INTERNAL_SERVICE_SECRET',
    'REFERRAL_IDENTITY_HMAC_KEY',
    'REFERRAL_PREVIEW_SECRET',
    'ENGAGEMENT_RECEIPT_SECRET',
    'REWARD_WORKER_INTERNAL_SECRET'
  );
}

const missing = REQUIRED_ENV.filter((key) => !process.env[key]);
if (!process.env.API_DATABASE_URL && !process.env.DATABASE_URL) {
  missing.push('API_DATABASE_URL or DATABASE_URL');
}
if (missing.length > 0) {
  throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
}

const jwtIssuer = process.env.JWT_ISSUER || 'pandapay-auth';
const jwtAudience = process.env.JWT_AUDIENCE || 'mobile-app';
const jwtActiveKeyId = process.env.JWT_ACTIVE_KEY_ID || '1';

let jwtKeys;
if (process.env.JWT_KEYS_JSON) {
  try {
    const parsed = JSON.parse(process.env.JWT_KEYS_JSON);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('JWT_KEYS_JSON must be a JSON object');
    }
    jwtKeys = Object.fromEntries(
      Object.entries(parsed).filter(
        ([keyId, secret]) => keyId && typeof secret === 'string' && secret,
      ),
    );
  } catch (error) {
    throw new Error(`Invalid JWT_KEYS_JSON: ${error.message}`);
  }
} else {
  jwtKeys = { [jwtActiveKeyId]: process.env.JWT_ACCESS_SECRET };
}

if (Object.keys(jwtKeys).length === 0) {
  throw new Error('JWT_KEYS_JSON must contain at least one signing key');
}

for (const key of [
  'AUTH_INTERNAL_SERVICE_SECRET',
  'REFERRAL_IDENTITY_HMAC_KEY',
  'REFERRAL_PREVIEW_SECRET',
  'ENGAGEMENT_RECEIPT_SECRET',
  'REWARD_WORKER_INTERNAL_SECRET',
]) {
  const value = process.env[key];
  if (value && Buffer.byteLength(value) < 32) {
    throw new Error(`${key} must contain at least 32 bytes`);
  }
}
if (!jwtKeys[jwtActiveKeyId]) {
  throw new Error(`JWT_ACTIVE_KEY_ID ${jwtActiveKeyId} is not present in JWT_KEYS_JSON`);
}

module.exports = {
  ...securityFeatures,
  isProduction,
  port: Number(process.env.PORT) || 4000,
  // Prefer the product database when both service URLs live in a shared
  // root .env. DATABASE_URL is retained for backwards-compatible local use.
  databaseUrl: process.env.API_DATABASE_URL || process.env.DATABASE_URL,
  // Same default as before this module existed: SSL on unless explicitly
  // disabled (local/dev docker-compose sets DB_SSL=false).
  dbSslEnabled: process.env.DB_SSL !== 'false',
  jwtAccessSecret: process.env.JWT_ACCESS_SECRET,
  jwtKeys,
  jwtIssuer,
  jwtAudience,
  authInternalBaseUrl: (process.env.AUTH_INTERNAL_BASE_URL || '').replace(/\/$/, '') || null,
  authInternalServiceSecret: process.env.AUTH_INTERNAL_SERVICE_SECRET || null,
  referralIdentityHmacKey: process.env.REFERRAL_IDENTITY_HMAC_KEY || null,
  referralIdentityHmacKeyVersion: process.env.REFERRAL_IDENTITY_HMAC_KEY_VERSION || 'v1',
  referralPreviewSecret: process.env.REFERRAL_PREVIEW_SECRET || null,
  engagementReceiptSecret: process.env.ENGAGEMENT_RECEIPT_SECRET || null,
  rewardWorkerInternalSecret: process.env.REWARD_WORKER_INTERNAL_SECRET || null,
  rewardWorkerApiUrl: (process.env.REWARD_WORKER_API_URL || 'http://api:4000').replace(/\/$/, ''),
  rewardWorkerId: process.env.REWARD_WORKER_ID || process.env.HOSTNAME || `rewards-${process.pid}`,
  rewardWorkerPollIntervalMs: Math.max(1000, Number(process.env.REWARD_WORKER_POLL_INTERVAL_MS) || 5000),
  rewardWorkerBatchSize: Math.min(20, Math.max(1, Number(process.env.REWARD_WORKER_BATCH_SIZE) || 5)),
  rewardWorkerLeaseSeconds: Math.min(900, Math.max(15, Number(process.env.REWARD_WORKER_LEASE_SECONDS) || 90)),
  rewardWorkerEnabled: process.env.REWARD_WORKER_ENABLED === 'true',
  productTermsVersion: process.env.PRODUCT_TERMS_VERSION || '2026-08-07',
  inboundEmailWebhookSecret: process.env.INBOUND_EMAIL_WEBHOOK_SECRET || null,
  partnerWebhookSecret: process.env.PARTNER_WEBHOOK_SECRET || null,
  partnerWebhookDatabaseUrl: process.env.PARTNER_WEBHOOK_DATABASE_URL || null,
  imapEncryptionKey: process.env.IMAP_ENCRYPTION_KEY || null,
  imapPollDatabaseUrl: process.env.IMAP_POLL_DATABASE_URL || null,
  accountLifecycleEnabled: ['true','1'].includes(process.env.ACCOUNT_LIFECYCLE_ENABLED),
  // Schema-first rollout: typed sync requires financial-state acceptance.
  syncTypedWritesEnabled: process.env.SYNC_TYPED_WRITES_ENABLED === 'true',
  accountLifecycleDatabaseUrl: process.env.ACCOUNT_LIFECYCLE_DATABASE_URL || null,
  notificationServiceUrl:
    process.env.NOTIFICATION_SERVICE_URL
    || process.env.NOVU_NOTIFICATION_URL
    || process.env.NOVU_API_URL
    || null,
  notificationServiceApiKey:
    process.env.NOTIFICATION_SERVICE_API_KEY
    || process.env.NOVU_NOTIFICATION_API_KEY
    || process.env.NOVU_API_KEY
    || null,
  notificationServiceFcmIntegrationIdentifier:
    process.env.NOTIFICATION_SERVICE_FCM_INTEGRATION_IDENTIFIER || null,
  notificationServiceWorkflowIdentifier:
    process.env.NOTIFICATION_SERVICE_WORKFLOW_IDENTIFIER || 'pandapay-push-notification',
  notificationServiceWorkflowName:
    process.env.NOTIFICATION_SERVICE_WORKFLOW_NAME || 'PandaPay push notification',
  notificationServiceTimeoutMs: Math.max(
    1000,
    Number(process.env.NOTIFICATION_SERVICE_TIMEOUT_MS) || 4000,
  ),
  // A user-scoped report must fail cleanly rather than holding a pooled
  // connection forever when the database is overloaded or a query plan
  // regresses. Routes turn this into a normal 500 and the client can use its
  // cached snapshot/retry affordance.
  dbStatementTimeoutMs: Math.max(
    1000,
    Number(process.env.DB_STATEMENT_TIMEOUT_MS) || 15000,
  ),
  dbPoolMax: Math.min(100, Math.max(1, Number(process.env.DB_POOL_MAX) || 10)),
  dbIdleTimeoutMs: Math.max(
    1000,
    Number(process.env.DB_IDLE_TIMEOUT_MS) || 10000,
  ),
  dbConnectionTimeoutMs: Math.max(
    1000,
    Number(process.env.DB_CONNECTION_TIMEOUT_MS) || 5000,
  ),
};
