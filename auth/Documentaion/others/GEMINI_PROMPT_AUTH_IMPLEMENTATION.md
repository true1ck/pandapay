# Gemini Prompt: Implement JWT Authentication with Refresh Token Rotation

## Context
I have a partially built Android Kotlin application that needs secure JWT authentication with rotating refresh tokens for persistent login. The authentication service is already built and running at `http://localhost:3000`. The app should keep users logged in using secure token storage and automatic token refresh.

---

## Authentication Service Details

**Base URL:** `http://localhost:3000` (development)

**Authentication Flow:**
1. User requests OTP via `POST /auth/request-otp`
2. User verifies OTP via `POST /auth/verify-otp` → receives `access_token` and `refresh_token`
3. Access token (15 min expiry) is used for authenticated API calls
4. Refresh token (7 days expiry) is used to get new tokens when access token expires
5. Refresh tokens rotate on each use (must save new refresh_token)

**Key Endpoints:**

### 1. Request OTP
```
POST /auth/request-otp
Body: { "phone_number": "+919876543210" }
Response: { "ok": true }
```

### 2. Verify OTP (Login)
```
POST /auth/verify-otp
Body: {
  "phone_number": "+919876543210",
  "code": "123456",
  "device_id": "android-installation-id",
  "device_info": {
    "platform": "android",
    "model": "Samsung SM-M326B",
    "os_version": "Android 14",
    "app_version": "1.0.0",
    "language_code": "en-IN",
    "timezone": "Asia/Kolkata"
  }
}
Response: {
  "user": { "id": "...", "phone_number": "...", "name": null, ... },
  "access_token": "eyJhbGc...",
  "refresh_token": "eyJhbGc...",
  "needs_profile": true,
  "is_new_device": true,
  "is_new_account": false
}
```

### 3. Refresh Token (Get New Tokens)
```
POST /auth/refresh
Body: { "refresh_token": "eyJhbGc..." }
Response: {
  "access_token": "eyJhbGc...",
  "refresh_token": "eyJhbGc..."  // NEW token - MUST save this
}
```

### 4. Get User Details (Authenticated)
```
GET /users/me
Headers: Authorization: Bearer <access_token>
Response: {
  "id": "...",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "user_type": "seller",
  "last_login_at": "2024-01-20T14:22:00Z",
  "location": { ... },
  "locations": [ ... ],
  "active_devices_count": 2
}
```

### 5. Logout
```
POST /auth/logout
Body: { "refresh_token": "eyJhbGc..." }
Response: { "ok": true }
```

---

## Implementation Requirements

### 1. Secure Token Storage

**Use EncryptedSharedPreferences (Android Security Library):**
- Store `access_token` and `refresh_token` securely
- Never use plain SharedPreferences
- Never log tokens in console/logs
- Clear tokens on logout or app uninstall

**Implementation:**
```kotlin
// Use androidx.security:security-crypto:1.1.0-alpha06
// Store tokens using EncryptedSharedPreferences with MasterKey
```

### 2. Token Management

**Access Token:**
- Lifetime: 15 minutes
- Used in `Authorization: Bearer <token>` header for all authenticated requests
- Automatically refreshed when expired (401 response)

**Refresh Token:**
- Lifetime: 7 days (configurable)
- Idle timeout: 3 days (if unused for 3 days, becomes invalid)
- **ROTATES on each refresh** - always save the new refresh_token
- Stored securely, never sent in URLs or logs

**Token Refresh Flow:**
```
1. API call returns 401 (Unauthorized)
2. Get refresh_token from secure storage
3. Call POST /auth/refresh with refresh_token
4. Receive new access_token and new refresh_token
5. Save BOTH new tokens securely
6. Retry original API call with new access_token
7. If refresh fails → clear tokens → redirect to login
```

### 3. Auto-Refresh Interceptor/Plugin

**Implement automatic token refresh:**
- Intercept all API requests
- Add `Authorization: Bearer <access_token>` header automatically
- On 401 response:
  - Refresh token automatically
  - Retry original request
  - If refresh fails, clear tokens and redirect to login

**Use either:**
- Ktor: HTTP client interceptor/plugin
- Retrofit: OkHttp interceptor

### 4. Success Page Implementation

**After successful login (OTP verification), show a Success/Home screen that:**

1. **Fetches User Details:**
   - Call `GET /users/me` with access_token
   - Display: name, phone_number, user_type, last_login_at
   - Display location if available (city, state, pincode)
   - Handle loading and error states

2. **Persistent Login:**
   - Check for stored tokens on app launch
   - If tokens exist and valid → auto-login user
   - If tokens expired → attempt refresh
   - If refresh fails → show login screen

3. **Logout Button:**
   - Clear all tokens from secure storage
   - Call `POST /auth/logout` with refresh_token
   - Navigate back to login screen
   - Show confirmation dialog before logout

### 5. Security Requirements

**Critical Security Rules:**
1. ✅ Store tokens only in `EncryptedSharedPreferences`
2. ✅ Never log tokens or sensitive data
3. ✅ Always use HTTPS in production (http://localhost only for dev)
4. ✅ Implement certificate pinning for production
5. ✅ Handle token reuse detection (if refresh returns 401, force re-login)
6. ✅ Clear tokens on logout, app uninstall, or security breach
7. ✅ Validate device_id consistently (use Android ID or Installation ID)
8. ✅ Handle network errors gracefully without exposing tokens

### 6. Error Handling

**Handle these scenarios:**
- **401 Unauthorized** → Refresh token → Retry
- **401 on refresh** → Clear tokens → Redirect to login (session expired)
- **Network errors** → Show user-friendly message, retry option
- **Invalid OTP** → Show error, allow retry
- **Token expired** → Auto-refresh silently (user shouldn't notice)
- **Refresh token expired** → Show "Session expired, please login again"

### 7. Device Information

**Send device info during login:**
- Use Android ID or Firebase Installation ID for `device_id`
- Collect: platform, model, OS version, app version, language, timezone
- Send in `device_info` object during OTP verification

---

## Code Structure Requirements

### Data Models (Kotlinx Serialization)
```kotlin
@Serializable
data class User(...)
@Serializable  
data class VerifyOtpResponse(...)
@Serializable
data class RefreshResponse(...)
// Include all necessary models with @SerialName for snake_case JSON
```

### Token Manager
```kotlin
class TokenManager(context: Context) {
    fun saveTokens(accessToken: String, refreshToken: String)
    fun getAccessToken(): String?
    fun getRefreshToken(): String?
    fun clearTokens()
}
```

### API Client with Auto-Refresh
```kotlin
class AuthApiClient {
    // Automatically adds Authorization header
    // Automatically refreshes token on 401
    // Handles token rotation
}
```

### ViewModel Pattern
```kotlin
class SuccessViewModel : ViewModel() {
    // Fetch user details
    // Handle logout
    // Observe authentication state
}
```

---

## User Experience Flow

1. **App Launch:**
   - Check for stored tokens
   - If valid → navigate to Success/Home screen
   - If invalid/expired → show Login screen

2. **Login Screen:**
   - Enter phone number → Request OTP
   - Enter OTP code → Verify OTP
   - On success → Save tokens → Navigate to Success screen

3. **Success/Home Screen:**
   - Show loading indicator
   - Fetch user details from `/users/me`
   - Display: Name, Phone, Profile Type, Location, Last Login
   - Show logout button
   - Handle token refresh silently if needed

4. **Logout:**
   - Show confirmation dialog
   - Call logout API
   - Clear tokens
   - Navigate to Login screen

---

## Dependencies Required

```kotlin
// HTTP Client
implementation("io.ktor:ktor-client-android:2.3.5")
implementation("io.ktor:ktor-client-content-negotiation:2.3.5")
implementation("io.ktor:ktor-serialization-kotlinx-json:2.3.5")

// Secure Storage
implementation("androidx.security:security-crypto:1.1.0-alpha06")

// Serialization
implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")

// Coroutines
implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

// ViewModel
implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.2")
```

---

## Testing Checklist

- [ ] Login with OTP and receive tokens
- [ ] Tokens stored securely in EncryptedSharedPreferences
- [ ] Success page displays user details from `/users/me`
- [ ] Access token auto-refreshes when expired (wait 15+ min)
- [ ] Refresh token rotates correctly (save new token)
- [ ] Logout clears tokens and navigates to login
- [ ] App remembers login after restart (if tokens valid)
- [ ] Session expires gracefully after 3 days idle
- [ ] Network errors handled gracefully
- [ ] No tokens logged in console/logs

---

## Specific Implementation Notes

1. **Phone Number Format:**
   - Accept user input (can be 10 digits or with +91)
   - Server auto-normalizes: `9876543210` → `+919876543210`
   - Always send in E.164 format

2. **Device ID:**
   - Use consistent identifier: Android ID or Firebase Installation ID
   - Must be 4-128 alphanumeric characters
   - Server sanitizes invalid IDs

3. **Token Rotation:**
   - **CRITICAL:** After refresh, the new `refresh_token` replaces the old one
   - Old refresh_token becomes invalid immediately
   - Always save the new refresh_token from refresh response

4. **Base URL Configuration:**
   - Development: `http://localhost:3000`
   - Production: Use environment-based configuration
   - Consider using BuildConfig for different environments

5. **API Response Handling:**
   - All error responses: `{ "error": "message" }`
   - Success responses vary by endpoint
   - Always check HTTP status code before parsing JSON

---

## Security Validation Checklist

Before considering the implementation complete, verify:

- ✅ No tokens in logs/console
- ✅ Tokens only in EncryptedSharedPreferences
- ✅ Automatic token refresh works
- ✅ Token rotation handled correctly
- ✅ Tokens cleared on logout
- ✅ Session expiry handled
- ✅ Network errors don't expose tokens
- ✅ HTTPS for production (when deployed)

---

## Expected Behavior

**On Successful Login:**
1. Save `access_token` and `refresh_token` securely
2. Navigate to Success/Home screen
3. Automatically fetch user details from `/users/me`
4. Display user information
5. Show logout button

**On App Restart (with valid tokens):**
1. Check stored tokens
2. Validate token (or refresh if expired)
3. Auto-navigate to Success/Home screen
4. Fetch and display user details

**On Token Expiration:**
1. Next API call returns 401
2. Automatically refresh token (silently)
3. Retry API call with new token
4. User experience uninterrupted

**On Refresh Token Expiration:**
1. Refresh attempt fails with 401
2. Clear all tokens
3. Show "Session expired" message
4. Navigate to login screen

**On Logout:**
1. Show confirmation dialog
2. Call logout API
3. Clear all tokens from storage
4. Navigate to login screen

---

## Reference Documentation

The complete API documentation and data models are available in:
- `how_to_use_Auth.md` (in your Android project)
- Full API reference with request/response examples
- All data models with Kotlinx Serialization annotations

---

## Deliverables

Please implement:

1. **TokenManager** - Secure token storage using EncryptedSharedPreferences
2. **AuthApiClient** - API client with automatic token refresh and rotation
3. **Success/Home Screen** - Displays user details from `/users/me`
4. **Logout functionality** - With confirmation and proper cleanup
5. **Auto-login on app launch** - Check tokens and auto-login if valid
6. **Error handling** - Graceful handling of all error scenarios
7. **Loading states** - Show loading indicators during API calls

**Code Quality:**
- Use Kotlin best practices
- Follow MVVM architecture pattern
- Use Kotlin Coroutines for async operations
- Proper error handling with Result type
- Clean, maintainable, and secure code

**Security:**
- All tokens encrypted at rest
- No tokens in logs
- Proper token rotation
- Secure network communication

---

This implementation should provide a secure, production-ready authentication system with persistent login capability. The user should be able to login once and remain logged in (until tokens expire or logout) with seamless token refresh happening automatically in the background.










