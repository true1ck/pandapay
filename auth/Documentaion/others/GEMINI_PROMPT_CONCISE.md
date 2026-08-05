# Gemini Prompt: JWT Auth with Refresh Token Rotation - Copy This to Gemini

---

I need you to implement secure JWT authentication with rotating refresh tokens in my Android Kotlin app for persistent login. The auth service runs at `http://localhost:3000`.

## API Endpoints

**Base URL:** `http://localhost:3000`

1. **Request OTP:** `POST /auth/request-otp` → Body: `{ "phone_number": "+919876543210" }`
2. **Verify OTP:** `POST /auth/verify-otp` → Returns: `{ "access_token", "refresh_token", "user", ... }`
3. **Refresh Token:** `POST /auth/refresh` → Body: `{ "refresh_token": "..." }` → Returns new access_token AND new refresh_token (ROTATES)
4. **Get User:** `GET /users/me` → Header: `Authorization: Bearer <access_token>` → Returns user details with location
5. **Logout:** `POST /auth/logout` → Body: `{ "refresh_token": "..." }`

## Critical Requirements

**Token Storage (SECURITY):**
- ✅ Use `EncryptedSharedPreferences` (androidx.security:security-crypto)
- ❌ NEVER use plain SharedPreferences
- ❌ NEVER log tokens in console/logs
- ✅ Clear tokens on logout

**Token Management:**
- Access token: 15 min lifetime, used in `Authorization: Bearer <token>` header
- Refresh token: 7 days lifetime, rotates on each refresh (SAVE NEW TOKEN)
- Auto-refresh on 401: Get new tokens, retry request, if refresh fails → logout

**Success/Home Screen:**
- After login → Navigate to Success screen
- Fetch user details from `GET /users/me` with access_token
- Display: name, phone_number, user_type, last_login_at, location
- Show logout button with confirmation
- Handle loading/error states

**Persistent Login:**
- On app launch: Check stored tokens → If valid, auto-login to Success screen
- If tokens expired: Try refresh → If fails, show login screen
- User should stay logged in until logout or 7 days of inactivity

## Implementation Tasks

1. **TokenManager** - Secure storage using EncryptedSharedPreferences
2. **AuthApiClient** - With auto-refresh interceptor (handles 401, refreshes, retries)
3. **Success/Home Activity/Fragment** - Displays user details from `/users/me`
4. **Logout** - Calls logout API, clears tokens, navigates to login
5. **Auto-login** - Check tokens on app launch

## Code Requirements

- Use Kotlinx Serialization for JSON
- Use Ktor or Retrofit for HTTP client
- Use MVVM architecture
- Use Kotlin Coroutines
- Handle all errors gracefully
- Show loading indicators

## Security Checklist

- ✅ Tokens only in EncryptedSharedPreferences
- ✅ Auto-refresh on token expiration
- ✅ Token rotation handled (save new refresh_token)
- ✅ No tokens in logs
- ✅ Clear tokens on logout

## Dependencies

```kotlin
implementation("io.ktor:ktor-client-android:2.3.5")
implementation("io.ktor:ktor-client-content-negotiation:2.3.5")
implementation("io.ktor:ktor-serialization-kotlinx-json:2.3.5")
implementation("androidx.security:security-crypto:1.1.0-alpha06")
implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
```

**IMPORTANT:** Refresh tokens ROTATE - always save the new refresh_token from refresh response. Reference: See `how_to_use_Auth.md` in the project for complete API documentation.

---










