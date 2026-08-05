# Environment Variables Setup

## Required Variables (MUST provide)

These are **mandatory** - the service will not start without them:

```env
DATABASE_URL=postgres://username:password@localhost:5432/database_name
JWT_ACCESS_SECRET=your-secret-here-minimum-32-characters
JWT_REFRESH_SECRET=your-secret-here-minimum-32-characters
```

### How to generate JWT secrets:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Run this twice to get two different secrets.

---

## Optional Variables (Can skip)

### Twilio SMS Configuration

**You DO NOT need to provide Twilio credentials** - the service will work without them!

If Twilio is **NOT configured**:
- ✅ Service starts normally
- ✅ OTP codes are logged to console for testing
- ⚠️ SMS will not be sent (OTP shown in server logs)

If Twilio **IS configured**:
- ✅ OTP codes sent via SMS automatically

```env
# Twilio (Optional - only if you want SMS delivery)
TWILIO_ACCOUNT_SID=your-twilio-account-sid
TWILIO_AUTH_TOKEN=your-twilio-auth-token
TWILIO_MESSAGING_SERVICE_SID=your-messaging-service-sid
# OR
TWILIO_FROM_NUMBER=+1234567890
```

### Other Optional Variables

```env
PORT=3000                                    # Server port (default: 3000)
NODE_ENV=development                         # Environment (development/production)
CORS_ALLOWED_ORIGINS=                        # Comma-separated origins (required in production)
JWT_ACCESS_TTL=15m                          # Access token expiry (default: 15m)
JWT_REFRESH_TTL=7d                          # Refresh token expiry (default: 7d)
REFRESH_MAX_IDLE_MINUTES=4320               # Refresh token inactivity timeout (default: 3 days)
OTP_MAX_ATTEMPTS=5                          # Max OTP verification attempts (default: 5)
```

---

## Quick Setup

1. **Copy the example file:**
   ```bash
   cp .env.example .env
   ```

2. **Fill in REQUIRED variables only:**
   ```env
   DATABASE_URL=postgres://postgres:password123@localhost:5433/farmmarket
   JWT_ACCESS_SECRET=<generate-with-node-command>
   JWT_REFRESH_SECRET=<generate-with-node-command>
   ```

3. **Skip Twilio** (optional - for development, OTP will show in console)

4. **Start the service:**
   ```bash
   npm run dev
   ```

---

## Testing Without Twilio

When Twilio is not configured:
- Request OTP: `POST /auth/request-otp`
- Check server console - OTP code will be logged: `📱 DEBUG OTP: +919876543210 Code: 123456`
- Use that code to verify: `POST /auth/verify-otp`

This is perfect for local development!











