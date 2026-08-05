# Farm Auth Service - API Integration Guide

Complete integration guide for Farm Auth Service with Kotlin Multiplatform Mobile (KMM) or Kotlin Native applications.

## Base URL

```
http://localhost:3000  (development)
https://your-domain.com (production)
```

## Table of Contents

- [Authentication Flow](#authentication-flow)
- [API Endpoints](#api-endpoints)
- [Kotlin Multiplatform Implementation](#kotlin-multiplatform-implementation)
- [Error Handling](#error-handling)
- [Security Best Practices](#security-best-practices)
- [Token Management](#token-management)

---

## Authentication Flow

1. **Request OTP** → User enters phone number
2. **Verify OTP** → User enters code, receives tokens + user info
3. **Use Access Token** → Include in `Authorization` header for protected endpoints
4. **Refresh Token** → When access token expires, get new tokens (auto-rotation)
5. **Logout** → Revoke refresh token on current device
6. **Device Management** → View/manage active devices

---

## API Endpoints

### 1. Request OTP

**Endpoint:** `POST /auth/request-otp`

**Request:**
```json
{
  "phone_number": "+919876543210"
}
```

**Response (200):**
```json
{
  "ok": true
}
```

**Error (400):**
```json
{
  "error": "phone_number is required"
}
```

**Error (500):**
```json
{
  "error": "Failed to send OTP"
}
```

**Phone Number Normalization:**
- `9876543210` → Automatically becomes `+919876543210` (10-digit assumed as Indian)
- `+919876543210` → Kept as is
- Phone numbers should ideally be in E.164 format with `+` prefix

---

### 2. Verify OTP

**Endpoint:** `POST /auth/verify-otp`

**Request:**
```json
{
  "phone_number": "+919876543210",
  "code": "123456",
  "device_id": "android-installation-id-123",
  "device_info": {
    "platform": "android",
    "model": "Samsung SM-M326B",
    "os_version": "Android 14",
    "app_version": "1.0.0",
    "language_code": "en-IN",
    "timezone": "Asia/Kolkata"
  }
}
```

**Response (200):**
```json
{
  "user": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "phone_number": "+919876543210",
    "name": null,
    "role": "user",
    "user_type": null
  },
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "needs_profile": true,
  "is_new_device": true,
  "is_new_account": false,
  "active_devices_count": 2
}
```

**Error (400):**
```json
{
  "error": "phone_number and code are required"
}
```
or
```json
{
  "error": "Invalid or expired OTP"
}
```

**Notes:**
- `device_id` is required and will be sanitized (must be 4-128 alphanumeric characters, otherwise hashed)
- `device_info` is optional but recommended for better device tracking
- `needs_profile` is `true` if `name` or `user_type` is null
- `is_new_device` indicates if this device was seen for the first time
- `is_new_account` indicates if the user account was just created
- `active_devices_count` shows how many active devices the user has

---

### 3. Refresh Token

**Endpoint:** `POST /auth/refresh`

**Request:**
```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

**Response (200):**
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

**Error (400):**
```json
{
  "error": "refresh_token is required"
}
```

**Error (401):**
```json
{
  "error": "Invalid refresh token"
}
```

**Important:** 
- Refresh tokens **rotate on each use** - always save the new `refresh_token`
- Old refresh token is automatically revoked
- If refresh token is compromised and reused, all tokens for that device are revoked

---

### 4. Logout

**Endpoint:** `POST /auth/logout`

**Request:**
```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

**Response (200):**
```json
{
  "ok": true
}
```

**Note:** Returns `ok: true` even if token is already invalid (idempotent)

---

### 5. Get Current User Profile

**Endpoint:** `GET /users/me`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response (200):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "role": "user",
  "user_type": "seller",
  "avatar_url": "https://example.com/avatar.jpg",
  "language": "en",
  "timezone": "Asia/Kolkata",
  "created_at": "2024-01-15T10:30:00Z",
  "last_login_at": "2024-01-20T14:22:00Z",
  "active_devices_count": 2,
  "location": {
    "id": "location-uuid-here",
    "country": "India",
    "state": "Maharashtra",
    "district": "Pune",
    "city_village": "Pune City",
    "pincode": "411001",
    "coordinates": {
      "latitude": 18.5204,
      "longitude": 73.8567
    },
    "location_type": "home",
    "is_saved_address": true,
    "source_type": "manual",
    "source_confidence": "high",
    "created_at": "2024-01-15T10:30:00Z",
    "updated_at": "2024-01-20T14:22:00Z"
  },
  "locations": [
    {
      "id": "location-uuid-here",
      "country": "India",
      "state": "Maharashtra",
      "district": "Pune",
      "city_village": "Pune City",
      "pincode": "411001",
      "coordinates": {
        "latitude": 18.5204,
        "longitude": 73.8567
      },
      "location_type": "home",
      "is_saved_address": true,
      "source_type": "manual",
      "source_confidence": "high",
      "created_at": "2024-01-15T10:30:00Z",
      "updated_at": "2024-01-20T14:22:00Z"
    }
  ]
}
```

**Response Notes:**
- `location`: Primary/most recent saved location (or `null` if no saved locations)
- `locations`: Array of all saved locations (empty array if none)
- `coordinates`: `null` if latitude/longitude not available
- All optional fields (`avatar_url`, `language`, `timezone`) may be `null`

**Response with No Saved Locations:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "role": "user",
  "user_type": "seller",
  "avatar_url": null,
  "language": null,
  "timezone": null,
  "created_at": "2024-01-15T10:30:00Z",
  "last_login_at": "2024-01-20T14:22:00Z",
  "active_devices_count": 1,
  "location": null,
  "locations": []
}
```

**Error (401):**
```json
{
  "error": "Missing Authorization header"
}
```
or
```json
{
  "error": "Invalid or expired token"
}
```

**Error (404):**
```json
{
  "error": "User not found"
}
```

---

### 6. Update User Profile

**Endpoint:** `PUT /users/me`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Request:**
```json
{
  "name": "John Doe",
  "user_type": "seller"
}
```

**Response (200):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "role": "user",
  "user_type": "seller"
}
```

**Valid `user_type` values:**
- `seller`
- `buyer`
- `service_provider`

**Error (400):**
```json
{
  "error": "name and user_type are required"
}
```

---

### 7. List Active Devices

**Endpoint:** `GET /users/me/devices`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response (200):**
```json
{
  "devices": [
    {
      "device_identifier": "android-installation-id-123",
      "device_platform": "android",
      "device_model": "Samsung SM-M326B",
      "os_version": "Android 14",
      "app_version": "1.0.0",
      "language_code": "en-IN",
      "timezone": "Asia/Kolkata",
      "first_seen_at": "2024-01-15T10:30:00Z",
      "last_seen_at": "2024-01-20T14:22:00Z",
      "is_active": true
    }
  ]
}
```

---

### 8. Logout Specific Device

**Endpoint:** `DELETE /users/me/devices/:device_id`

**Headers:**
```
Authorization: Bearer <access_token>
```

**Response (200):**
```json
{
  "ok": true,
  "message": "Device logged out successfully"
}
```

**Note:** This will:
- Mark the device as inactive in `user_devices`
- Revoke all refresh tokens for that device
- Log the action in `auth_audit`

---

### 9. Logout All Other Devices

**Endpoint:** `POST /users/me/logout-all-other-devices`

**Headers:**
```
Authorization: Bearer <access_token>
X-Device-Id: <current_device_id>
```

**Alternative:** Send `current_device_id` in request body:
```json
{
  "current_device_id": "android-installation-id-123"
}
```

**Response (200):**
```json
{
  "ok": true,
  "message": "Logged out 2 device(s)",
  "revoked_devices_count": 2
}
```

**Error (400):**
```json
{
  "error": "current_device_id is required in header or body"
}
```

---

### 10. Health Check

**Endpoint:** `GET /health`

**Response (200):**
```json
{
  "ok": true
}
```

Use this to verify the service is running before attempting authentication.

---

## Kotlin Multiplatform Implementation

### 1. Data Models (Common Module)

```kotlin
// commonMain/kotlin/models/Requests.kt
package com.farm.auth.models

import kotlinx.serialization.Serializable

@Serializable
data class RequestOtpRequest(val phone_number: String)

@Serializable
data class RequestOtpResponse(val ok: Boolean)

@Serializable
data class DeviceInfo(
    val platform: String,
    val model: String? = null,
    @SerialName("os_version") val osVersion: String? = null,
    @SerialName("app_version") val appVersion: String? = null,
    @SerialName("language_code") val languageCode: String? = null,
    val timezone: String? = null
)

@Serializable
data class VerifyOtpRequest(
    @SerialName("phone_number") val phoneNumber: String,
    val code: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_info") val deviceInfo: DeviceInfo? = null
)

@Serializable
data class Coordinates(
    val latitude: Double,
    val longitude: Double
)

@Serializable
data class Location(
    val id: String,
    val country: String?,
    val state: String?,
    val district: String?,
    @SerialName("city_village") val cityVillage: String?,
    val pincode: String?,
    val coordinates: Coordinates?,
    @SerialName("location_type") val locationType: String?,
    @SerialName("is_saved_address") val isSavedAddress: Boolean,
    @SerialName("source_type") val sourceType: String?,
    @SerialName("source_confidence") val sourceConfidence: String?,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String
)

@Serializable
data class User(
    val id: String,
    @SerialName("phone_number") val phoneNumber: String,
    val name: String?,
    val role: String,
    @SerialName("user_type") val userType: String?,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val language: String? = null,
    val timezone: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_login_at") val lastLoginAt: String? = null,
    @SerialName("active_devices_count") val activeDevicesCount: Int? = null,
    val location: Location? = null,
    val locations: List<Location> = emptyList()
)

@Serializable
data class VerifyOtpResponse(
    val user: User,
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("needs_profile") val needsProfile: Boolean,
    @SerialName("is_new_device") val isNewDevice: Boolean,
    @SerialName("is_new_account") val isNewAccount: Boolean,
    @SerialName("active_devices_count") val activeDevicesCount: Int
)

@Serializable
data class RefreshRequest(@SerialName("refresh_token") val refreshToken: String)

@Serializable
data class RefreshResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String
)

@Serializable
data class LogoutRequest(@SerialName("refresh_token") val refreshToken: String)

@Serializable
data class LogoutResponse(val ok: Boolean)

@Serializable
data class UpdateProfileRequest(
    val name: String,
    @SerialName("user_type") val userType: String
)

@Serializable
data class Device(
    @SerialName("device_identifier") val deviceIdentifier: String,
    @SerialName("device_platform") val devicePlatform: String,
    @SerialName("device_model") val deviceModel: String?,
    @SerialName("os_version") val osVersion: String?,
    @SerialName("app_version") val appVersion: String?,
    @SerialName("language_code") val languageCode: String?,
    val timezone: String?,
    @SerialName("first_seen_at") val firstSeenAt: String,
    @SerialName("last_seen_at") val lastSeenAt: String,
    @SerialName("is_active") val isActive: Boolean
)

@Serializable
data class DevicesResponse(val devices: List<Device>)

@Serializable
data class LogoutAllOtherDevicesRequest(
    @SerialName("current_device_id") val currentDeviceId: String
)

@Serializable
data class LogoutAllOtherDevicesResponse(
    val ok: Boolean,
    val message: String,
    @SerialName("revoked_devices_count") val revokedDevicesCount: Int
)

@Serializable
data class ErrorResponse(val error: String)

@Serializable
data class HealthResponse(val ok: Boolean)
```

### 2. API Client (Common Module)

```kotlin
// commonMain/kotlin/network/AuthApiClient.kt
package com.farm.auth.network

import com.farm.auth.models.*
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.json.Json

class AuthApiClient(
    private val baseUrl: String,
    private val httpClient: HttpClient
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = false
    }

    init {
        httpClient.config {
            install(ContentNegotiation) {
                json(json)
            }
        }
    }

    suspend fun requestOtp(phoneNumber: String): Result<RequestOtpResponse> {
        return try {
            val response = httpClient.post("$baseUrl/auth/request-otp") {
                contentType(ContentType.Application.Json)
                setBody(RequestOtpRequest(phoneNumber))
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun verifyOtp(
        phoneNumber: String,
        code: String,
        deviceId: String,
        deviceInfo: DeviceInfo? = null
    ): Result<VerifyOtpResponse> {
        return try {
            val request = VerifyOtpRequest(phoneNumber, code, deviceId, deviceInfo)
            val response = httpClient.post("$baseUrl/auth/verify-otp") {
                contentType(ContentType.Application.Json)
                setBody(request)
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun refreshToken(refreshToken: String): Result<RefreshResponse> {
        return try {
            val request = RefreshRequest(refreshToken)
            val response = httpClient.post("$baseUrl/auth/refresh") {
                contentType(ContentType.Application.Json)
                setBody(request)
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun logout(refreshToken: String): Result<LogoutResponse> {
        return try {
            val request = LogoutRequest(refreshToken)
            val response = httpClient.post("$baseUrl/auth/logout") {
                contentType(ContentType.Application.Json)
                setBody(request)
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getCurrentUser(accessToken: String): Result<User> {
        return try {
            val response = httpClient.get("$baseUrl/users/me") {
                contentType(ContentType.Application.Json)
                header("Authorization", "Bearer $accessToken")
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateProfile(
        name: String,
        userType: String,
        accessToken: String
    ): Result<User> {
        return try {
            val request = UpdateProfileRequest(name, userType)
            val response = httpClient.put("$baseUrl/users/me") {
                contentType(ContentType.Application.Json)
                header("Authorization", "Bearer $accessToken")
                setBody(request)
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getDevices(accessToken: String): Result<DevicesResponse> {
        return try {
            val response = httpClient.get("$baseUrl/users/me/devices") {
                contentType(ContentType.Application.Json)
                header("Authorization", "Bearer $accessToken")
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun logoutDevice(
        deviceId: String,
        accessToken: String
    ): Result<LogoutResponse> {
        return try {
            val response = httpClient.delete("$baseUrl/users/me/devices/$deviceId") {
                contentType(ContentType.Application.Json)
                header("Authorization", "Bearer $accessToken")
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun logoutAllOtherDevices(
        currentDeviceId: String,
        accessToken: String
    ): Result<LogoutAllOtherDevicesResponse> {
        return try {
            val request = LogoutAllOtherDevicesRequest(currentDeviceId)
            val response = httpClient.post("$baseUrl/users/me/logout-all-other-devices") {
                contentType(ContentType.Application.Json)
                header("Authorization", "Bearer $accessToken")
                header("X-Device-Id", currentDeviceId)
                setBody(request)
            }
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun healthCheck(): Result<HealthResponse> {
        return try {
            val response = httpClient.get("$baseUrl/health")
            Result.success(response.body())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
```

### 3. Token Storage Interface (Common Module)

```kotlin
// commonMain/kotlin/storage/TokenStorage.kt
package com.farm.auth.storage

interface TokenStorage {
    fun saveTokens(accessToken: String, refreshToken: String)
    fun getAccessToken(): String?
    fun getRefreshToken(): String?
    fun clearTokens()
}
```

### 4. Android Token Storage Implementation

```kotlin
// androidMain/kotlin/storage/AndroidTokenStorage.kt
package com.farm.auth.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class AndroidTokenStorage(private val context: Context) : TokenStorage {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "auth_tokens",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    override fun saveTokens(accessToken: String, refreshToken: String) {
        prefs.edit().apply {
            putString("access_token", accessToken)
            putString("refresh_token", refreshToken)
            apply()
        }
    }

    override fun getAccessToken(): String? = prefs.getString("access_token", null)

    override fun getRefreshToken(): String? = prefs.getString("refresh_token", null)

    override fun clearTokens() {
        prefs.edit().clear().apply()
    }
}
```

### 5. iOS Token Storage Implementation (using Keychain)

```kotlin
// iosMain/kotlin/storage/IosTokenStorage.kt
package com.farm.auth.storage

import platform.Security.*
import platform.Foundation.*

class IosTokenStorage : TokenStorage {
    private val accessTokenKey = "access_token"
    private val refreshTokenKey = "refresh_token"
    private val service = "com.farm.auth"

    override fun saveTokens(accessToken: String, refreshToken: String) {
        saveToKeychain(accessTokenKey, accessToken)
        saveToKeychain(refreshTokenKey, refreshToken)
    }

    override fun getAccessToken(): String? = getFromKeychain(accessTokenKey)

    override fun getRefreshToken(): String? = getFromKeychain(refreshTokenKey)

    override fun clearTokens() {
        deleteFromKeychain(accessTokenKey)
        deleteFromKeychain(refreshTokenKey)
    }

    private fun saveToKeychain(key: String, value: String): Boolean {
        val data = (value as NSString).dataUsingEncoding(NSUTF8StringEncoding) ?: return false
        val query = mapOf(
            kSecClass to kSecClassGenericPassword,
            kSecAttrService to service,
            kSecAttrAccount to key,
            kSecValueData to data
        )
        SecItemDelete(query.toCFDictionary())
        return SecItemAdd(query.toCFDictionary(), null) == errSecSuccess
    }

    private fun getFromKeychain(key: String): String? {
        val query = mapOf(
            kSecClass to kSecClassGenericPassword,
            kSecAttrService to service,
            kSecAttrAccount to key,
            kSecReturnData to kCFBooleanTrue
        )
        val result = alloc<AnyVar>()
        if (SecItemCopyMatching(query.toCFDictionary(), result.ptr) == errSecSuccess) {
            val data = result.value as? NSData ?: return null
            return NSString.create(data, NSUTF8StringEncoding) as String
        }
        return null
    }

    private fun deleteFromKeychain(key: String) {
        val query = mapOf(
            kSecClass to kSecClassGenericPassword,
            kSecAttrService to service,
            kSecAttrAccount to key
        )
        SecItemDelete(query.toCFDictionary())
    }
}
```

### 6. Device Info Provider Interface

```kotlin
// commonMain/kotlin/device/DeviceInfoProvider.kt
package com.farm.auth.device

import com.farm.auth.models.DeviceInfo

interface DeviceInfoProvider {
    fun getDeviceId(): String
    fun getDeviceInfo(): DeviceInfo
}
```

### 7. Authentication Manager

```kotlin
// commonMain/kotlin/auth/AuthManager.kt
package com.farm.auth.auth

import com.farm.auth.models.*
import com.farm.auth.network.AuthApiClient
import com.farm.auth.storage.TokenStorage
import com.farm.auth.device.DeviceInfoProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class AuthManager(
    private val apiClient: AuthApiClient,
    private val tokenStorage: TokenStorage,
    private val deviceInfoProvider: DeviceInfoProvider
) {
    private val _currentUser = MutableStateFlow<User?>(null)
    val currentUser: StateFlow<User?> = _currentUser.asStateFlow()

    private val _isAuthenticated = MutableStateFlow(false)
    val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    suspend fun requestOtp(phoneNumber: String): Result<RequestOtpResponse> {
        return apiClient.requestOtp(phoneNumber)
    }

    suspend fun verifyOtp(phoneNumber: String, code: String): Result<VerifyOtpResponse> {
        val deviceId = deviceInfoProvider.getDeviceId()
        val deviceInfo = deviceInfoProvider.getDeviceInfo()

        return apiClient.verifyOtp(phoneNumber, code, deviceId, deviceInfo)
            .onSuccess { response ->
                tokenStorage.saveTokens(response.accessToken, response.refreshToken)
                _currentUser.value = response.user
                _isAuthenticated.value = true
            }
    }

    suspend fun refreshTokens(): Result<Pair<String, String>> {
        val refreshToken = tokenStorage.getRefreshToken()
            ?: return Result.failure(Exception("No refresh token"))

        return apiClient.refreshToken(refreshToken)
            .onSuccess { response ->
                tokenStorage.saveTokens(response.accessToken, response.refreshToken)
            }
            .onFailure {
                // If refresh fails, clear tokens and logout
                if (it.message?.contains("Invalid refresh token") == true) {
                    logout()
                }
            }
            .map { it.accessToken to it.refreshToken }
    }

    suspend fun logout() {
        tokenStorage.getRefreshToken()?.let { refreshToken ->
            apiClient.logout(refreshToken)
        }
        tokenStorage.clearTokens()
        _currentUser.value = null
        _isAuthenticated.value = false
    }

    suspend fun getCurrentUser(): Result<User> {
        val accessToken = tokenStorage.getAccessToken()
            ?: return Result.failure(Exception("Not authenticated"))

        return apiClient.getCurrentUser(accessToken)
            .onSuccess { user ->
                _currentUser.value = user
            }
            .recoverCatching { error ->
                if (error.message?.contains("401") == true || 
                    error.message?.contains("Unauthorized") == true) {
                    // Try to refresh token and retry
                    refreshTokens().getOrNull()?.let { (newAccessToken, _) ->
                        apiClient.getCurrentUser(newAccessToken)
                            .onSuccess { user ->
                                _currentUser.value = user
                            }
                    } ?: Result.failure(error)
                } else {
                    Result.failure(error)
                }
            }
    }

    suspend fun updateProfile(name: String, userType: String): Result<User> {
        val accessToken = tokenStorage.getAccessToken()
            ?: return Result.failure(Exception("Not authenticated"))

        return apiClient.updateProfile(name, userType, accessToken)
            .onSuccess { user ->
                _currentUser.value = user
            }
    }

    suspend fun getDevices(): Result<DevicesResponse> {
        val accessToken = tokenStorage.getAccessToken()
            ?: return Result.failure(Exception("Not authenticated"))

        return callWithAuth { token ->
            apiClient.getDevices(token)
        }
    }

    suspend fun logoutDevice(deviceId: String): Result<LogoutResponse> {
        return callWithAuth { token ->
            apiClient.logoutDevice(deviceId, token)
        }
    }

    suspend fun logoutAllOtherDevices(): Result<LogoutAllOtherDevicesResponse> {
        val currentDeviceId = deviceInfoProvider.getDeviceId()
        return callWithAuth { token ->
            apiClient.logoutAllOtherDevices(currentDeviceId, token)
        }
    }

    fun getAccessToken(): String? = tokenStorage.getAccessToken()

    private suspend fun <T> callWithAuth(
        block: suspend (String) -> Result<T>
    ): Result<T> {
        val token = tokenStorage.getAccessToken()
            ?: return Result.failure(Exception("Not authenticated"))

        return block(token).recoverCatching { error ->
            if (error.message?.contains("401") == true || 
                error.message?.contains("Unauthorized") == true) {
                // Token expired, refresh and retry
                refreshTokens().getOrNull()?.let { (newAccessToken, _) ->
                    block(newAccessToken)
                } ?: Result.failure(Exception("Failed to refresh token"))
            } else {
                Result.failure(error)
            }
        }
    }
}
```

---

## Error Handling

### Common Error Codes

| Status | Error | Description |
|--------|-------|-------------|
| 400 | `phone_number is required` | Missing phone number in request |
| 400 | `Invalid or expired OTP` | Wrong code, OTP expired (10 min), or max attempts exceeded (5) |
| 400 | `name and user_type are required` | Missing required fields in profile update |
| 400 | `current_device_id is required` | Missing device ID for logout all devices |
| 401 | `Invalid refresh token` | Token expired, revoked, or compromised |
| 401 | `Missing Authorization header` | Access token not provided |
| 401 | `Invalid or expired token` | Access token invalid or expired |
| 404 | `User not found` | User account doesn't exist |
| 403 | `Origin not allowed` | CORS restriction (production only) |
| 500 | `Internal server error` | Server-side error |
| 500 | `Failed to send OTP` | Twilio SMS sending failed |

### Error Response Format

```json
{
  "error": "Error message here"
}
```

---

## Security Best Practices

1. **Store tokens securely**
   - **Android**: Use `EncryptedSharedPreferences` (Android Security Library)
   - **iOS**: Use Keychain Services
   - Never store tokens in plain SharedPreferences/UserDefaults

2. **Handle token expiration**
   - Automatically refresh when access token expires (401 response)
   - Implement retry logic with token refresh

3. **Rotate refresh tokens**
   - Always save the new `refresh_token` after refresh
   - Old refresh tokens are automatically revoked

4. **Validate device_id**
   - Use consistent device identifier (Android ID, Installation ID, or Vendor ID)
   - Device ID should be 4-128 alphanumeric characters
   - Server will hash invalid device IDs

5. **Handle reuse detection**
   - If refresh returns 401 with "Invalid refresh token", force re-login
   - This indicates potential token compromise

6. **Secure network communication**
   - Always use HTTPS in production
   - Implement certificate pinning if needed

7. **Rate limiting awareness**
   - Don't spam OTP requests
   - Implement client-side rate limiting if possible

---

## Token Management

### Token Expiration

- **Access Token:** 15 minutes (default, configurable via `JWT_ACCESS_TTL` env var)
- **Refresh Token:** 7 days (default, configurable via `JWT_REFRESH_TTL` env var)
- **Refresh Token Idle Timeout:** 3 days (default, configurable via `REFRESH_MAX_IDLE_MINUTES` = 4320)
- **OTP:** 10 minutes (fixed)

### Auto-refresh Pattern

```kotlin
suspend fun <T> callWithAuth(
    block: suspend (String) -> Result<T>
): Result<T> {
    val token = tokenStorage.getAccessToken()
        ?: return Result.failure(Exception("Not authenticated"))
    
    return block(token).recoverCatching { error ->
        if (error.message?.contains("401") == true || 
            error.message?.contains("Unauthorized") == true) {
            // Token expired, refresh and retry
            refreshTokens().getOrNull()?.let { (newAccessToken, _) ->
                block(newAccessToken)
            } ?: Result.failure(Exception("Failed to refresh token"))
        } else {
            Result.failure(error)
        }
    }
}
```

---

## Notes

- Phone numbers are auto-normalized: 10-digit numbers → `+91` prefix
- Device ID should be 4-128 alphanumeric characters (server sanitizes if invalid)
- Refresh tokens rotate on each use - always update stored token
- If `needs_profile: true`, prompt user to complete profile before accessing app
- `is_new_device` and `is_new_account` flags help with onboarding flows
- Device management endpoints require authentication
- All timestamps are in ISO 8601 format with timezone (UTC)

---

## Example Usage (Android Activity)

```kotlin
class LoginActivity : AppCompatActivity() {
    private lateinit var authManager: AuthManager
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        val httpClient = HttpClient(Android) {
            install(ContentNegotiation) {
                json()
            }
        }
        
        val apiClient = AuthApiClient("http://your-api-url", httpClient)
        val tokenStorage = AndroidTokenStorage(this)
        val deviceInfoProvider = AndroidDeviceInfoProvider(this)
        
        authManager = AuthManager(apiClient, tokenStorage, deviceInfoProvider)
        
        // Observe authentication state
        lifecycleScope.launch {
            authManager.isAuthenticated.collect { isAuth ->
                if (isAuth) {
                    // Navigate to main screen
                }
            }
        }
    }
    
    private fun requestOtp() {
        lifecycleScope.launch {
            val phoneNumber = phoneInput.text.toString()
            authManager.requestOtp(phoneNumber)
                .onSuccess { 
                    showToast("OTP sent!") 
                }
                .onFailure { 
                    showError(it.message ?: "Failed to send OTP") 
                }
        }
    }
    
    private fun verifyOtp() {
        lifecycleScope.launch {
            val phoneNumber = phoneInput.text.toString()
            val code = otpInput.text.toString()
            
            authManager.verifyOtp(phoneNumber, code)
                .onSuccess { response ->
                    if (response.needsProfile) {
                        startActivity(Intent(this@LoginActivity, ProfileSetupActivity::class.java))
                    } else {
                        startActivity(Intent(this@LoginActivity, MainActivity::class.java))
                    }
                    finish()
                }
                .onFailure { 
                    showError("Invalid OTP") 
                }
        }
    }
}
```
