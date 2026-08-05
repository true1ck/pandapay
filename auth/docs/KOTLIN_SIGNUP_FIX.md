# Kotlin Signup API Response Fix

## Problem
The error "Expected response body of the type 'class com.example.livingai...'" indicates that your Kotlin data class doesn't match the actual API response structure.

## Actual API Response Structure

The `/auth/signup` endpoint returns:

```json
{
  "success": true,
  "user": {
    "id": "uuid-here",
    "phone_number": "+919876543210",
    "name": "John Doe",
    "country_code": "+91",
    "created_at": "2024-01-15T10:30:00Z"
  },
  "access_token": "jwt-token",
  "refresh_token": "jwt-token",
  "needs_profile": true,
  "is_new_account": true,
  "is_new_device": true,
  "active_devices_count": 1,
  "location_id": "uuid-or-null"
}
```

## Correct Kotlin Data Classes

### Option 1: Using Gson/Moshi with @SerializedName

```kotlin
import com.google.gson.annotations.SerializedName
// OR for Moshi: import com.squareup.moshi.Json

data class SignupUser(
    val id: String,
    @SerializedName("phone_number") val phoneNumber: String,
    val name: String?,
    @SerializedName("country_code") val countryCode: String?,
    @SerializedName("created_at") val createdAt: String?
)

data class SignupResponse(
    val success: Boolean,
    val user: SignupUser,
    @SerializedName("access_token") val accessToken: String,
    @SerializedName("refresh_token") val refreshToken: String,
    @SerializedName("needs_profile") val needsProfile: Boolean,
    @SerializedName("is_new_account") val isNewAccount: Boolean,
    @SerializedName("is_new_device") val isNewDevice: Boolean,
    @SerializedName("active_devices_count") val activeDevicesCount: Int,
    @SerializedName("location_id") val locationId: String?
)
```

### Option 2: Using Kotlinx Serialization

```kotlin
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SignupUser(
    val id: String,
    @SerialName("phone_number") val phoneNumber: String,
    val name: String? = null,
    @SerialName("country_code") val countryCode: String? = null,
    @SerialName("created_at") val createdAt: String? = null
)

@Serializable
data class SignupResponse(
    val success: Boolean,
    val user: SignupUser,
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("needs_profile") val needsProfile: Boolean,
    @SerialName("is_new_account") val isNewAccount: Boolean,
    @SerialName("is_new_device") val isNewDevice: Boolean,
    @SerialName("active_devices_count") val activeDevicesCount: Int,
    @SerialName("location_id") val locationId: String? = null
)
```

### Option 3: Using Retrofit with Field Naming Strategy

If using Retrofit, you can configure it to handle snake_case automatically:

```kotlin
// In your Retrofit builder
val retrofit = Retrofit.Builder()
    .baseUrl(BASE_URL)
    .addConverterFactory(
        GsonConverterFactory.create(
            GsonBuilder()
                .setFieldNamingPolicy(FieldNamingPolicy.LOWER_CASE_WITH_UNDERSCORES)
                .create()
        )
    )
    .build()

// Then your data classes can use camelCase
data class SignupUser(
    val id: String,
    val phoneNumber: String,  // Will map to "phone_number"
    val name: String?,
    val countryCode: String?,  // Will map to "country_code"
    val createdAt: String?  // Will map to "created_at"
)

data class SignupResponse(
    val success: Boolean,
    val user: SignupUser,
    val accessToken: String,  // Will map to "access_token"
    val refreshToken: String,  // Will map to "refresh_token"
    val needsProfile: Boolean,
    val isNewAccount: Boolean,
    val isNewDevice: Boolean,
    val activeDevicesCount: Int,
    val locationId: String?
)
```

## Complete Example with Error Handling

```kotlin
// SignupRequest.kt
data class SignupRequest(
    val name: String,
    @SerializedName("phone_number") val phoneNumber: String,
    val state: String? = null,
    val district: String? = null,
    @SerializedName("city_village") val cityVillage: String? = null,
    @SerializedName("device_id") val deviceId: String? = null,
    @SerializedName("device_info") val deviceInfo: Map<String, String?>? = null
)

// SignupResponse.kt
data class SignupUser(
    val id: String,
    @SerializedName("phone_number") val phoneNumber: String,
    val name: String?,
    @SerializedName("country_code") val countryCode: String?,
    @SerializedName("created_at") val createdAt: String?
)

data class SignupResponse(
    val success: Boolean,
    val user: SignupUser,
    @SerializedName("access_token") val accessToken: String,
    @SerializedName("refresh_token") val refreshToken: String,
    @SerializedName("needs_profile") val needsProfile: Boolean,
    @SerializedName("is_new_account") val isNewAccount: Boolean,
    @SerializedName("is_new_device") val isNewDevice: Boolean,
    @SerializedName("active_devices_count") val activeDevicesCount: Int,
    @SerializedName("location_id") val locationId: String?
)

// ErrorResponse.kt
data class ErrorResponse(
    val success: Boolean? = null,
    val error: String? = null,
    val message: String? = null,
    @SerializedName("user_exists") val userExists: Boolean? = null
)

// Usage in your ViewModel or Repository
suspend fun signup(
    name: String,
    phoneNumber: String,
    state: String? = null,
    district: String? = null,
    cityVillage: String? = null
): Result<SignupResponse> {
    return try {
        val request = SignupRequest(
            name = name,
            phoneNumber = phoneNumber,
            state = state,
            district = district,
            cityVillage = cityVillage,
            deviceId = getDeviceId(),
            deviceInfo = getDeviceInfo()
        )
        
        val response = apiClient.post<SignupResponse>("/auth/signup", request)
        
        if (response.isSuccessful && response.body()?.success == true) {
            Result.success(response.body()!!)
        } else {
            // Parse error response
            val errorBody = response.errorBody()?.string()
            val errorResponse = Gson().fromJson(errorBody, ErrorResponse::class.java)
            Result.failure(Exception(errorResponse.message ?: errorResponse.error ?: "Signup failed"))
        }
    } catch (e: Exception) {
        Result.failure(e)
    }
}
```

## Common Issues and Fixes

### Issue 1: Field Name Mismatch
**Problem**: API uses `snake_case` but Kotlin uses `camelCase`
**Fix**: Use `@SerializedName` annotation or configure Retrofit with field naming policy

### Issue 2: Nullable Fields
**Problem**: Some fields might be null (like `location_id`)
**Fix**: Mark optional fields as nullable: `val locationId: String?`

### Issue 3: Nested Objects
**Problem**: `user` is a nested object
**Fix**: Create separate data class for `SignupUser`

### Issue 4: Type Mismatch
**Problem**: API returns `"success": true` but expecting different type
**Fix**: Use `Boolean` type: `val success: Boolean`

## Testing the Response

Add logging to see the actual response:

```kotlin
val response = apiClient.post("/auth/signup", request)
Log.d("Signup", "Response code: ${response.code()}")
Log.d("Signup", "Response body: ${response.body()?.string()}")
```

This will help you see exactly what the API is returning and adjust your data class accordingly.


