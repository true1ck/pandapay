# How to Use `/users/me` Endpoint in Kotlin Application

Complete guide for integrating the authenticated `/users/me` endpoint in your Kotlin/Android application.

---

## Overview

**Endpoint:** `GET http://localhost:3000/users/me` (or your production URL)

**Authentication Required:** Yes (JWT Bearer Token)

**What it returns:**
- User details (phone, name, profile type)
- Last login time
- Location information (primary + all saved locations)
- Active devices count

---

## Complete Flow

### Step 1: User Login (Get Tokens)
```
POST /auth/verify-otp
→ Returns: { access_token, refresh_token, user, ... }
```

### Step 2: Store Tokens Securely
```
Save access_token and refresh_token in EncryptedSharedPreferences
```

### Step 3: Make Authenticated Request
```
GET /users/me
Header: Authorization: Bearer <access_token>
→ Returns: { id, phone_number, name, location, ... }
```

### Step 4: Handle Token Expiration
```
If 401 error → Use refresh_token to get new tokens
If refresh fails → Redirect to login
```

---

## Kotlin Implementation

### 1. Add Dependencies (build.gradle.kts)

```kotlin
dependencies {
    // Ktor for HTTP requests
    implementation("io.ktor:ktor-client-android:2.3.5")
    implementation("io.ktor:ktor-client-content-negotiation:2.3.5")
    implementation("io.ktor:ktor-serialization-kotlinx-json:2.3.5")
    
    // Secure storage
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    
    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
}
```

---

### 2. Data Models

```kotlin
// models/User.kt
package com.farm.auth.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

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
data class ErrorResponse(val error: String)
```

---

### 3. Secure Token Storage

```kotlin
// storage/TokenManager.kt
package com.farm.auth.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class TokenManager(private val context: Context) {
    
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

    fun saveTokens(accessToken: String, refreshToken: String) {
        prefs.edit().apply {
            putString("access_token", accessToken)
            putString("refresh_token", refreshToken)
            apply()
        }
    }

    fun getAccessToken(): String? = prefs.getString("access_token", null)

    fun getRefreshToken(): String? = prefs.getString("refresh_token", null)

    fun clearTokens() {
        prefs.edit().clear().apply()
    }
    
    fun hasTokens(): Boolean {
        return getAccessToken() != null && getRefreshToken() != null
    }
}
```

---

### 4. API Client with Auto-Refresh

```kotlin
// network/AuthApiClient.kt
package com.farm.auth.network

import com.farm.auth.models.*
import com.farm.auth.storage.TokenManager
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.defaultrequest.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json

class AuthApiClient(
    private val baseUrl: String,
    private val tokenManager: TokenManager
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = false
    }

    private val client = HttpClient(Android) {
        install(ContentNegotiation) {
            json(json)
        }
        install(DefaultRequest) {
            url(baseUrl)
            contentType(ContentType.Application.Json)
        }
        // Add auth token to all requests automatically
        engine {
            addInterceptor { request ->
                val token = tokenManager.getAccessToken()
                if (token != null && !request.url.encodedPath.contains("/auth/")) {
                    request.headers.append("Authorization", "Bearer $token")
                }
                request
            }
        }
    }

    private val _currentUser = MutableStateFlow<User?>(null)
    val currentUser: StateFlow<User?> = _currentUser.asStateFlow()

    /**
     * Refresh access token using refresh token
     */
    suspend fun refreshTokens(): Result<Pair<String, String>> {
        val refreshToken = tokenManager.getRefreshToken()
            ?: return Result.failure(Exception("No refresh token available"))

        return try {
            val response = client.post("/auth/refresh") {
                setBody(mapOf("refresh_token" to refreshToken))
            }

            if (response.status.isSuccess()) {
                val data: RefreshResponse = response.body()
                tokenManager.saveTokens(data.accessToken, data.refreshToken)
                Result.success(data.accessToken to data.refreshToken)
            } else {
                val error: ErrorResponse = response.body()
                Result.failure(Exception(error.error))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Get current user details from /users/me endpoint
     * Automatically handles token refresh on 401
     */
    suspend fun getCurrentUser(): Result<User> {
        return try {
            val response = client.get("/users/me")

            if (response.status.isSuccess()) {
                val user: User = response.body()
                _currentUser.value = user
                Result.success(user)
            } else if (response.status == HttpStatusCode.Unauthorized) {
                // Token expired, try to refresh
                refreshTokens().fold(
                    onSuccess = { (newAccessToken, _) ->
                        // Retry with new token
                        val retryResponse = client.get("/users/me") {
                            header("Authorization", "Bearer $newAccessToken")
                        }
                        if (retryResponse.status.isSuccess()) {
                            val user: User = retryResponse.body()
                            _currentUser.value = user
                            Result.success(user)
                        } else {
                            // Refresh worked but retry failed - force re-login
                            tokenManager.clearTokens()
                            _currentUser.value = null
                            Result.failure(Exception("Authentication failed. Please login again."))
                        }
                    },
                    onFailure = { error ->
                        // Refresh failed - force re-login
                        tokenManager.clearTokens()
                        _currentUser.value = null
                        Result.failure(Exception("Session expired. Please login again."))
                    }
                )
            } else {
                val error: ErrorResponse = response.body()
                Result.failure(Exception(error.error))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    @Serializable
    private data class RefreshResponse(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String
    )
}
```

---

### 5. Repository Pattern (Optional but Recommended)

```kotlin
// repository/UserRepository.kt
package com.farm.auth.repository

import com.farm.auth.models.User
import com.farm.auth.network.AuthApiClient
import kotlinx.coroutines.flow.StateFlow

class UserRepository(private val apiClient: AuthApiClient) {
    
    val currentUser: StateFlow<User?> = apiClient.currentUser
    
    suspend fun getUserDetails(): Result<User> {
        return apiClient.getCurrentUser()
    }
    
    suspend fun refreshUserData(): Result<User> {
        return apiClient.getCurrentUser()
    }
}
```

---

### 6. ViewModel Usage

```kotlin
// ui/UserProfileViewModel.kt
package com.farm.auth.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.farm.auth.models.User
import com.farm.auth.repository.UserRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class UserProfileViewModel(
    private val userRepository: UserRepository
) : ViewModel() {
    
    private val _uiState = MutableStateFlow<UserProfileUiState>(UserProfileUiState.Loading)
    val uiState: StateFlow<UserProfileUiState> = _uiState.asStateFlow()

    init {
        loadUserProfile()
    }
    
    fun loadUserProfile() {
        viewModelScope.launch {
            _uiState.value = UserProfileUiState.Loading
            
            userRepository.getUserDetails()
                .fold(
                    onSuccess = { user ->
                        _uiState.value = UserProfileUiState.Success(user)
                    },
                    onFailure = { error ->
                        _uiState.value = UserProfileUiState.Error(error.message ?: "Failed to load profile")
                    }
                )
        }
    }
    
    fun refreshProfile() {
        loadUserProfile()
    }
}

sealed class UserProfileUiState {
    object Loading : UserProfileUiState()
    data class Success(val user: User) : UserProfileUiState()
    data class Error(val message: String) : UserProfileUiState()
}
```

---

### 7. Activity/Fragment Usage

```kotlin
// ui/UserProfileActivity.kt
package com.farm.auth.ui

import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.farm.auth.network.AuthApiClient
import com.farm.auth.repository.UserRepository
import com.farm.auth.storage.TokenManager
import kotlinx.coroutines.launch

class UserProfileActivity : AppCompatActivity() {
    
    private val viewModel: UserProfileViewModel by viewModels {
        val tokenManager = TokenManager(this)
        val apiClient = AuthApiClient("http://localhost:3000", tokenManager)
        val repository = UserRepository(apiClient)
        UserProfileViewModelFactory(repository)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_user_profile)

        // Observe UI state
        lifecycleScope.launch {
            viewModel.uiState.collect { state ->
                when (state) {
                    is UserProfileUiState.Loading -> {
                        // Show loading indicator
                        showLoading()
                    }
                    is UserProfileUiState.Success -> {
                        // Display user data
                        displayUserData(state.user)
                        hideLoading()
                    }
                    is UserProfileUiState.Error -> {
                        // Show error message
                        showError(state.message)
                        hideLoading()
                    }
                }
            }
        }
    }
    
    private fun displayUserData(user: User) {
        // Update UI with user data
        findViewById<TextView>(R.id.tvName).text = user.name ?: "Not set"
        findViewById<TextView>(R.id.tvPhone).text = user.phoneNumber
        findViewById<TextView>(R.id.tvProfileType).text = user.userType ?: "Not set"
        findViewById<TextView>(R.id.tvLastLogin).text = user.lastLoginAt ?: "Never"
        
        // Display location
        user.location?.let { location ->
            findViewById<TextView>(R.id.tvLocation).text = buildString {
                append(location.cityVillage ?: "")
                if (location.district != null) append(", ${location.district}")
                if (location.state != null) append(", ${location.state}")
                if (location.pincode != null) append(" - ${location.pincode}")
            }
        } ?: run {
            findViewById<TextView>(R.id.tvLocation).text = "No location saved"
        }
    }
}
```

---

## Simple Example (Without Repository)

If you want a simpler approach without repository pattern:

```kotlin
// Simple usage in Activity
class MainActivity : AppCompatActivity() {
    
    private lateinit var tokenManager: TokenManager
    private lateinit var apiClient: AuthApiClient
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        tokenManager = TokenManager(this)
        apiClient = AuthApiClient("http://localhost:3000", tokenManager)
        
        // Load user profile
        loadUserProfile()
    }
    
    private fun loadUserProfile() {
        lifecycleScope.launch {
            apiClient.getCurrentUser()
                .onSuccess { user ->
                    // Use user data
                    Log.d("User", "Name: ${user.name}")
                    Log.d("User", "Phone: ${user.phoneNumber}")
                    Log.d("User", "Location: ${user.location?.cityVillage}")
                }
                .onFailure { error ->
                    Log.e("Error", "Failed: ${error.message}")
                    // Handle error - maybe redirect to login
                }
        }
    }
}
```

---

## Complete Flow Example

```kotlin
// Complete authentication and profile loading flow
class AuthFlow {
    
    suspend fun loginAndLoadProfile(
        phoneNumber: String,
        otpCode: String
    ): Result<User> {
        // 1. Login and get tokens
        val loginResult = login(phoneNumber, otpCode)
        
        return loginResult.fold(
            onSuccess = { tokens ->
                // 2. Save tokens
                tokenManager.saveTokens(tokens.accessToken, tokens.refreshToken)
                
                // 3. Get user profile
                apiClient.getCurrentUser()
            },
            onFailure = { error ->
                Result.failure(error)
            }
        )
    }
}
```

---

## Key Points

### 1. **Authentication Header Format**
```
Authorization: Bearer <access_token>
```

### 2. **Token Storage**
- ✅ Use `EncryptedSharedPreferences` (secure)
- ❌ Don't use plain `SharedPreferences`
- ❌ Don't log tokens in console/logs

### 3. **Token Refresh Flow**
```
401 Error → Refresh Token → Retry Request
If refresh fails → Clear tokens → Redirect to login
```

### 4. **Base URL Configuration**

The backend may use AWS SSM Parameter Store for database credentials (server-side only). This doesn't affect your Kotlin client - you just need to configure the correct API base URL.

```kotlin
// Development/Local
val baseUrl = "http://localhost:3000"

// Test Environment
val baseUrl = "https://test-api.yourdomain.com"

// Production
val baseUrl = "https://api.yourdomain.com"
```

**Environment-based Configuration:**
```kotlin
// config/ApiConfig.kt
object ApiConfig {
    val baseUrl: String
        get() = when (BuildConfig.BUILD_TYPE) {
            "debug" -> "http://localhost:3000"  // Local development
            "staging" -> "https://test-api.yourdomain.com"  // Test environment
            "release" -> "https://api.yourdomain.com"  // Production
            else -> "http://localhost:3000"
        }
}

// Usage
val apiClient = AuthApiClient(ApiConfig.baseUrl, tokenManager)
```

### 5. **Error Handling**
- **401 Unauthorized**: Token expired → Try refresh
- **404 Not Found**: User doesn't exist
- **500 Server Error**: Server issue

---

## Testing Checklist

- [ ] Login successfully and get tokens
- [ ] Store tokens securely
- [ ] Fetch user profile with valid token
- [ ] Handle token expiration (wait 15+ min, then retry)
- [ ] Handle refresh token rotation
- [ ] Handle refresh token expiration (force re-login)
- [ ] Handle network errors gracefully
- [ ] Display user data correctly
- [ ] Display location data if available

---

## AWS SSM Parameter Store (Backend Configuration)

**Important:** AWS SSM Parameter Store is a **server-side feature only**. It's used by the backend to securely store database credentials. Your Kotlin application doesn't need to interact with AWS SSM directly.

### What AWS SSM Does (Backend)
- Stores database credentials securely in AWS
- Backend fetches credentials from SSM on startup
- No changes needed in your Kotlin client code

### What You Need to Know (Kotlin App)
1. **API Endpoints remain the same** - No changes to API calls
2. **Base URL configuration** - Use correct environment URL (see below)
3. **Authentication flow unchanged** - Same OTP and token flow

### Environment Configuration

The backend may be deployed to different environments (test/prod) which use different SSM parameter paths. Your Kotlin app should connect to the correct API endpoint:

```kotlin
// config/EnvironmentConfig.kt
enum class Environment {
    DEVELOPMENT,
    TEST,
    PRODUCTION
}

object EnvironmentConfig {
    val currentEnvironment: Environment
        get() = when (BuildConfig.BUILD_TYPE) {
            "debug" -> Environment.DEVELOPMENT
            "staging" -> Environment.TEST
            "release" -> Environment.PRODUCTION
            else -> Environment.DEVELOPMENT
        }
    
    val apiBaseUrl: String
        get() = when (currentEnvironment) {
            Environment.DEVELOPMENT -> "http://localhost:3000"
            Environment.TEST -> "https://test-api.livingai.app"  // Test backend
            Environment.PRODUCTION -> "https://api.livingai.app"  // Production backend
        }
}

// Usage in your app
class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        
        val tokenManager = TokenManager(this)
        val apiClient = AuthApiClient(
            baseUrl = EnvironmentConfig.apiBaseUrl,
            tokenManager = tokenManager
        )
        
        // Store in dependency injection container
        // or use as singleton
    }
}
```

### Build Variants Setup (build.gradle.kts)

```kotlin
android {
    buildTypes {
        debug {
            buildConfigField("String", "API_BASE_URL", "\"http://localhost:3000\"")
        }
        
        create("staging") {
            buildConfigField("String", "API_BASE_URL", "\"https://test-api.livingai.app\"")
            isMinifyEnabled = false
        }
        
        release {
            buildConfigField("String", "API_BASE_URL", "\"https://api.livingai.app\"")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

// Then use in code
val baseUrl = BuildConfig.API_BASE_URL
```

## Production Considerations

1. **Base URL**: Use environment-based configuration (see above)

2. **Certificate Pinning**: For production, implement SSL pinning
   ```kotlin
   // Add certificate pinning for security
   val client = HttpClient(Android) {
       engine {
           // Configure certificate pinning
       }
   }
   ```

3. **Error Logging**: Log errors to crash reporting (Firebase Crashlytics, etc.)

4. **Network Timeout**: Set appropriate timeouts for network requests
   ```kotlin
   val client = HttpClient(Android) {
       install(HttpTimeout) {
           requestTimeoutMillis = 30000  // 30 seconds
           connectTimeoutMillis = 10000  // 10 seconds
       }
   }
   ```

5. **Token Refresh Strategy**: Consider proactive refresh (refresh before expiration)
   ```kotlin
   // Refresh token proactively before expiration
   suspend fun refreshTokenIfNeeded() {
       val token = tokenManager.getAccessToken()
       if (token != null && isTokenExpiringSoon(token)) {
           apiClient.refreshTokens()
       }
   }
   ```

6. **Network Security Config**: For production, enforce HTTPS only
   ```xml
   <!-- res/xml/network_security_config.xml -->
   <network-security-config>
       <base-config cleartextTrafficPermitted="false">
           <trust-anchors>
               <certificates src="system" />
           </trust-anchors>
       </base-config>
   </network-security-config>
   ```

---

## Quick Reference

**Endpoint:** `GET /users/me`

**Headers:**
```http
Authorization: Bearer <access_token>
Content-Type: application/json
```

**Success Response (200):**
```json
{
  "id": "...",
  "phone_number": "+919876543210",
  "name": "John Doe",
  "user_type": "seller",
  "last_login_at": "2024-01-20T14:22:00Z",
  "location": { ... },
  "locations": [ ... ]
}
```

**Error Responses:**
- **401**: Token expired/invalid → Refresh token
- **404**: User not found
- **500**: Server error

---

## AWS SSM Integration Summary

### For Kotlin Developers

✅ **What you DON'T need to do:**
- No AWS SDK in your Kotlin app
- No SSM client code
- No changes to authentication flow
- No changes to API calls

✅ **What you DO need:**
- Configure correct base URL for each environment
- Use proper environment-based build variants
- Handle API responses as before

### Backend Configuration (Server-Side)

The backend uses AWS SSM Parameter Store to fetch database credentials:
- **Test Environment**: `/test/livingai/db/app`
- **Production Environment**: `/prod/livingai/db/app`

This is configured on the server with:
```env
USE_AWS_SSM=true
AWS_REGION=ap-south-1
```

Your Kotlin app just needs to connect to the correct API endpoint for each environment.

---

This guide provides everything you need to integrate the `/users/me` endpoint in your Kotlin application!










