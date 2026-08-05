# Signup API Endpoint

## POST /auth/signup

Creates a new user account with name, phone number, and optional location information.

### Request Body

```json
{
  "name": "John Doe",                    // Required: User's name (string, max 100 chars)
  "phone_number": "+919876543210",      // Required: Phone number in E.164 format
  "state": "Maharashtra",               // Optional: State name (string, max 100 chars)
  "district": "Mumbai",                 // Optional: District name (string, max 100 chars)
  "city_village": "Andheri",            // Optional: City/Village name (string, max 150 chars)
  "device_id": "device-123",             // Optional: Device identifier
  "device_info": {                      // Optional: Device information
    "platform": "android",
    "model": "Samsung Galaxy S21",
    "os_version": "Android 13",
    "app_version": "1.0.0",
    "language_code": "en",
    "timezone": "Asia/Kolkata"
  }
}
```

### Success Response (201 Created)

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
  "access_token": "jwt-access-token",
  "refresh_token": "jwt-refresh-token",
  "needs_profile": true,
  "is_new_account": true,
  "is_new_device": true,
  "active_devices_count": 1,
  "location_id": "uuid-of-location"  // null if no location provided
}
```

### Error Responses

#### 400 Bad Request - Validation Error
```json
{
  "error": "name is required"
}
```

#### 409 Conflict - User Already Exists
```json
{
  "success": false,
  "message": "User with this phone number already exists. Please sign in instead.",
  "user_exists": true
}
```

#### 403 Forbidden - IP Blocked
```json
{
  "success": false,
  "message": "Access denied from this location."
}
```

#### 500 Internal Server Error
```json
{
  "success": false,
  "message": "Internal server error"
}
```

### Features

1. **User Existence Check**: Automatically checks if a user with the phone number already exists
2. **Phone Number Encryption**: Phone numbers are encrypted before storing in database
3. **Location Creation**: If state/district/city_village provided, creates a location entry
4. **Token Issuance**: Automatically issues access and refresh tokens
5. **Device Tracking**: Records device information for security
6. **Audit Logging**: Logs signup events for security monitoring

### Example Usage

#### cURL
```bash
curl -X POST http://localhost:3000/auth/signup \
  -H "Content-Type: application/json" \
  -d '{
    "name": "John Doe",
    "phone_number": "+919876543210",
    "state": "Maharashtra",
    "district": "Mumbai",
    "city_village": "Andheri",
    "device_id": "android-device-123",
    "device_info": {
      "platform": "android",
      "model": "Samsung Galaxy S21",
      "os_version": "Android 13"
    }
  }'
```

#### JavaScript/TypeScript
```javascript
const response = await fetch('/auth/signup', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    name: 'John Doe',
    phone_number: '+919876543210',
    state: 'Maharashtra',
    district: 'Mumbai',
    city_village: 'Andheri',
    device_id: 'android-device-123',
    device_info: {
      platform: 'android',
      model: 'Samsung Galaxy S21',
      os_version: 'Android 13'
    }
  })
});

const data = await response.json();
if (data.success) {
  // Store tokens
  localStorage.setItem('access_token', data.access_token);
  localStorage.setItem('refresh_token', data.refresh_token);
}
```

#### Kotlin/Android
```kotlin
data class SignupRequest(
    val name: String,
    val phone_number: String,
    val state: String? = null,
    val district: String? = null,
    val city_village: String? = null,
    val device_id: String? = null,
    val device_info: Map<String, String?>? = null
)

data class SignupResponse(
    val success: Boolean,
    val user: User,
    val access_token: String,
    val refresh_token: String,
    val needs_profile: Boolean,
    val is_new_account: Boolean,
    val is_new_device: Boolean,
    val active_devices_count: Int,
    val location_id: String?
)

// Usage
val request = SignupRequest(
    name = "John Doe",
    phone_number = "+919876543210",
    state = "Maharashtra",
    district = "Mumbai",
    city_village = "Andheri",
    device_id = getDeviceId(),
    device_info = mapOf(
        "platform" to "android",
        "model" to Build.MODEL,
        "os_version" to Build.VERSION.RELEASE
    )
)

val response = apiClient.post<SignupResponse>("/auth/signup", request)
```

### Notes

- Phone number must be in E.164 format (e.g., `+919876543210`)
- If phone number is 10 digits without `+`, it will be normalized to `+91` prefix
- Location fields are optional - user can be created without location
- If user already exists, returns 409 Conflict with `user_exists: true`
- All phone numbers are encrypted in the database for security
- Country code is automatically extracted from phone number

