# Farm Auth Service - Quick Start

## Base URL
```
Development: http://localhost:3000
Production: https://your-domain.com
```

## Authentication Flow

```
1. POST /auth/request-otp      → User enters phone number
2. POST /auth/verify-otp       → User enters OTP code → Get tokens
3. Use access_token in header  → Authorization: Bearer <token>
4. POST /auth/refresh          → Get new tokens when expired
5. POST /auth/logout           → Revoke token
```

---

## Endpoints

### 1. Request OTP
```http
POST /auth/request-otp
Content-Type: application/json

{
  "phone_number": "+919876543210"
}
```

**Response:**
```json
{ "ok": true }
```

---

### 2. Verify OTP (Login)
```http
POST /auth/verify-otp
Content-Type: application/json

{
  "phone_number": "+919876543210",
  "code": "123456",
  "device_id": "android-device-id-123",
  "device_info": {
    "platform": "android",
    "model": "Samsung Galaxy",
    "os_version": "Android 14",
    "app_version": "1.0.0"
  }
}
```

**Response:**
```json
{
  "user": {
    "id": "uuid",
    "phone_number": "+919876543210",
    "name": null,
    "role": "user",
    "user_type": null
  },
  "access_token": "eyJhbGc...",
  "refresh_token": "eyJhbGc...",
  "needs_profile": true
}
```

**Store:** `access_token` and `refresh_token` securely (EncryptedSharedPreferences)

---

### 3. Refresh Token
```http
POST /auth/refresh
Content-Type: application/json

{
  "refresh_token": "eyJhbGc..."
}
```

**Response:**
```json
{
  "access_token": "eyJhbGc...",
  "refresh_token": "eyJhbGc..."  ← Always save this new token!
}
```

**Important:** Refresh tokens rotate. Always save the new `refresh_token`.

---

### 4. Update Profile
```http
PUT /users/me
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "name": "John Doe",
  "user_type": "seller"  // or "buyer" or "service_provider"
}
```

**Response:**
```json
{
  "id": "uuid",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "role": "user",
  "user_type": "seller"
}
```

---

### 5. Logout
```http
POST /auth/logout
Content-Type: application/json

{
  "refresh_token": "eyJhbGc..."
}
```

**Response:**
```json
{ "ok": true }
```

---

## Kotlin Data Classes

```kotlin
// Request Models
data class RequestOtpRequest(val phone_number: String)

data class VerifyOtpRequest(
    val phone_number: String,
    val code: String,
    val device_id: String,
    val device_info: DeviceInfo? = null
)

data class DeviceInfo(
    val platform: String = "android",
    val model: String? = null,
    val os_version: String? = null,
    val app_version: String? = null,
    val language_code: String? = null,
    val timezone: String? = null
)

data class RefreshRequest(val refresh_token: String)

data class UpdateProfileRequest(
    val name: String,
    val user_type: String  // "seller" | "buyer" | "service_provider"
)

// Response Models
data class User(
    val id: String,
    val phone_number: String,
    val name: String?,
    val role: String,
    val user_type: String?
)

data class VerifyOtpResponse(
    val user: User,
    val access_token: String,
    val refresh_token: String,
    val needs_profile: Boolean
)

data class RefreshResponse(
    val access_token: String,
    val refresh_token: String
)
```

---

## Example: Kotlin HTTP Client

```kotlin
// Using Retrofit + OkHttp
interface AuthApi {
    @POST("auth/request-otp")
    suspend fun requestOtp(@Body request: RequestOtpRequest): Response<Unit>
    
    @POST("auth/verify-otp")
    suspend fun verifyOtp(@Body request: VerifyOtpRequest): Response<VerifyOtpResponse>
    
    @POST("auth/refresh")
    suspend fun refreshToken(@Body request: RefreshRequest): Response<RefreshResponse>
    
    @PUT("users/me")
    suspend fun updateProfile(
        @Header("Authorization") token: String,
        @Body request: UpdateProfileRequest
    ): Response<User>
    
    @POST("auth/logout")
    suspend fun logout(@Body request: RefreshRequest): Response<Unit>
}

// Usage
val api = Retrofit.Builder()
    .baseUrl("http://your-api-url")
    .addConverterFactory(GsonConverterFactory.create())
    .build()
    .create(AuthApi::class.java)

// Request OTP
api.requestOtp(RequestOtpRequest("+919876543210"))

// Verify OTP
val response = api.verifyOtp(
    VerifyOtpRequest(
        phone_number = "+919876543210",
        code = "123456",
        device_id = getDeviceId(),
        device_info = DeviceInfo(platform = "android")
    )
)
val tokens = response.body() // Save access_token & refresh_token

// Make authenticated request
val user = api.updateProfile(
    "Bearer ${accessToken}",
    UpdateProfileRequest("John", "seller")
)
```

---

## Error Codes

| Code | Error | Solution |
|------|-------|----------|
| 400 | `phone_number is required` | Include phone_number in request |
| 400 | `Invalid or expired OTP` | Re-request OTP (expires in 10 min) |
| 401 | `Invalid refresh token` | Force re-login |
| 401 | `Missing Authorization header` | Include `Authorization: Bearer <token>` |
| 403 | `Origin not allowed` | CORS issue (production) |
| 500 | `Internal server error` | Retry later |

---

## Token Storage (Android)

```kotlin
// Use EncryptedSharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class TokenStorage(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "auth_tokens",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    
    fun saveTokens(access: String, refresh: String) {
        prefs.edit().apply {
            putString("access_token", access)
            putString("refresh_token", refresh)
            apply()
        }
    }
    
    fun getAccessToken() = prefs.getString("access_token", null)
    fun getRefreshToken() = prefs.getString("refresh_token", null)
    fun clear() = prefs.edit().clear().apply()
}
```

---

## Token Expiration

- **Access Token:** 15 minutes (auto-refresh on 401)
- **Refresh Token:** 7 days
- **OTP:** 10 minutes

---

## Phone Number Format

- `9876543210` → Auto-converted to `+919876543210` (10-digit = India)
- `+919876543210` → Used as-is
- Always send in E.164 format: `+<country_code><number>`

---

## Device ID

- Must be 4-128 alphanumeric characters
- Use: Android ID, Installation ID, or Firebase Installation ID
- Invalid formats are auto-hashed

---

## Security Notes

1. ✅ Store tokens in EncryptedSharedPreferences
2. ✅ Auto-refresh access token on 401 errors
3. ✅ Always save new refresh_token after refresh (tokens rotate)
4. ✅ Logout clears tokens and revokes refresh token
5. ⚠️ If refresh returns 401 → Force re-login (token compromised/reused)

---

## Full Example Flow

```kotlin
// 1. Request OTP
api.requestOtp(RequestOtpRequest("+919876543210"))

// 2. Verify OTP & Save Tokens
val loginResponse = api.verifyOtp(...)
tokenStorage.saveTokens(loginResponse.access_token, loginResponse.refresh_token)

// 3. Use Access Token
val user = api.updateProfile("Bearer ${tokenStorage.getAccessToken()}", ...)

// 4. Handle Token Expiration (401) → Refresh
val refreshResponse = api.refreshToken(RefreshRequest(tokenStorage.getRefreshToken()!!))
tokenStorage.saveTokens(refreshResponse.access_token, refreshResponse.refresh_token)

// 5. Logout
api.logout(RefreshRequest(tokenStorage.getRefreshToken()!!))
tokenStorage.clear()
```
