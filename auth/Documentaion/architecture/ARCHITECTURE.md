# Farm Auth Service - Architecture Documentation

## 1. High-Level Overview

The Farm Auth Service is a Node.js + Express authentication and security service that provides phone-based authentication using OTP (One-Time Password) via SMS, JWT-based access and refresh tokens, comprehensive rate limiting, security hardening, and audit logging. The service is designed for a mobile application ecosystem where users authenticate using their phone numbers.

**Core Functionality:**
- Phone number-based authentication with OTP verification via SMS (Twilio)
- JWT access tokens (short-lived) and refresh tokens (long-lived) with rotation
- Device tracking and multi-device session management
- Comprehensive rate limiting at multiple levels (phone, IP, user)
- Security hardening: CORS validation, security headers, field-level encryption, timing attack protection, enumeration detection
- Audit logging with risk scoring and webhook alerting
- Admin dashboard for security event monitoring

**External Systems:**
- **PostgreSQL Database**: Stores users, OTP codes, refresh tokens, devices, and audit logs
- **Redis** (optional): Used for rate limiting counters and OTP tracking (falls back to in-memory store)
- **Twilio**: SMS provider for OTP delivery (optional - service works without it for development)
- **Webhook Endpoints**: For security alerts (Slack, Discord, or custom webhooks)

---

## 2. Architecture & Components

### 2.1 HTTP/API Layer

**Files:**
- `src/index.js` - Express server setup and middleware configuration
- `src/routes/authRoutes.js` - Authentication endpoints
- `src/routes/userRoutes.js` - User profile and device management endpoints
- `src/routes/adminRoutes.js` - Admin security dashboard endpoints

**Responsibilities:**
- Request routing and middleware orchestration
- Input validation and sanitization
- Response formatting
- Error handling

**Middleware Order (Critical):**
1. Trust proxy configuration (if behind reverse proxy)
2. CORS validation (startup and runtime)
3. JSON body parser
4. Security headers (global)
5. Route-specific middleware (validation, rate limiting, auth)

**Key Configuration:**
- `TRUST_PROXY`: Set to `'true'` if behind reverse proxy (nginx, load balancer)
- `CORS_ALLOWED_ORIGINS`: Comma-separated list of allowed origins (required in production)
- `ENABLE_ADMIN_DASHBOARD`: Set to `'true'` to enable admin routes

### 2.2 Authentication Core

**Files:**
- `src/services/otpService.js` - OTP generation, hashing (bcrypt), storage, and verification
- `src/services/tokenService.js` - JWT access/refresh token issuance, rotation, and validation
- `src/services/jwtKeys.js` - JWT key management with rotation support
- `src/middleware/authMiddleware.js` - JWT access token validation
- `src/middleware/stepUpAuth.js` - Step-up authentication for sensitive operations

**Responsibilities:**
- OTP generation (4-digit random codes)
- OTP hashing with bcrypt (10 rounds)
- OTP storage in database with expiry and attempt tracking
- JWT token signing with key rotation support
- Refresh token rotation and reuse detection
- Device fingerprinting and tracking

**Key Features:**
- **OTP Security**: Hashed with bcrypt, constant-time verification to prevent timing attacks
- **Token Rotation**: Refresh tokens rotate on each use, old tokens are revoked
- **Reuse Detection**: Detects if a refresh token is reused (theft indicator)
- **Step-Up Auth**: Requires recent OTP verification for sensitive operations

### 2.3 Security Layer

**Files:**
- `src/middleware/rateLimitMiddleware.js` - OTP request/verification rate limiting
- `src/middleware/userRateLimit.js` - User route rate limiting (read/write/sensitive)
- `src/middleware/adminRateLimit.js` - Admin route rate limiting
- `src/middleware/securityHeaders.js` - Security headers (CSP, HSTS, X-Frame-Options, etc.)
- `src/utils/corsValidator.js` - CORS configuration validation
- `src/utils/timingProtection.js` - Timing attack protection for OTP flows
- `src/utils/enumerationDetection.js` - Phone number enumeration detection
- `src/services/riskScoring.js` - Risk scoring for login/refresh attempts
- `src/middleware/validation.js` - Input validation middleware

**Responsibilities:**
- Rate limiting at multiple levels (phone, IP, user, admin)
- Security headers enforcement
- CORS origin validation (startup and runtime)
- Timing attack mitigation (constant-time OTP verification)
- Enumeration detection and IP blocking
- Risk scoring based on IP/device changes
- Input validation and sanitization

**Key Features:**
- **Multi-Level Rate Limiting**: Phone-based, IP-based, and user-based limits
- **Enumeration Protection**: Detects and blocks IPs attempting phone number enumeration
- **Timing Attack Protection**: All OTP operations use constant-time execution
- **Risk Scoring**: Calculates risk scores for suspicious login/refresh attempts

### 2.4 Persistence Layer

**Files:**
- `src/db.js` - PostgreSQL connection pool and query wrapper
- `src/middleware/dbAccessLogger.js` - Optional database access logging
- `src/utils/fieldEncryption.js` - Field-level encryption for PII (phone numbers)
- `src/utils/encryptedPhoneSearch.js` - Phone number search with encryption support

**Database Tables:**
- `users` - User accounts (phone number, name, role, user_type)
- `otp_codes` - OTP codes (hashed, with expiry and attempt tracking)
- `refresh_tokens` - Refresh tokens (hashed, with rotation tracking)
- `user_devices` - Device tracking (platform, model, OS, app version)
- `auth_audit` - Security audit logs (all authentication events)

**Responsibilities:**
- Database connection management
- Query execution with optional logging
- Field-level encryption for sensitive data (phone numbers)
- Database schema management (auto-creates tables if missing)

**Key Features:**
- **Field-Level Encryption**: Phone numbers encrypted at rest (AES-256-GCM)
- **Database Access Logging**: Optional logging of all DB queries (for security auditing)
- **Backward Compatibility**: Handles both encrypted and plaintext phone numbers during migration

### 2.5 Integration Layer

**Files:**
- `src/services/smsService.js` - Twilio SMS integration
- `src/services/auditLogger.js` - Audit logging with webhook alerting
- `src/services/redisClient.js` - Redis client with graceful fallback

**Responsibilities:**
- SMS delivery via Twilio (with fallback logging)
- Security event logging to database
- Webhook alerting for high-risk events
- Redis connection management (optional, falls back to in-memory)

**Key Features:**
- **Twilio Integration**: Sends OTP via SMS (optional - works without for development)
- **Webhook Alerting**: Sends alerts to Slack/Discord/custom webhooks for SUSPICIOUS/HIGH_RISK events
- **Redis Fallback**: Gracefully falls back to in-memory store if Redis unavailable

---

## 3. Request Flows

### 3.1 OTP Login Flow

**Step-by-Step:**

1. **Client requests OTP** (`POST /auth/request-otp`)
   - Input validation (phone number format)
   - Check for active OTP (2-minute no-resend rule)
   - Rate limit by phone number (3 per 10 min, 10 per day)
   - Rate limit by IP address (20 per 10 min, 100 per day)
   - Check if IP is blocked (enumeration or CIDR ranges)
   - Enumeration detection (if suspicious, apply stricter limits)
   - Timing protection wrapper (constant-time execution)
   - Normalize phone number (E.164 format)
   - Generate 4-digit OTP code
   - Hash OTP with bcrypt (10 rounds)
   - Encrypt phone number (if encryption enabled)
   - Store OTP in database (delete old OTPs for same phone)
   - Mark OTP as active in Redis/memory (2-minute TTL)
   - Send SMS via Twilio (or log to console if not configured)
   - Log audit event (otp_request, INFO risk level)
   - Return success (even if SMS fails - OTP is generated)

2. **Client verifies OTP** (`POST /auth/verify-otp`)
   - Input validation (phone number, 4-digit code, device_id, device_info)
   - Rate limit failed verifications (10 per hour per phone)
   - Check if IP is blocked
   - Timing protection wrapper (constant-time execution)
   - Normalize phone number
   - Encrypt phone number for search
   - Query OTP from database (with constant-time dummy hash if not found)
   - Check expiry, max attempts, and verify code (all with constant-time bcrypt.compare)
   - If invalid: increment attempt count, log suspicious event, return generic error
   - If valid: delete OTP, find or create user, decrypt phone number
   - Update user last_login_at
   - Upsert device record (track platform, model, OS, app version)
   - Calculate risk score (IP change, device change, user agent change)
   - Log audit event (login, risk level based on score)
   - Check for anomalies (multiple failed attempts, high-risk IPs)
   - Issue access token (with high_assurance flag) and refresh token
   - Return user data, tokens, and device info

**Mermaid Sequence Diagram:**

```mermaid
sequenceDiagram
    participant Client
    participant API
    participant RateLimiter
    participant OTPService
    participant DB
    participant Twilio
    participant AuditLogger

    Client->>API: POST /auth/request-otp<br/>{phone_number}
    API->>API: Validate input
    API->>RateLimiter: Check active OTP (2-min rule)
    RateLimiter-->>API: No active OTP
    API->>RateLimiter: Rate limit by phone (3/10min)
    RateLimiter-->>API: Allowed
    API->>RateLimiter: Rate limit by IP (20/10min)
    RateLimiter-->>API: Allowed
    API->>API: Check IP blocking
    API->>OTPService: Generate OTP
    OTPService->>DB: Store hashed OTP
    OTPService->>RateLimiter: Mark active (2-min TTL)
    API->>Twilio: Send SMS
    Twilio-->>API: SMS sent (or error)
    API->>AuditLogger: Log otp_request event
    API-->>Client: {ok: true}

    Client->>API: POST /auth/verify-otp<br/>{phone_number, code, device_id}
    API->>API: Validate input
    API->>RateLimiter: Check failed attempts (10/hour)
    RateLimiter-->>API: Allowed
    API->>OTPService: Verify OTP (constant-time)
    OTPService->>DB: Query OTP (with dummy hash if not found)
    OTPService->>OTPService: bcrypt.compare (constant-time)
    alt OTP Valid
        OTPService->>DB: Delete OTP
        API->>DB: Find or create user
        API->>DB: Upsert device
        API->>API: Calculate risk score
        API->>AuditLogger: Log login (with risk level)
        API->>API: Issue access + refresh tokens
        API-->>Client: {user, access_token, refresh_token}
    else OTP Invalid
        OTPService->>DB: Increment attempt count
        API->>AuditLogger: Log suspicious attempt
        API-->>Client: {error: "OTP invalid or expired"}
    end
```

### 3.2 Token Refresh Flow

**Step-by-Step:**

1. **Client requests token refresh** (`POST /auth/refresh`)
   - Input validation (refresh_token)
   - Check if IP is blocked
   - Decode refresh token to get key ID
   - Verify refresh token signature (try all keys if key ID not found)
   - Validate JWT claims (iss, aud, exp, iat)
   - Query refresh token from database (by token_id)
   - Verify token hash matches (bcrypt.compare)
   - Check if token is revoked or expired
   - Check refresh token idle timeout (max idle minutes)
   - Calculate risk score (IP change, device change, user agent change)
   - If suspicious: log suspicious refresh event
   - If suspicious and REQUIRE_OTP_ON_SUSPICIOUS_REFRESH: return step_up_required error
   - Update token last_used_at
   - Revoke old refresh token
   - Issue new access token and new refresh token (rotation)
   - Update device last_seen_at
   - Log audit event (token_refresh, risk level based on score)
   - Return new tokens

**Mermaid Sequence Diagram:**

```mermaid
sequenceDiagram
    participant Client
    participant API
    participant TokenService
    participant JWTKeys
    participant DB
    participant RiskScoring
    participant AuditLogger

    Client->>API: POST /auth/refresh<br/>{refresh_token}
    API->>API: Validate input
    API->>API: Check IP blocking
    API->>TokenService: Verify refresh token
    TokenService->>JWTKeys: Get key secret (by key ID)
    JWTKeys-->>TokenService: Key secret
    TokenService->>TokenService: Verify JWT signature
    TokenService->>TokenService: Validate claims (iss, aud, exp)
    TokenService->>DB: Query refresh token (by token_id)
    DB-->>TokenService: Token record
    TokenService->>TokenService: Verify token hash (bcrypt)
    alt Token Valid
        TokenService->>TokenService: Check expiry & idle timeout
        API->>RiskScoring: Calculate risk score
        RiskScoring->>DB: Get previous auth info
        RiskScoring-->>API: Risk score & reasons
        alt Suspicious Refresh
            API->>AuditLogger: Log suspicious refresh
            alt Require OTP
                API-->>Client: {error: "step_up_required"}
            else Allow with Risk
                API->>TokenService: Rotate refresh token
                TokenService->>DB: Revoke old token
                TokenService->>DB: Store new token
                API->>AuditLogger: Log refresh (SUSPICIOUS/HIGH_RISK)
                API-->>Client: {access_token, refresh_token}
            end
        else Normal Refresh
            API->>TokenService: Rotate refresh token
            TokenService->>DB: Revoke old token
            TokenService->>DB: Store new token
            API->>DB: Update device last_seen_at
            API->>AuditLogger: Log refresh (INFO)
            API-->>Client: {access_token, refresh_token}
        end
    else Token Invalid
        API-->>Client: {error: "Invalid refresh token"}
    end
```

### 3.3 Logout Flow

**Step-by-Step:**

1. **Single-device logout** (`POST /auth/logout`)
   - Input validation (refresh_token)
   - Verify refresh token (same as refresh flow)
   - If token invalid/already revoked: return success (idempotent)
   - Revoke all refresh tokens for user + device
   - Log audit event (logout, INFO)
   - Return success

2. **Logout all other devices** (`POST /users/me/logout-all-other-devices`)
   - Requires authentication (access token)
   - Requires step-up auth (recent OTP or high_assurance token)
   - Rate limited (10 per hour per user)
   - Get current device_id from header or body
   - Mark all other devices as inactive
   - Revoke refresh tokens for all other devices
   - Log audit event (logout_all_other_devices, INFO)
   - Return count of revoked devices

3. **Logout from all devices** (`POST /users/me/logout-all-devices`)
   - Requires authentication (access token)
   - Requires step-up auth (recent OTP or high_assurance token)
   - Rate limited (10 per hour per user)
   - Revoke all refresh tokens for the user (all devices)
   - Mark all devices as inactive
   - Increment user's `token_version` to invalidate all existing access tokens
   - Log audit event (logout_all_devices, HIGH_RISK) - triggers security alert
   - Return success with revoked tokens count
   - **Security Note**: This is a critical security operation used when account compromise is suspected. All existing access tokens become invalid immediately, even if they haven't expired yet.

4. **Revoke specific device** (`DELETE /users/me/devices/:device_id`)
   - Requires authentication (access token)
   - Requires step-up auth (recent OTP or high_assurance token)
   - Rate limited (10 per hour per user)
   - Validate device_id parameter
   - Mark device as inactive
   - Revoke refresh tokens for device
   - Log audit event (device_revoked, INFO)
   - Return success

**Mermaid Sequence Diagram:**

```mermaid
sequenceDiagram
    participant Client
    participant API
    participant TokenService
    participant DB
    participant AuditLogger

    Note over Client,AuditLogger: Single Device Logout
    Client->>API: POST /auth/logout<br/>{refresh_token}
    API->>TokenService: Verify refresh token
    TokenService-->>API: Token info
    API->>TokenService: Revoke refresh token
    TokenService->>DB: Mark token revoked
    API->>AuditLogger: Log logout event
    API-->>Client: {ok: true}

    Note over Client,AuditLogger: Logout All Other Devices
    Client->>API: POST /users/me/logout-all-other-devices<br/>{current_device_id}
    API->>API: Verify access token
    API->>API: Check step-up auth
    API->>API: Rate limit check (10/hour)
    API->>DB: Mark other devices inactive
    API->>TokenService: Revoke tokens for other devices
    TokenService->>DB: Revoke tokens
    API->>AuditLogger: Log logout_all_other_devices
    API-->>Client: {ok: true, revoked_devices_count: N}

    Note over Client,AuditLogger: Logout All Devices (Global Logout)
    Client->>API: POST /users/me/logout-all-devices
    API->>API: Verify access token
    API->>API: Check step-up auth
    API->>API: Rate limit check (10/hour)
    API->>TokenService: Revoke all user tokens
    TokenService->>DB: Revoke all refresh tokens
    TokenService->>DB: Mark all devices inactive
    TokenService->>DB: Increment token_version
    API->>AuditLogger: Log logout_all_devices (HIGH_RISK)
    AuditLogger->>AuditLogger: Trigger security alert
    API-->>Client: {ok: true, revoked_tokens_count: N}
```

### 3.4 Admin Security Events Flow

**Step-by-Step:**

1. **Admin requests security events** (`GET /admin/security-events`)
   - Requires authentication (access token)
   - Requires admin role (security_admin)
   - Rate limited (100 per 15 minutes per admin)
   - Validate and sanitize query parameters (risk_level, limit, offset, search)
   - Build parameterized SQL query (prevent injection)
   - Query auth_audit table with filters
   - Mask phone numbers (keep last 4 digits)
   - Sanitize all output fields
   - Get total count for pagination
   - Get statistics (last 24 hours: total, high_risk, suspicious, info)
   - Log admin access event (admin_view_security_events, INFO)
   - Return events, pagination info, and statistics

**Mermaid Sequence Diagram:**

```mermaid
sequenceDiagram
    participant Admin
    participant API
    participant AuthMiddleware
    participant AdminAuth
    participant AdminRateLimit
    participant DB
    participant AuditLogger

    Admin->>API: GET /admin/security-events<br/>?risk_level=HIGH_RISK&limit=200
    API->>AuthMiddleware: Verify access token
    AuthMiddleware-->>API: User info
    API->>AdminAuth: Check admin role
    AdminAuth-->>API: Authorized
    API->>AdminRateLimit: Check rate limit (100/15min)
    AdminRateLimit-->>API: Allowed
    API->>API: Sanitize query params
    API->>DB: Query auth_audit (parameterized)
    DB-->>API: Events data
    API->>API: Mask phone numbers
    API->>API: Sanitize output
    API->>DB: Get total count
    API->>DB: Get statistics (24h)
    API->>AuditLogger: Log admin access
    API-->>Admin: {events, pagination, stats}
```

---

## 4. Timeouts, Expiry, and Limits

| Name | ENV Variable / Config | Default Value | Defined In | What It Affects |
|------|----------------------|---------------|------------|-----------------|
| **OTP Expiry** | `OTP_TTL_SECONDS` | `120` (2 minutes) | `src/services/otpService.js:10` | OTP validity period |
| **OTP Resend Throttle** | (hardcoded) | `120` seconds | `src/middleware/rateLimitMiddleware.js:154` | Minimum time between OTP requests for same phone |
| **Max OTP Verification Attempts** | `OTP_VERIFY_MAX_ATTEMPTS` | `5` | `src/services/otpService.js:12` | Maximum attempts to verify an OTP before it's invalidated |
| **JWT Access Token Expiry** | `JWT_ACCESS_TTL` | `'15m'` (15 minutes) | `src/config.js:72` | Access token lifetime |
| **JWT Refresh Token Expiry** | `JWT_REFRESH_TTL` | `'7d'` (7 days) | `src/config.js:73` | Refresh token lifetime |
| **Refresh Token Max Idle** | `REFRESH_MAX_IDLE_MINUTES` | `4320` (3 days) | `src/config.js:58-60` | Maximum idle time before refresh token expires |
| **Step-Up Auth Window** | `STEP_UP_OTP_WINDOW_MINUTES` | `5` minutes | `src/middleware/stepUpAuth.js:26` | Time window for "recent" OTP verification for step-up auth |
| **OTP Request - Phone (10 min)** | `OTP_REQ_PHONE_10MIN_LIMIT` | `3` | `src/middleware/rateLimitMiddleware.js:24` | Max OTP requests per phone per 10 minutes |
| **OTP Request - Phone (24h)** | `OTP_REQ_PHONE_DAY_LIMIT` | `10` | `src/middleware/rateLimitMiddleware.js:25` | Max OTP requests per phone per 24 hours |
| **OTP Request - IP (10 min)** | `OTP_REQ_IP_10MIN_LIMIT` | `20` | `src/middleware/rateLimitMiddleware.js:26` | Max OTP requests per IP per 10 minutes |
| **OTP Request - IP (24h)** | `OTP_REQ_IP_DAY_LIMIT` | `100` | `src/middleware/rateLimitMiddleware.js:27` | Max OTP requests per IP per 24 hours |
| **OTP Verify Failed (1h)** | `OTP_VERIFY_FAILED_PER_HOUR_LIMIT` | `10` | `src/middleware/rateLimitMiddleware.js:31` | Max failed verification attempts per phone per hour |
| **Enumeration IP Block Duration** | `ENUMERATION_BLOCK_DURATION` | `3600` (1 hour) | `src/middleware/rateLimitMiddleware.js:40` | Duration IP is blocked after enumeration detection |
| **User Rate Limit - Read** | `USER_RATE_LIMIT_READ_MAX` | `100` | `src/middleware/userRateLimit.js:25` | Max read requests per user per 15 minutes |
| **User Rate Limit - Read Window** | `USER_RATE_LIMIT_READ_WINDOW` | `900` (15 min) | `src/middleware/userRateLimit.js:26` | Time window for read rate limit |
| **User Rate Limit - Write** | `USER_RATE_LIMIT_WRITE_MAX` | `20` | `src/middleware/userRateLimit.js:29` | Max write requests per user per 15 minutes |
| **User Rate Limit - Write Window** | `USER_RATE_LIMIT_WRITE_WINDOW` | `900` (15 min) | `src/middleware/userRateLimit.js:30` | Time window for write rate limit |
| **User Rate Limit - Sensitive** | `USER_RATE_LIMIT_SENSITIVE_MAX` | `10` | `src/middleware/userRateLimit.js:33` | Max sensitive requests per user per hour |
| **User Rate Limit - Sensitive Window** | `USER_RATE_LIMIT_SENSITIVE_WINDOW` | `3600` (1 hour) | `src/middleware/userRateLimit.js:34` | Time window for sensitive rate limit |
| **Admin Rate Limit** | `ADMIN_RATE_LIMIT_MAX` | `100` | `src/middleware/adminRateLimit.js:23` | Max admin requests per admin per 15 minutes |
| **Admin Rate Limit Window** | `ADMIN_RATE_LIMIT_WINDOW` | `900` (15 min) | `src/middleware/adminRateLimit.js:24` | Time window for admin rate limit |
| **Twilio HTTP Timeout** | (hardcoded) | `5000` ms | `src/services/auditLogger.js:459` | Webhook request timeout (also used for Twilio if configured) |
| **Webhook Retry Delay** | (hardcoded) | `3000` ms | `src/services/auditLogger.js:498` | Delay before retrying failed webhook alerts |
| **OTP Request Min Delay** | `OTP_REQUEST_MIN_DELAY` | `500` ms | `src/utils/timingProtection.js:26` | Minimum delay for OTP requests (timing attack protection) |
| **OTP Verify Min Delay** | `OTP_VERIFY_MIN_DELAY` | `300` ms | `src/utils/timingProtection.js:30` | Minimum delay for OTP verification (timing attack protection) |
| **Timing Max Jitter** | `TIMING_MAX_JITTER` | `100` ms | `src/utils/timingProtection.js:34` | Maximum random jitter added to delays |
| **Enumeration Max Phones/IP (10min)** | `ENUMERATION_MAX_PHONES_PER_IP_10MIN` | `5` | `src/utils/enumerationDetection.js:32` | Max unique phone numbers per IP in 10 minutes |
| **Enumeration Max Phones/IP (1h)** | `ENUMERATION_MAX_PHONES_PER_IP_HOUR` | `20` | `src/utils/enumerationDetection.js:33` | Max unique phone numbers per IP in 1 hour |
| **Enumeration Alert Threshold (10min)** | `ENUMERATION_ALERT_THRESHOLD_10MIN` | `10` | `src/utils/enumerationDetection.js:40` | Unique phones threshold for alert (10 min) |
| **Enumeration Alert Threshold (1h)** | `ENUMERATION_ALERT_THRESHOLD_HOUR` | `50` | `src/utils/enumerationDetection.js:41` | Unique phones threshold for alert (1 hour) |

---

## 5. Security Features

### 5.1 CORS Behavior

**Configuration:**
- **Startup Validation**: CORS configuration is validated at startup (`src/index.js:29-34`)
- **Runtime Monitoring**: Runtime CORS checks log warnings for suspicious patterns (`src/index.js:58-63`)
- **Origin Whitelisting**: Only explicitly configured origins are allowed (never wildcard `*` when credentials are involved)
- **No-Origin Requests**: Requests without origin (mobile apps, Postman) are allowed

**Implementation:**
- `CORS_ALLOWED_ORIGINS`: Comma-separated list of allowed origins (required in production)
- Development mode: Allows all origins if no origins configured (with warning)
- Production mode: Throws error if `CORS_ALLOWED_ORIGINS` is empty

**Files:**
- `src/index.js:36-86` - CORS middleware configuration
- `src/utils/corsValidator.js` - CORS validation utilities

### 5.2 Security Headers

**Headers Set Globally:**
- `X-Frame-Options: DENY` - Prevents clickjacking
- `X-Content-Type-Options: nosniff` - Prevents MIME type sniffing
- `X-XSS-Protection: 1; mode=block` - Enables XSS filter (legacy browsers)
- `Strict-Transport-Security` - HSTS (only in production, max-age=31536000, includeSubDomains, preload)
- `Content-Security-Policy` - CSP with nonce support for inline scripts/styles
- `Referrer-Policy: strict-origin-when-cross-origin` - Controls referrer information
- `Permissions-Policy` - Restricts browser features (geolocation, microphone, camera, etc.)

**Files:**
- `src/middleware/securityHeaders.js` - Security headers middleware

### 5.3 Authentication & Authorization

**Authentication:**
- **OTP-Based**: Phone number + 4-digit OTP code
- **JWT Access Tokens**: Short-lived (15 minutes), signed with HS256, include `token_version` claim
- **JWT Refresh Tokens**: Long-lived (7 days), stored hashed in database, rotated on each use
- **Device Tracking**: Tracks device identifier, platform, model, OS version, app version
- **Token Versioning**: Access tokens include `token_version` claim that is validated against user's current version in database. When user logs out from all devices, `token_version` is incremented, invalidating all existing access tokens immediately.

**Authorization:**
- **Role-Based**: Admin routes require `role === 'security_admin'`
- **Step-Up Auth**: Sensitive operations require recent OTP verification or `high_assurance` token flag
- **Token Claims**: Validates `iss` (issuer), `aud` (audience), `exp` (expiration), `iat` (issued at), `token_version` (for access token invalidation)

**Files:**
- `src/middleware/authMiddleware.js` - Access token validation
- `src/middleware/adminAuth.js` - Admin role check
- `src/middleware/stepUpAuth.js` - Step-up authentication

### 5.4 Audit Logging

**Events Logged:**
- `otp_request` - OTP request (success/failed)
- `otp_verify` - OTP verification (success/failed)
- `login` - User login (success/blocked)
- `token_refresh` - Token refresh (success, with risk level)
- `logout` - User logout
- `device_revoked` - Device revocation
- `logout_all_other_devices` - Logout all other devices
- `logout_all_devices` - Logout from all devices (HIGH_RISK, triggers security alert)
- `admin_view_security_events` - Admin access to security dashboard

**Risk Levels:**
- `INFO` - Normal operations
- `SUSPICIOUS` - Unusual patterns (IP change, device change, multiple failures)
- `HIGH_RISK` - Blocked IPs, high risk scores (>=50), enumeration attempts

**Alerting:**
- **Webhook Integration**: Sends alerts to `SECURITY_ALERT_WEBHOOK_URL` for SUSPICIOUS/HIGH_RISK events
- **Anomaly Detection**: Detects patterns (multiple failed OTPs, multiple high-risk events from same IP)
- **Retry Logic**: Retries failed webhook alerts once after 3 seconds

**Files:**
- `src/services/auditLogger.js` - Audit logging and webhook alerting
- `src/services/riskScoring.js` - Risk score calculation

### 5.5 Data Protection

**Field-Level Encryption:**
- **Algorithm**: AES-256-GCM (authenticated encryption)
- **Fields Encrypted**: Phone numbers (before storing in database)
- **Key Management**: 32-byte key from `ENCRYPTION_KEY` (base64 encoded)
- **Backward Compatibility**: Handles both encrypted and plaintext data during migration

**Database Access Logging:**
- **Optional Feature**: Enabled with `DB_ACCESS_LOGGING_ENABLED=true`
- **Logs**: All database queries with context (user ID, IP, user agent)
- **Use Case**: Security auditing, compliance

**Files:**
- `src/utils/fieldEncryption.js` - Field-level encryption
- `src/middleware/dbAccessLogger.js` - Database access logging

### 5.6 Protection Against Attacks

**Brute-Force / Enumeration:**
- Rate limiting at multiple levels (phone, IP, user)
- Enumeration detection (tracks unique phone numbers per IP)
- IP blocking for enumeration attempts (1 hour block)
- Stricter rate limits when enumeration detected

**Timing Attacks:**
- Constant-time OTP verification (always performs bcrypt.compare, uses dummy hash if OTP not found)
- Timing protection wrappers for OTP request and verification flows
- Minimum delay enforcement to prevent timing leaks

**Man-in-the-Middle:**
- HTTPS enforcement via HSTS header (production)
- Security headers (CSP, X-Frame-Options) prevent various MITM attacks
- JWT token validation with signature verification

**Token Replay:**
- Refresh token rotation (new token issued, old token revoked)
- Reuse detection (if old token is used, all tokens for device are revoked)
- Access token short expiry (15 minutes) limits replay window
- Token versioning: Access tokens include `token_version` claim that is validated on each request. When user logs out from all devices, version is incremented, immediately invalidating all existing access tokens (even if not expired)

**Files:**
- `src/utils/timingProtection.js` - Timing attack protection
- `src/utils/enumerationDetection.js` - Enumeration detection
- `src/services/tokenService.js` - Token rotation and reuse detection

---

## 6. Error Handling & Failure Modes

### 6.1 OTP Sending Failures

**Behavior:**
- If Twilio is not configured: OTP is logged to console, request still succeeds
- If Twilio fails: Error is logged, OTP is still generated and stored, request succeeds
- **Rationale**: OTP generation should not fail if SMS delivery fails (user can check logs in development)

**Error Response:**
- Success response returned even if SMS fails (for development/testing)
- Production recommendation: Return error if SMS fails (uncomment error return in `src/routes/authRoutes.js:213`)

**Files:**
- `src/services/smsService.js` - SMS sending with fallback logging

### 6.2 Database Failures

**Behavior:**
- Connection pool errors: Logged, process exits (`src/db.js:11-14`)
- Query errors: Propagated to route handler, return 500 error
- **No Retries**: Database queries are not retried automatically (application-level retries can be added)

**Error Response:**
- `500 Internal Server Error` with generic message: `{error: 'Internal server error'}`

**Files:**
- `src/db.js` - Database connection and query wrapper

### 6.3 JWT Validation Errors

**Behavior:**
- Invalid token format: `401 Unauthorized` - `{error: 'Invalid token format'}`
- Invalid/expired token: `401 Unauthorized` - `{error: 'Invalid or expired token'}`
- Invalid claims: `401 Unauthorized` - `{error: 'Invalid token claims'}`
- Missing Authorization header: `401 Unauthorized` - `{error: 'Missing Authorization header'}`

**Key Rotation:**
- If key ID not found: Tries all available keys (for rotation support)
- If no key matches: Returns `401 Unauthorized`

**Files:**
- `src/middleware/authMiddleware.js` - JWT validation
- `src/services/tokenService.js` - Refresh token validation

### 6.4 Rate Limit Exceeded

**Behavior:**
- OTP request rate limit: `429 Too Many Requests` - `{success: false, message: 'Too many OTP requests...'}`
- OTP verify rate limit: `429 Too Many Requests` - `{success: false, message: 'Too many attempts...'}`
- User route rate limit: `429 Too Many Requests` - `{error: 'Too many requests', retry_after: seconds}`
- Admin route rate limit: `429 Too Many Requests` - `{error: 'Too many requests', retry_after: seconds}`

**Headers:**
- `X-RateLimit-Limit`: Maximum requests allowed
- `X-RateLimit-Remaining`: Remaining requests in window
- `X-RateLimit-Reset`: ISO timestamp when limit resets
- `X-RateLimit-Type`: Type of rate limit (read/write/sensitive/admin)

**Files:**
- `src/middleware/rateLimitMiddleware.js` - OTP rate limiting
- `src/middleware/userRateLimit.js` - User route rate limiting
- `src/middleware/adminRateLimit.js` - Admin rate limiting

### 6.5 Retries & Fallbacks

**Redis Fallback:**
- If Redis unavailable: Falls back to in-memory store (per-process, not shared)
- Rate limiting continues to work (with per-instance limits, not global)
- Warning logged on first failure, then silent

**Webhook Alerting:**
- If webhook fails: Retries once after 3 seconds
- If retry fails: Error logged, but main request flow continues (non-blocking)

**Files:**
- `src/services/redisClient.js` - Redis client with graceful fallback
- `src/services/auditLogger.js:334-516` - Webhook alerting with retry

---

## 7. Configuration & Environment Variables

### 7.1 Required Variables

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `DATABASE_URL` | PostgreSQL connection string | `postgres://user:pass@localhost:5432/dbname` | ✅ Yes |
| `JWT_ACCESS_SECRET` | Secret for signing access tokens (min 32 chars) | `hex-string-32-chars-minimum` | ✅ Yes |
| `JWT_REFRESH_SECRET` | Secret for signing refresh tokens (min 32 chars) | `hex-string-32-chars-minimum` | ✅ Yes |

### 7.2 Optional Variables - Timeouts & Expiry

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `JWT_ACCESS_TTL` | Access token expiry | `15m` | `15m`, `1h` |
| `JWT_REFRESH_TTL` | Refresh token expiry | `7d` | `7d`, `30d` |
| `REFRESH_MAX_IDLE_MINUTES` | Refresh token max idle time | `4320` (3 days) | `4320` |
| `OTP_TTL_SECONDS` | OTP validity in seconds | `120` (2 min) | `120` |
| `STEP_UP_OTP_WINDOW_MINUTES` | Step-up auth window | `5` | `5` |

### 7.3 Optional Variables - Rate Limits

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `OTP_REQ_PHONE_10MIN_LIMIT` | Max OTP requests per phone (10 min) | `3` | `3` |
| `OTP_REQ_PHONE_DAY_LIMIT` | Max OTP requests per phone (24h) | `10` | `10` |
| `OTP_REQ_IP_10MIN_LIMIT` | Max OTP requests per IP (10 min) | `20` | `20` |
| `OTP_REQ_IP_DAY_LIMIT` | Max OTP requests per IP (24h) | `100` | `100` |
| `OTP_VERIFY_MAX_ATTEMPTS` | Max OTP verification attempts | `5` | `5` |
| `OTP_VERIFY_FAILED_PER_HOUR_LIMIT` | Max failed verifications per phone (1h) | `10` | `10` |
| `USER_RATE_LIMIT_READ_MAX` | Max read requests per user (15 min) | `100` | `100` |
| `USER_RATE_LIMIT_WRITE_MAX` | Max write requests per user (15 min) | `20` | `20` |
| `USER_RATE_LIMIT_SENSITIVE_MAX` | Max sensitive requests per user (1h) | `10` | `10` |
| `ADMIN_RATE_LIMIT_MAX` | Max admin requests per admin (15 min) | `100` | `100` |

### 7.4 Optional Variables - Security Features

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `ENCRYPTION_ENABLED` | Enable field-level encryption | `false` | `true` |
| `ENCRYPTION_KEY` | 32-byte encryption key (base64) | - | `base64-encoded-32-byte-key` |
| `DB_ACCESS_LOGGING_ENABLED` | Enable database access logging | `false` | `true` |
| `DB_ACCESS_LOG_LEVEL` | DB access log level ('all' or 'sensitive') | `sensitive` | `all`, `sensitive` |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowed origins | - | `https://app.example.com,https://api.example.com` |
| `ENUMERATION_MAX_PHONES_PER_IP_10MIN` | Max unique phones per IP (10 min) | `5` | `5` |
| `ENUMERATION_MAX_PHONES_PER_IP_HOUR` | Max unique phones per IP (1h) | `20` | `20` |
| `ENUMERATION_ALERT_THRESHOLD_10MIN` | Alert threshold for enumeration (10 min) | `10` | `10` |
| `ENUMERATION_ALERT_THRESHOLD_HOUR` | Alert threshold for enumeration (1h) | `50` | `50` |
| `OTP_REQUEST_MIN_DELAY` | Min delay for OTP requests (ms) | `500` | `500` |
| `OTP_VERIFY_MIN_DELAY` | Min delay for OTP verify (ms) | `300` | `300` |
| `TIMING_MAX_JITTER` | Max jitter for timing protection (ms) | `100` | `100` |
| `BLOCKED_IP_RANGES` | Comma-separated CIDR blocks | - | `10.0.0.0/8,172.16.0.0/12` |
| `REQUIRE_OTP_ON_SUSPICIOUS_REFRESH` | Require OTP on suspicious refresh | `false` | `true` |
| `SECURITY_ALERT_WEBHOOK_URL` | Webhook URL for security alerts | - | `https://hooks.slack.com/...` |
| `SECURITY_ALERT_MIN_LEVEL` | Minimum risk level for alerts | `HIGH_RISK` | `SUSPICIOUS`, `HIGH_RISK` |

### 7.5 Optional Variables - JWT Key Rotation

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `JWT_ACTIVE_KEY_ID` | Key ID for signing new tokens | `1` | `1`, `2` |
| `JWT_KEYS_JSON` | JSON mapping key IDs to secrets | - | `{"1":"secret1","2":"secret2"}` |
| `JWT_REFRESH_KEY_ID` | Key ID for refresh tokens | Same as active | `1` |
| `JWT_ISSUER` | JWT issuer claim | `farm-auth-service` | `farm-auth-service` |
| `JWT_AUDIENCE` | JWT audience claim | `mobile-app` | `mobile-app` |

### 7.6 Optional Variables - External Services

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `TWILIO_ACCOUNT_SID` | Twilio account SID | - | `ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| `TWILIO_AUTH_TOKEN` | Twilio auth token | - | `your_auth_token` |
| `TWILIO_MESSAGING_SERVICE_SID` | Twilio messaging service SID | - | `MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| `TWILIO_FROM_NUMBER` | Twilio phone number (E.164) | - | `+1234567890` |
| `REDIS_URL` | Redis connection URL | - | `redis://localhost:6379` |
| `REDIS_HOST` | Redis host | `localhost` | `localhost` |
| `REDIS_PORT` | Redis port | `6379` | `6379` |
| `REDIS_PASSWORD` | Redis password | - | `password` |

### 7.7 Optional Variables - Server Configuration

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PORT` | Server port | `3000` | `3000` |
| `NODE_ENV` | Environment | - | `development`, `production` |
| `TRUST_PROXY` | Trust proxy headers | `false` | `true` |
| `ENABLE_ADMIN_DASHBOARD` | Enable admin routes | `false` | `true` |

---

## 8. Future Improvements / Notes

### 8.1 Planned Improvements (from TODOs in code)

1. **Secrets Manager Integration**
   - Load JWT keys from AWS Secrets Manager / HashiCorp Vault (instead of environment variables)
   - Load encryption keys from secrets manager
   - **File**: `src/services/jwtKeys.js:161-174` (TODO comment)

2. **Automated Key Rotation**
   - Implement automated JWT key rotation without downtime
   - Re-encrypt existing data when encryption keys are rotated
   - **File**: `src/services/jwtKeys.js` (key rotation support exists, but automation needed)

3. **SIEM Integration**
   - Integrate with SIEM systems (Splunk, ELK, etc.) for centralized log aggregation
   - Export audit logs to SIEM for advanced threat detection
   - **File**: `src/services/auditLogger.js` (webhook exists, but SIEM integration needed)

4. **CSP Nonces**
   - Fully implement CSP nonces for inline scripts/styles (currently allows `unsafe-inline` for compatibility)
   - **File**: `src/middleware/securityHeaders.js:28-29` (nonce support exists but not fully utilized)

5. **Database Connection Pooling Tuning**
   - Add configuration for connection pool size, timeout, etc.
   - **File**: `src/db.js` (basic pool, no tuning options)

6. **Rate Limiting Improvements**
   - Implement distributed rate limiting (currently per-instance if Redis unavailable)
   - Add rate limit headers to all rate-limited endpoints
   - **File**: `src/middleware/rateLimitMiddleware.js` (Redis fallback exists, but distributed limiting needed)

7. **OTP Delivery Alternatives**
   - Support multiple SMS providers (fallback if Twilio fails)
   - Support email OTP delivery
   - Support push notification OTP delivery
   - **File**: `src/services/smsService.js` (only Twilio supported)

8. **Advanced Risk Scoring**
   - Machine learning-based risk scoring
   - Geographic anomaly detection (unusual locations)
   - Device fingerprinting improvements
   - **File**: `src/services/riskScoring.js` (basic scoring exists)

### 8.2 Potential Risks & Technical Debt

1. **In-Memory Rate Limiting**
   - If Redis is unavailable, rate limiting uses in-memory store (per-instance, not shared)
   - **Risk**: Rate limits are per-instance, not global (can be bypassed with multiple instances)
   - **Mitigation**: Always use Redis in production, or implement distributed rate limiting

2. **OTP Storage**
   - OTPs are stored in database (not just Redis)
   - **Risk**: Database can become a bottleneck for high-volume OTP requests
   - **Mitigation**: Consider moving OTP storage to Redis entirely (with DB backup for audit)

3. **Phone Number Encryption Migration**
   - Handles both encrypted and plaintext phone numbers (backward compatibility)
   - **Risk**: Plaintext phone numbers still in database if encryption was enabled after data existed
   - **Mitigation**: Implement migration script to encrypt all existing phone numbers

4. **Webhook Alerting**
   - Webhook failures are logged but don't block requests
   - **Risk**: Security alerts might be missed if webhook is down
   - **Mitigation**: Implement alert queue (Redis/RabbitMQ) with retry logic and dead-letter queue

5. **Database Access Logging**
   - Database access logging is optional and can impact performance
   - **Risk**: Performance degradation if enabled in high-traffic scenarios
   - **Mitigation**: Use async logging, batch writes, or separate logging database

6. **JWT Key Rotation**
   - Key rotation support exists, but manual process
   - **Risk**: Manual key rotation can cause downtime if not done correctly
   - **Mitigation**: Implement automated key rotation with gradual rollout

7. **CORS Configuration**
   - CORS validation at startup, but runtime checks are warnings only
   - **Risk**: Misconfiguration might not be caught until runtime
   - **Mitigation**: Add stricter runtime validation or fail-fast on suspicious patterns

8. **Error Messages**
   - Some error messages are generic to prevent information leakage
   - **Risk**: Generic errors can make debugging difficult
   - **Mitigation**: Log detailed errors server-side, return generic errors to clients

---

## Appendix: Database Schema

### Key Tables

**users**
- `id` (UUID, PK)
- `phone_number` (VARCHAR(20), UNIQUE, encrypted if ENCRYPTION_ENABLED)
- `name` (VARCHAR(255))
- `role` (enum: 'user', 'admin', 'moderator')
- `user_type` (enum: 'seller', 'buyer', 'service_provider')
- `token_version` (INT, DEFAULT 1) - Incremented on logout-all-devices to invalidate all access tokens
- `created_at`, `updated_at`, `last_login_at`

**otp_codes**
- `id` (UUID, PK)
- `phone_number` (VARCHAR(20), encrypted if ENCRYPTION_ENABLED)
- `otp_hash` (VARCHAR(255), bcrypt hash)
- `expires_at` (TIMESTAMPTZ)
- `attempt_count` (INT)
- `created_at` (TIMESTAMPTZ)

**refresh_tokens**
- `id` (UUID, PK)
- `user_id` (UUID, FK)
- `token_id` (UUID, UNIQUE)
- `token_hash` (VARCHAR(255), bcrypt hash)
- `device_id` (VARCHAR(255))
- `user_agent` (TEXT)
- `ip_address` (VARCHAR(45))
- `expires_at` (TIMESTAMPTZ)
- `last_used_at` (TIMESTAMPTZ)
- `revoked_at` (TIMESTAMPTZ, NULL = active)
- `reuse_detected_at` (TIMESTAMPTZ)
- `rotated_from_id` (UUID, FK to refresh_tokens)

**user_devices**
- `id` (UUID, PK)
- `user_id` (UUID, FK)
- `device_identifier` (TEXT)
- `device_platform` (TEXT)
- `device_model` (TEXT)
- `os_version` (TEXT)
- `app_version` (TEXT)
- `language_code` (TEXT)
- `timezone` (TEXT)
- `first_seen_at` (TIMESTAMPTZ)
- `last_seen_at` (TIMESTAMPTZ)
- `is_active` (BOOLEAN)
- UNIQUE (user_id, device_identifier)

**auth_audit**
- `id` (UUID, PK)
- `user_id` (UUID, FK, nullable)
- `action` (VARCHAR(100))
- `status` (VARCHAR(50))
- `risk_level` (VARCHAR(20): 'INFO', 'SUSPICIOUS', 'HIGH_RISK')
- `ip_address` (VARCHAR(45))
- `user_agent` (TEXT)
- `device_id` (VARCHAR(255))
- `meta` (JSONB)
- `created_at` (TIMESTAMPTZ)

---

## Document Version

- **Version**: 1.0
- **Last Updated**: 2024
- **Author**: Architecture Documentation Generator
- **Maintained By**: Development Team

