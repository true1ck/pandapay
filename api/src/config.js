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

require('dotenv').config();

const isProduction = process.env.NODE_ENV === 'production';

// DATABASE_URL and JWT_ACCESS_SECRET are required everywhere — api/ cannot
// do anything useful without a database or without being able to verify
// auth/'s tokens (api/src/auth.js already throws on the latter today; this
// just makes it one consistent check instead of two).
const REQUIRED_ENV = ['DATABASE_URL', 'JWT_ACCESS_SECRET'];

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
    'IMAP_ENCRYPTION_KEY'
  );
}

const missing = REQUIRED_ENV.filter((key) => !process.env[key]);
if (missing.length > 0) {
  throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
}

module.exports = {
  isProduction,
  port: Number(process.env.PORT) || 4000,
  databaseUrl: process.env.DATABASE_URL,
  // Same default as before this module existed: SSL on unless explicitly
  // disabled (local/dev docker-compose sets DB_SSL=false).
  dbSslEnabled: process.env.DB_SSL !== 'false',
  jwtAccessSecret: process.env.JWT_ACCESS_SECRET,
  inboundEmailWebhookSecret: process.env.INBOUND_EMAIL_WEBHOOK_SECRET || null,
  partnerWebhookSecret: process.env.PARTNER_WEBHOOK_SECRET || null,
  imapEncryptionKey: process.env.IMAP_ENCRYPTION_KEY || null,
};
