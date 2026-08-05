// src/config.js
// === ADDED FOR RATE LIMITING ===
// Environment variables for rate limiting (used in middleware/rateLimitMiddleware.js):
// - REDIS_URL: Full Redis connection URL (e.g., redis://localhost:6379)
//   OR use REDIS_HOST and REDIS_PORT separately
// - REDIS_HOST: Redis host (default: localhost)
// - REDIS_PORT: Redis port (default: 6379)
// - REDIS_PASSWORD: Redis password (optional)
// - OTP_REQ_PHONE_10MIN_LIMIT: Max OTP requests per phone per 10 min (default: 3)
// - OTP_REQ_PHONE_DAY_LIMIT: Max OTP requests per phone per 24 hours (default: 10)
// - OTP_REQ_IP_10MIN_LIMIT: Max OTP requests per IP per 10 min (default: 20)
// - OTP_REQ_IP_DAY_LIMIT: Max OTP requests per IP per 24 hours (default: 100)
// - OTP_VERIFY_MAX_ATTEMPTS: Max verification attempts per OTP (default: 5)
// - OTP_VERIFY_FAILED_PER_HOUR_LIMIT: Max failed verifications per phone per hour (default: 10)
// - OTP_TTL_SECONDS: OTP validity in seconds (default: 120, i.e., 2 minutes)
//
// === SECURITY HARDENING: JWT KEY ROTATION ===
// - JWT_ACTIVE_KEY_ID: Key ID to use for signing new tokens (default: '1')
// - JWT_KEYS_JSON: JSON object mapping key IDs to secrets, e.g. '{"1":"secret1","2":"secret2"}'
//   OR use legacy: JWT_ACCESS_SECRET, JWT_REFRESH_SECRET
// - JWT_REFRESH_KEY_ID: Key ID for refresh tokens (default: same as active key)
// - JWT_ISSUER: Issuer claim (iss) for tokens (default: 'farm-auth-service')
// - JWT_AUDIENCE: Audience claim (aud) for tokens (default: 'mobile-app')
//
// === SECURITY HARDENING: IP/DEVICE RISK ===
// - BLOCKED_IP_RANGES: Comma-separated CIDR blocks to block (e.g., '10.0.0.0/8,172.16.0.0/12')
// - REQUIRE_OTP_ON_SUSPICIOUS_REFRESH: Require OTP re-verification on suspicious refresh (default: false)
//
// === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
// - STEP_UP_OTP_WINDOW_MINUTES: Time window for "recent" OTP verification (default: 5)
//
// === SECURITY HARDENING: CORS ===
// - CORS_ALLOWED_ORIGINS: Comma-separated list of allowed origins (REQUIRED in production)
//   Example: 'https://app.example.com,https://api.example.com'
//   WARNING: Never use '*' when credentials or tokens are involved
require('dotenv').config();

// DATABASE_URL is only required if not using AWS SSM Parameter Store
const REQUIRED_ENV = [
  'JWT_ACCESS_SECRET',
  'JWT_REFRESH_SECRET',
];

// If using AWS SSM, DATABASE_URL is optional (credentials come from SSM)
if (process.env.USE_AWS_SSM !== 'true' && process.env.USE_AWS_SSM !== '1') {
  REQUIRED_ENV.push('DATABASE_URL');
}

const missing = REQUIRED_ENV.filter((key) => !process.env[key]);
if (missing.length > 0) {
  throw new Error(
    `Missing required environment variables: ${missing.join(', ')}`
  );
}

const corsAllowedOrigins = (process.env.CORS_ALLOWED_ORIGINS || '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

const isProduction = process.env.NODE_ENV === 'production';

const refreshMaxIdleMinutes = Number(
  process.env.REFRESH_MAX_IDLE_MINUTES || 4320
);

if (isProduction && corsAllowedOrigins.length === 0) {
  throw new Error(
    'CORS_ALLOWED_ORIGINS must be set (comma-separated) in production'
  );
}

module.exports = {
  databaseUrl: process.env.DATABASE_URL,
  jwtAccessSecret: process.env.JWT_ACCESS_SECRET,
  jwtRefreshSecret: process.env.JWT_REFRESH_SECRET,
  jwtAccessTtl: process.env.JWT_ACCESS_TTL || '15m',
  jwtRefreshTtl: process.env.JWT_REFRESH_TTL || '7d',
  corsAllowedOrigins,
  isProduction,
  refreshMaxIdleMinutes,
  googleClientId: process.env.GOOGLE_CLIENT_ID,
  emailHost: process.env.EMAIL_HOST,
  emailPort: process.env.EMAIL_PORT,
  emailUser: process.env.EMAIL_USER,
  emailPass: process.env.EMAIL_PASS,
  emailFrom: process.env.EMAIL_FROM,
  enablePhoneOtp: process.env.ENABLE_PHONE_OTP !== 'false',
  enableEmailOtp: process.env.ENABLE_EMAIL_OTP !== 'false',
};

