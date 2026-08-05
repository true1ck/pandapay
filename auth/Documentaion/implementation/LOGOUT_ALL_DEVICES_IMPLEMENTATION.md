# Logout from All Devices - Implementation Summary

## Overview

This document describes the implementation of the "Logout from All Devices" feature, which allows users to immediately invalidate all access and refresh tokens across all devices when a security breach or account compromise is suspected.

## Implementation Details

### 1. Database Schema Changes

**Added Column to `users` table:**
- `token_version` (INT, NOT NULL, DEFAULT 1)
  - Incremented on logout-all-devices to invalidate all existing access tokens
  - Validated on each access token verification

**Migration Required:**
For existing databases, run:
```sql
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INT NOT NULL DEFAULT 1;
```

### 2. Token Service Updates

**File: `src/services/tokenService.js`**

- **Updated `signAccessToken()`**: Now includes `token_version` claim in JWT payload
- **Added `revokeAllUserTokens(userId)`**: 
  - Revokes all refresh tokens for the user
  - Marks all devices as inactive
  - Increments user's `token_version` to invalidate all access tokens

### 3. Authentication Middleware Updates

**File: `src/middleware/authMiddleware.js`**

- **Made middleware async**: Required for database query
- **Added token version validation**: 
  - Queries user's current `token_version` from database
  - Compares with `token_version` claim in access token
  - Rejects token if versions don't match (token has been invalidated)

### 4. New API Endpoint

**Endpoint: `POST /users/me/logout-all-devices`**

**Security Requirements:**
- Requires authentication (access token)
- Requires step-up authentication (recent OTP or `high_assurance` token)
- Rate limited: 10 requests per hour per user

**Functionality:**
1. Revokes all refresh tokens for the user
2. Marks all devices as inactive
3. Increments user's `token_version` (invalidates all access tokens)
4. Logs HIGH_RISK security event (triggers security alert webhook)

**Response:**
```json
{
  "ok": true,
  "message": "Logged out from all devices successfully",
  "revoked_tokens_count": 5
}
```

### 5. Audit Logging

**Event Type:** `logout_all_devices`
**Risk Level:** `HIGH_RISK`
**Status:** `success`

**Metadata:**
- `revoked_tokens_count`: Number of refresh tokens revoked
- `new_token_version`: New token version after increment
- `reason`: "user_initiated_global_logout"
- `message`: "User initiated logout from all devices - security breach suspected"

**Alerting:** This event triggers security alert webhook (if configured) due to HIGH_RISK level.

## How It Works

### Access Token Invalidation

1. **Token Issuance**: When an access token is issued, it includes the user's current `token_version` in the JWT payload.

2. **Token Validation**: On each authenticated request:
   - `authMiddleware` extracts `token_version` from the JWT payload
   - Queries the user's current `token_version` from the database
   - Compares versions - if they don't match, the token is rejected

3. **Global Logout**: When user calls `/users/me/logout-all-devices`:
   - All refresh tokens are revoked (marked with `revoked_at`)
   - All devices are marked as inactive
   - User's `token_version` is incremented
   - All existing access tokens (even if not expired) become invalid immediately

### Refresh Token Invalidation

Refresh tokens are stored in the database and can be directly revoked by setting `revoked_at`. The `revokeAllUserTokens()` function revokes all refresh tokens for a user.

## Security Considerations

1. **Step-Up Authentication Required**: Users must provide recent OTP verification or have a `high_assurance` token to perform this action.

2. **Rate Limiting**: Limited to 10 requests per hour per user to prevent abuse.

3. **HIGH_RISK Logging**: All logout-all-devices events are logged with HIGH_RISK level and trigger security alerts.

4. **Immediate Invalidation**: Access tokens are invalidated immediately via token versioning, not just on expiry.

5. **Database Query Overhead**: Token version validation requires a database query on each authenticated request. This is acceptable for security-critical operations.

## Testing

### Manual Testing

1. **Login and get tokens:**
   ```bash
   POST /auth/verify-otp
   # Save access_token and refresh_token
   ```

2. **Verify token works:**
   ```bash
   GET /users/me
   Authorization: Bearer <access_token>
   # Should return 200 OK
   ```

3. **Logout from all devices:**
   ```bash
   POST /users/me/logout-all-devices
   Authorization: Bearer <access_token>
   # Requires step-up auth (recent OTP or high_assurance token)
   ```

4. **Verify old token is invalid:**
   ```bash
   GET /users/me
   Authorization: Bearer <old_access_token>
   # Should return 401 Unauthorized
   ```

5. **Verify refresh token is invalid:**
   ```bash
   POST /auth/refresh
   { "refresh_token": "<old_refresh_token>" }
   # Should return 401 Unauthorized
   ```

## API Integration

### Request

```http
POST /users/me/logout-all-devices
Authorization: Bearer <access_token>
```

**Note:** The access token must have `high_assurance: true` or the user must have verified OTP within the last 5 minutes.

### Response

**Success (200 OK):**
```json
{
  "ok": true,
  "message": "Logged out from all devices successfully",
  "revoked_tokens_count": 5
}
```

**Error (403 Forbidden - Step-up required):**
```json
{
  "error": "step_up_required",
  "message": "This action requires additional verification. Please verify your OTP first.",
  "requires_otp": true
}
```

**Error (429 Too Many Requests):**
```json
{
  "error": "Too many requests",
  "retry_after": 3600
}
```

## Files Modified

1. `db/farmmarket-db/init.sql` - Added `token_version` column to users table
2. `src/services/tokenService.js` - Added token versioning and `revokeAllUserTokens()` function
3. `src/middleware/authMiddleware.js` - Added token version validation
4. `src/routes/authRoutes.js` - Updated user queries to include `token_version`
5. `src/routes/userRoutes.js` - Added `/users/me/logout-all-devices` endpoint
6. `docs/ARCHITECTURE.md` - Updated documentation with new flow

## Future Improvements

1. **Caching**: Consider caching user's `token_version` in Redis to reduce database queries (with TTL matching access token expiry).

2. **Metrics**: Add metrics for logout-all-devices events to track security incidents.

3. **Notification**: Optionally notify user via email/SMS when logout-all-devices is triggered.

4. **Admin Override**: Allow admins to trigger logout-all-devices for a user (with proper audit logging).



