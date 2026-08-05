# Rate Limiting & OTP Throttling Implementation

## Overview

This document explains the secure rate limiting and OTP throttling implementation added to the authentication service.

## Architecture

### Components Added

1. **Redis Client** (`src/services/redisClient.js`)
   - Manages Redis connection with graceful fallback to in-memory storage
   - Supports `REDIS_URL` or `REDIS_HOST`/`REDIS_PORT` configuration

2. **Rate Limiting Middleware** (`src/middleware/rateLimitMiddleware.js`)
   - Per-phone rate limiting for OTP requests
   - Per-IP rate limiting for OTP requests
   - Active OTP checking (2-minute no-resend rule)
   - Failed verification attempt tracking

3. **Updated OTP Service** (`src/services/otpService.js`)
   - Changed OTP expiry from 10 minutes to 2 minutes (120 seconds)
   - Enhanced attempt tracking with generic error responses

4. **Updated Auth Routes** (`src/routes/authRoutes.js`)
   - Integrated all rate limiting middleware
   - Updated error responses to be generic

## Rate Limiting Rules

### POST /auth/request-otp

**Per Phone Number:**
- Max 3 requests per 10 minutes
- Max 10 requests per 24 hours
- **No resend if active OTP exists** (within 2 minutes of generation)

**Per IP Address:**
- Max 20 requests per 10 minutes
- Max 100 requests per 24 hours

**Response on Limit Exceeded:**
```json
{
  "success": false,
  "message": "Too many OTP requests. Please try again later."
}
```
HTTP Status: `429 Too Many Requests`

**Response if Active OTP Exists:**
```json
{
  "success": false,
  "message": "An OTP is already active. Please wait a moment before requesting a new one."
}
```
HTTP Status: `429 Too Many Requests`

### POST /auth/verify-otp

**Per OTP:**
- Max 5 verification attempts per OTP
- After 5 failed attempts, OTP is invalidated

**Per Phone Number:**
- Max 10 failed verifications per hour
- If exceeded, all verification attempts are blocked temporarily

**Response on Failure:**
```json
{
  "success": false,
  "message": "OTP invalid or expired. Please request a new one."
}
```
HTTP Status: `400 Bad Request`

**Response on Too Many Failed Attempts:**
```json
{
  "success": false,
  "message": "Too many attempts. Please try again later."
}
```
HTTP Status: `429 Too Many Requests`

## OTP Validity

- **OTP expires after 2 minutes (120 seconds)** from generation
- **No new OTP can be sent** to the same phone number while an active OTP exists
- Once verified successfully, OTP is immediately deleted

## Redis Setup

### Configuration

The system uses Redis for rate limiting counters with automatic TTL expiration. If Redis is not available, it falls back to in-memory storage.

**Environment Variables:**

```bash
# Option 1: Full Redis URL
REDIS_URL=redis://localhost:6379
# or with password
REDIS_URL=redis://:password@localhost:6379

# Option 2: Separate host/port
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=your_password  # Optional
```

### Redis Keys Used

- `otp_req:phone:{phone}:10min` - Phone requests (10 min window)
- `otp_req:phone:{phone}:day` - Phone requests (24 hour window)
- `otp_req:ip:{ip}:10min` - IP requests (10 min window)
- `otp_req:ip:{ip}:day` - IP requests (24 hour window)
- `otp_active:phone:{phone}` - Active OTP marker (2 min TTL)
- `otp_verify_failed:phone:{phone}:hour` - Failed verifications (1 hour window)

All keys automatically expire based on their TTL.

## Configuration

All limits are configurable via environment variables:

```bash
# OTP Request Limits
OTP_REQ_PHONE_10MIN_LIMIT=3        # Default: 3
OTP_REQ_PHONE_DAY_LIMIT=10        # Default: 10
OTP_REQ_IP_10MIN_LIMIT=20          # Default: 20
OTP_REQ_IP_DAY_LIMIT=100           # Default: 100

# OTP Verification Limits
OTP_VERIFY_MAX_ATTEMPTS=5          # Default: 5
OTP_VERIFY_FAILED_PER_HOUR_LIMIT=10 # Default: 10

# OTP Validity
OTP_TTL_SECONDS=120                # Default: 120 (2 minutes)

# Proxy Support (for correct IP detection)
TRUST_PROXY=true                    # Set if behind reverse proxy
```

## Implementation Details

### Redis Client Initialization

The Redis client is initialized in `src/index.js`:

```javascript
const { initRedis } = require('./services/redisClient');
initRedis().catch((err) => {
  console.warn('Redis initialization warning:', err.message);
});
```

If Redis is unavailable, the system logs a warning and continues with in-memory fallback.

### Rate Limiting Logic

1. **Request Flow for `/auth/request-otp`:**
   ```
   Request → checkActiveOtpForPhone → rateLimitRequestOtpByPhone → rateLimitRequestOtpByIp → createOtp
   ```

2. **Request Flow for `/auth/verify-otp`:**
   ```
   Request → rateLimitVerifyOtpByPhone → verifyOtp → (on failure) incrementFailedVerify
   ```

### Memory Store Fallback

When Redis is not available, the system uses an in-memory store that:
- Maintains counters with expiration timestamps
- Automatically cleans up expired entries every minute
- Works identically to Redis for rate limiting purposes
- **Note:** In-memory store is per-process and doesn't persist across restarts

### Error Handling

All rate limiting middleware uses a "fail open" strategy:
- If Redis errors occur, the request is allowed to proceed
- Errors are logged but don't block legitimate users
- This ensures availability even if rate limiting infrastructure fails

## Security Features

1. **Generic Error Messages:** All error responses use generic messages to avoid information leakage
2. **No Information Leakage:** Errors don't distinguish between "wrong OTP", "expired OTP", or "max attempts"
3. **Automatic Cleanup:** Expired OTPs and rate limit counters are automatically cleaned up
4. **IP-based Protection:** Prevents abuse from single IP addresses
5. **Phone-based Protection:** Prevents abuse targeting specific phone numbers

## Testing

To test the rate limiting:

1. **Test Active OTP Rule:**
   ```bash
   # Request OTP
   curl -X POST http://localhost:3000/auth/request-otp \
     -H "Content-Type: application/json" \
     -d '{"phone_number": "+1234567890"}'
   
   # Immediately try again (should be blocked)
   curl -X POST http://localhost:3000/auth/request-otp \
     -H "Content-Type: application/json" \
     -d '{"phone_number": "+1234567890"}'
   ```

2. **Test Rate Limits:**
   ```bash
   # Send multiple requests quickly (should hit limit after 3)
   for i in {1..5}; do
     curl -X POST http://localhost:3000/auth/request-otp \
       -H "Content-Type: application/json" \
       -d '{"phone_number": "+1234567890"}'
     sleep 1
   done
   ```

## Dependencies

Added to `package.json`:
- `redis`: ^4.7.0

Install with:
```bash
npm install
```

## Notes

- The system gracefully degrades if Redis is unavailable
- All rate limits are enforced independently (phone and IP limits both apply)
- OTP expiry time changed from 10 minutes to 2 minutes
- SMS message updated to reflect 2-minute expiry
- Existing JWT and user creation logic remains unchanged







