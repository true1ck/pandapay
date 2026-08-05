# Device Management Features

## Overview

The auth service now supports proper multi-device login with device management capabilities. **One phone number = One account**, but that account can be logged in from **multiple devices simultaneously**.

## Key Features

### ✅ Multi-Device Support
- Same phone number can log in from multiple devices
- Each device gets its own refresh token
- Devices can be active simultaneously
- Independent sessions per device

### ✅ Device Tracking
- All login attempts are logged to `auth_audit` table
- New device detection flags (`is_new_device`, `is_new_account`)
- Device metadata tracking (platform, model, OS version, etc.)

### ✅ Device Management
- List all active devices
- Revoke/logout specific devices
- Logout all other devices (keep current)

---

## Updated Endpoints

### 1. Verify OTP (Enhanced Response)

**Endpoint:** `POST /auth/verify-otp`

**Response now includes:**
```json
{
  "user": { ... },
  "access_token": "...",
  "refresh_token": "...",
  "needs_profile": true,
  "is_new_device": false,          // ← NEW: Is this a new device?
  "is_new_account": false,         // ← NEW: Is this a new account?
  "active_devices_count": 2        // ← NEW: How many devices are active?
}
```

**Use Cases:**
- `is_new_device: true` → Show security notification to user
- `is_new_account: true` → Welcome new user flow
- `active_devices_count` → Display in settings/profile

---

### 2. Get User Info

**Endpoint:** `GET /users/me`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "id": "uuid",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "role": "user",
  "user_type": "seller",
  "created_at": "2024-01-01T00:00:00Z",
  "last_login_at": "2024-01-15T10:30:00Z",
  "active_devices_count": 2
}
```

---

### 3. List Active Devices

**Endpoint:** `GET /users/me/devices`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "devices": [
    {
      "device_identifier": "android-device-123",
      "device_platform": "android",
      "device_model": "Samsung Galaxy S21",
      "os_version": "Android 14",
      "app_version": "1.0.0",
      "language_code": "en-IN",
      "timezone": "Asia/Kolkata",
      "first_seen_at": "2024-01-10T08:00:00Z",
      "last_seen_at": "2024-01-15T10:30:00Z",
      "is_active": true
    },
    {
      "device_identifier": "iphone-device-456",
      "device_platform": "ios",
      "device_model": "iPhone 13",
      "os_version": "iOS 17.2",
      "app_version": "1.0.0",
      "language_code": "en-IN",
      "timezone": "Asia/Kolkata",
      "first_seen_at": "2024-01-12T14:20:00Z",
      "last_seen_at": "2024-01-15T09:15:00Z",
      "is_active": true
    }
  ]
}
```

---

### 4. Revoke Specific Device

**Endpoint:** `DELETE /users/me/devices/:device_id`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "ok": true,
  "message": "Device logged out successfully"
}
```

**What it does:**
- Marks device as inactive in `user_devices` table
- Revokes all refresh tokens for that device
- Logs the action in `auth_audit` table

**Kotlin Example:**
```kotlin
suspend fun revokeDevice(deviceId: String, accessToken: String): Result<Unit> {
    val response = apiClient.delete("/users/me/devices/$deviceId") {
        header("Authorization", "Bearer $accessToken")
    }
    return if (response.status.isSuccess()) {
        Result.success(Unit)
    } else {
        Result.failure(Exception("Failed to revoke device"))
    }
}
```

---

### 5. Logout All Other Devices

**Endpoint:** `POST /users/me/logout-all-other-devices`

**Headers:**
```
Authorization: Bearer <access_token>
X-Device-Id: <current_device_id>  // ← Required header
```

**OR Request Body:**
```json
{
  "current_device_id": "android-device-123"
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Logged out 2 device(s)",
  "revoked_devices_count": 2
}
```

**What it does:**
- Keeps current device active
- Logs out all other devices
- Revokes refresh tokens for all other devices

**Kotlin Example:**
```kotlin
suspend fun logoutAllOtherDevices(
    currentDeviceId: String,
    accessToken: String
): Result<LogoutAllResponse> {
    val response = apiClient.post("/users/me/logout-all-other-devices") {
        header("Authorization", "Bearer $accessToken")
        header("X-Device-Id", currentDeviceId)
        contentType(ContentType.Application.Json)
        setBody(JsonObject(mapOf(
            "current_device_id" to JsonPrimitive(currentDeviceId)
        )))
    }
    return Result.success(response.body())
}
```

---

## Authentication Flow Example

### Scenario: User logs in from new phone

1. **Request OTP** (same phone number)
   ```kotlin
   POST /auth/request-otp
   { "phone_number": "+919876543210" }
   ```

2. **Verify OTP** (from new device)
   ```kotlin
   POST /auth/verify-otp
   {
     "phone_number": "+919876543210",
     "code": "123456",
     "device_id": "new-phone-device-id",
     "device_info": { "platform": "android", ... }
   }
   ```

3. **Response:**
   ```json
   {
     "user": { ... },
     "access_token": "...",
     "refresh_token": "...",
     "is_new_device": true,      // ← This is a new device
     "is_new_account": false,    // ← But existing account
     "active_devices_count": 2   // ← Now 2 devices active
   }
   ```

4. **Mobile App Action:**
   - Show notification: "New device logged in: Android Phone"
   - Display in security settings: "Active Devices: 2"
   - Allow user to revoke old device if needed

---

## Security Features

### ✅ New Device Detection
- Automatically detected on login
- Logged in `auth_audit` table
- Flag returned in response for app to show alert

### ✅ Device Activity Tracking
- `last_seen_at` updated on token refresh
- Tracks when device was last active
- Helps identify abandoned/inactive devices

### ✅ Audit Logging
All authentication events logged:
- Login attempts (success/failure)
- Device revocations
- Logout actions
- Token refreshes

Query audit logs:
```sql
SELECT * FROM auth_audit 
WHERE user_id = 'user-uuid' 
ORDER BY created_at DESC;
```

---

## Mobile App Implementation

### Show Active Devices Screen

```kotlin
class DeviceManagementActivity : AppCompatActivity() {
    private val authManager = AuthManager(...)
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        lifecycleScope.launch {
            val devices = authManager.getActiveDevices()
            devices.forEach { device ->
                // Display device info
                // Show "Revoke" button
            }
        }
    }
    
    private fun revokeDevice(deviceId: String) {
        lifecycleScope.launch {
            authManager.revokeDevice(deviceId)
                .onSuccess { 
                    // Refresh device list
                    // Show toast: "Device logged out"
                }
                .onFailure { showError("Failed to revoke device") }
        }
    }
}
```

### Handle New Device Login

```kotlin
private fun handleLoginResponse(response: VerifyOtpResponse) {
    if (response.is_new_device && !response.is_new_account) {
        // Show security alert
        showDialog(
            title = "New Device Detected",
            message = "You've logged in from a new device. " +
                     "If this wasn't you, please change your password.",
            positiveButton = "OK"
        )
    }
    
    // Save tokens
    tokenManager.saveTokens(response.access_token, response.refresh_token)
    
    // Navigate to home/profile
}
```

---

## Database Schema

### user_devices Table
```sql
CREATE TABLE user_devices (
    id                  UUID PRIMARY KEY,
    user_id             UUID NOT NULL REFERENCES users(id),
    device_identifier   TEXT,
    device_platform     TEXT NOT NULL,
    device_model        TEXT,
    os_version          TEXT,
    app_version         TEXT,
    language_code       TEXT,
    timezone            TEXT,
    first_seen_at       TIMESTAMPTZ NOT NULL,
    last_seen_at        TIMESTAMPTZ,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (user_id, device_identifier)
);
```

### auth_audit Table
```sql
CREATE TABLE auth_audit (
    id          UUID PRIMARY KEY,
    user_id     UUID REFERENCES users(id),
    action      VARCHAR(100) NOT NULL,  -- 'login', 'device_revoked', etc.
    status      VARCHAR(50) NOT NULL,   -- 'success', 'failed'
    device_id   VARCHAR(255),
    ip_address  VARCHAR(45),
    user_agent  TEXT,
    meta        JSONB,
    created_at  TIMESTAMPTZ NOT NULL
);
```

---

## Important Notes

1. **Phone Number = Account Ownership**
   - One phone number = One account
   - If someone else uses your phone number, they access your account
   - Always protect your phone number/SIM card

2. **Multiple Devices = Same Account**
   - All devices access the same user account
   - Data is shared across devices
   - Logout on one device doesn't affect others

3. **Device ID Must Be Consistent**
   - Use same `device_id` for same physical device
   - Don't randomly generate new IDs
   - Use Android ID, Installation ID, or Firebase Installation ID

4. **Token Rotation**
   - Refresh tokens rotate on each refresh
   - Always save the new `refresh_token`
   - Old tokens become invalid

5. **Device Revocation**
   - Revoking a device logs it out immediately
   - Refresh tokens for that device are revoked
   - User must re-login on that device

---

## Testing

### Test Multi-Device Login
```bash
# Device 1
curl -X POST http://localhost:3000/auth/verify-otp \
  -H "Content-Type: application/json" \
  -d '{
    "phone_number": "+919876543210",
    "code": "123456",
    "device_id": "device-1"
  }'

# Device 2 (same phone, different device)
curl -X POST http://localhost:3000/auth/verify-otp \
  -H "Content-Type: application/json" \
  -d '{
    "phone_number": "+919876543210",
    "code": "123456",
    "device_id": "device-2"
  }'

# Check active devices
curl -X GET http://localhost:3000/users/me/devices \
  -H "Authorization: Bearer <access_token>"
```

Both devices should be logged in and visible in the devices list.
