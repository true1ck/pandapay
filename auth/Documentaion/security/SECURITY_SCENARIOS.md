# Phone Number & Device Management - Security Scenarios

## Current System Behavior

### Scenario 1: Two Different Users with Same Phone Number

**Current Behavior:**
- ❌ **SECURITY ISSUE**: Both users will access the **SAME account**
- The system uses "find or create" logic:
  - If phone number exists → Logs into existing account
  - If phone number doesn't exist → Creates new account
- The second person can:
  - See the first person's data
  - Modify the first person's profile
  - Access their listings/transactions
  - Change their account settings

**Why this happens:**
```javascript
// src/routes/authRoutes.js (lines 88-107)
// find or create user
const found = await db.query(`SELECT ... FROM users WHERE phone_number = $1`, [phone]);
if (found.rows.length === 0) {
  // Create new user
} else {
  user = found.rows[0];  // ← Uses existing account!
}
```

**Database Constraint:**
- `phone_number` has UNIQUE constraint (one account per phone number)

---

### Scenario 2: Same User, Different Device

**Current Behavior:**
- ✅ **Works correctly**: Same user can log in from multiple devices
- Each device gets:
  - Its own refresh token (tracked by `device_id`)
  - Separate device record in `user_devices` table
  - Independent session
- All devices can be logged in **simultaneously**
- Each device's tokens work independently

**How it works:**
```javascript
// Device tracking (lines 117-142)
INSERT INTO user_devices (user_id, device_identifier, ...)
VALUES ($1, $2, ...)
ON CONFLICT (user_id, device_identifier)
DO UPDATE SET last_seen_at = NOW(), ...
```

**Database Constraint:**
- `UNIQUE (user_id, device_identifier)` → Same device can't be registered twice for same user

**Example:**
1. User logs in on Phone A → Gets tokens, device_id = "phone-a"
2. User logs in on Phone B → Gets different tokens, device_id = "phone-b"
3. Both devices active simultaneously
4. Logout on Phone A → Only revokes tokens for device_id = "phone-a"
5. Phone B continues working

---

## Security Risks

### Risk 1: Phone Number Hijacking

**Problem:**
- If someone gets access to your phone number (SIM swap, lost phone), they can log into your account
- They receive the OTP and gain full account access

**Mitigation (Recommended):**
1. Add additional verification (email, recovery questions)
2. Implement device fingerprinting
3. Alert user on new device login
4. Allow user to see all active devices and revoke them

### Risk 2: Shared Phone Numbers

**Problem:**
- Family members sharing a phone
- Business phone used by multiple employees
- Second-hand phone numbers

**Current Impact:**
- Account confusion
- Data privacy violations
- Unauthorized access

---

## Recommended Solutions

### Solution 1: Warn User on First Login from New Device

**Implementation:**
```javascript
// In verify-otp endpoint
const existingDevices = await db.query(
  `SELECT COUNT(*) FROM user_devices WHERE user_id = $1`,
  [user.id]
);

if (existingDevices.rows[0].count > 0) {
  // This is a new device for existing account
  // Could send notification to all other devices
  // Or require additional verification
}
```

### Solution 2: Multi-Factor Authentication (MFA)

**Add options:**
- Email verification for new device
- SMS backup codes
- Recovery questions
- Authenticator app

### Solution 3: Account Ownership Verification

**Before creating account:**
```javascript
// Check if phone number recently used
const recentLogins = await db.query(
  `SELECT user_id, last_login_at 
   FROM users 
   WHERE phone_number = $1 
   AND last_login_at > NOW() - INTERVAL '7 days'`,
  [phoneNumber]
);

if (recentLogins.rows.length > 0) {
  // Require additional verification or block
}
```

### Solution 4: Device Management Endpoint

**Add API endpoints:**
```javascript
// GET /users/me/devices - List all active devices
// DELETE /users/me/devices/:device_id - Revoke specific device
// POST /users/me/devices/:device_id/verify - Verify device ownership
```

### Solution 5: Session Limits

**Limit concurrent sessions:**
```javascript
// Enforce maximum devices per user
const MAX_DEVICES = 5;
const deviceCount = await db.query(
  `SELECT COUNT(*) FROM user_devices WHERE user_id = $1 AND is_active = true`,
  [user.id]
);

if (deviceCount >= MAX_DEVICES) {
  // Revoke oldest device or require user to choose which to revoke
}
```

---

## Immediate Actions Needed

### 1. Document Current Behavior
- Update API documentation
- Warn developers about phone number uniqueness
- Add to user terms of service

### 2. Add Logging
```javascript
// Log all login attempts
await db.query(
  `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address)
   VALUES ($1, 'login', 'success', $2, $3)`,
  [user.id, devId, req.ip]
);
```

### 3. Add User Notifications
- Email/SMS alert when login from new device
- Show active devices in user profile
- Allow device revocation

### 4. Consider Account Recovery Flow
- Allow users to dispute account ownership
- Support team can transfer ownership
- Require additional verification for sensitive actions

---

## Testing Scenarios

### Test Case 1: Same Phone, Different Users
```
1. User A requests OTP for +919876543210
2. User A verifies OTP → Account created
3. User B requests OTP for +919876543210
4. User B verifies OTP → Logs into User A's account ❌
```

### Test Case 2: Same User, Multiple Devices
```
1. User logs in on Device A → Gets tokens
2. User logs in on Device B → Gets different tokens
3. Both tokens work simultaneously ✅
4. User logs out on Device A → Device B still works ✅
```

### Test Case 3: Device Re-login
```
1. User logs in on Device A
2. User logs out
3. User logs in again on Device A → New tokens issued ✅
```

---

## Best Practices for Mobile App

### 1. Inform Users
```kotlin
// Show warning in app
if (response.needs_profile && existingAccount) {
    showDialog("This phone number is already registered. 
                You will be logged into the existing account.")
}
```

### 2. Show Active Devices
```kotlin
// Display all logged-in devices
GET /users/me/devices → List devices with last_seen_at
```

### 3. Allow Device Management
```kotlin
// Let users revoke devices
DELETE /users/me/devices/{device_id}
```

### 4. Handle Token Revocation
```kotlin
// If refresh returns 401, check if device was revoked
if (error.code == 401) {
    checkActiveDevices()
    if (currentDeviceRevoked) {
        forceReLogin()
    }
}
```

---

## Database Queries for Analysis

### Check accounts by phone
```sql
SELECT phone_number, COUNT(*) as account_count
FROM users
GROUP BY phone_number
HAVING COUNT(*) > 1;
-- Should return 0 rows (UNIQUE constraint)
```

### Check devices per user
```sql
SELECT u.phone_number, COUNT(ud.id) as device_count
FROM users u
LEFT JOIN user_devices ud ON u.id = ud.user_id
WHERE ud.is_active = true
GROUP BY u.id, u.phone_number
ORDER BY device_count DESC;
```

### Check concurrent sessions
```sql
SELECT u.phone_number, ud.device_identifier, ud.last_seen_at
FROM users u
JOIN user_devices ud ON u.id = ud.user_id
WHERE ud.is_active = true
AND ud.last_seen_at > NOW() - INTERVAL '1 hour'
ORDER BY ud.last_seen_at DESC;
```

---

## Summary

| Scenario | Current Behavior | Risk Level | Action Needed |
|----------|-----------------|------------|---------------|
| Same phone, different users | Share same account | 🔴 HIGH | Add verification/alert |
| Same user, different devices | Multiple active sessions | 🟢 LOW | Add device management UI |
| Same device, multiple logins | Works (token refresh) | 🟢 LOW | None |
| Phone number hijacking | Full account access | 🔴 HIGH | Add MFA, alerts |
