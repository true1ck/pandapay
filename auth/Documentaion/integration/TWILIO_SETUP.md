# Twilio SMS Setup

## Required Twilio Variables

Add these to your `.env` file:

```env
# Twilio SMS Configuration
TWILIO_ACCOUNT_SID=your-account-sid-here
TWILIO_AUTH_TOKEN=your-auth-token-here

# Use EITHER Messaging Service (recommended) OR From Number
TWILIO_MESSAGING_SERVICE_SID=your-messaging-service-sid
# OR
TWILIO_FROM_NUMBER=+1234567890
```

## Twilio Setup Options

### Option 1: Using Messaging Service (Recommended)
```env
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_MESSAGING_SERVICE_SID=MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Option 2: Using Phone Number
```env
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_FROM_NUMBER=+1234567890
```

## How to Get Twilio Credentials

1. Sign up at https://www.twilio.com/
2. Get your Account SID and Auth Token from the Twilio Console Dashboard
3. For Messaging Service:
   - Go to Messaging > Services in Twilio Console
   - Create or select a Messaging Service
   - Copy the Service SID (starts with MG)
4. For Phone Number:
   - Get a Twilio phone number from Phone Numbers section
   - Format: +1234567890 (E.164 format)

## Important Notes

- Use **Messaging Service** (Option 1) if you have one - it's recommended
- Use **Phone Number** (Option 2) if you don't have a Messaging Service
- You only need **ONE** of: `TWILIO_MESSAGING_SERVICE_SID` or `TWILIO_FROM_NUMBER`
- The phone number must be in E.164 format: `+[country code][number]`
- Example: `+919876543210` (India)

## Testing

After adding Twilio credentials:
1. Restart your server: `npm run dev`
2. Request OTP: `POST /auth/request-otp`
3. Check server logs - should see: `✅ Twilio SMS sent, SID: SMxxxxx`
4. User receives SMS with OTP code

---

## Troubleshooting Common Errors

### Error: "Short Code" Error

**Error Message:**
```
❌ Failed to send SMS via Twilio: 'To' number cannot be a Short Code: +9174114XXXX
```

**Cause:**
- You're trying to send SMS to a short code (5-6 digit number)
- Twilio doesn't allow sending to short codes
- Often happens with test numbers or invalid phone numbers

**Solution:**
- Use valid full-length phone numbers in E.164 format (e.g., `+919876543210`)
- Short codes are typically 5-6 digits total
- The service now validates phone numbers and rejects short codes

**Fallback:**
- OTP is automatically logged to console: `📱 DEBUG OTP (fallback): +91741147986 Code: 153502`
- Check server logs for the OTP code during development/testing

---

### Error: "Unverified Number" Error (Trial Account)

**Error Message:**
```
❌ Failed to send SMS via Twilio: The number +91741114XXXX is unverified. Trial accounts cannot send messages to unverified numbers
```

**Cause:**
- You're using a **Twilio Trial Account**
- Trial accounts can only send SMS to verified phone numbers
- This is a security feature to prevent abuse

**Solutions:**

**Option 1: Verify the Phone Number (Free)**
1. Go to [Twilio Console - Verified Numbers](https://console.twilio.com/us1/develop/phone-numbers/manage/verified)
2. Click "Add a new number"
3. Enter the phone number and verify via SMS/call
4. You can verify up to 10 numbers on a trial account

**Option 2: Upgrade to Paid Account (Recommended for Production)**
1. Add payment method in Twilio Console
2. Upgrade your account (minimum $20 credit required)
3. Once upgraded, you can send SMS to any valid phone number
4. Pay only for messages sent (per SMS pricing)

**Option 3: Use Console Logs (Development Only)**
- For testing/development, check server console logs
- OTP codes are logged: `📱 DEBUG OTP (fallback): +919876543210 Code: 1234`
- This allows testing without SMS delivery

---

### Error: "Failed to send OTP"

**Error Message:**
```
❌ Failed to send SMS via Twilio: [any error]
```

**General Troubleshooting:**

1. **Check Twilio Credentials:**
   - Verify `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN` in `.env`
   - Credentials should start with `AC` and be valid

2. **Check From Number/Service:**
   - Ensure `TWILIO_FROM_NUMBER` or `TWILIO_MESSAGING_SERVICE_SID` is set
   - Phone number must be in E.164 format: `+1234567890`

3. **Check Account Status:**
   - Login to [Twilio Console](https://console.twilio.com/)
   - Verify account is active (not suspended)
   - Check if you have credits/balance

4. **Check Phone Number Format:**
   - Must be E.164 format: `+[country code][number]`
   - Example: `+919876543210` (India), `+1234567890` (US)
   - No spaces or special characters

5. **Development Fallback:**
   - If SMS fails, OTP is always logged to console
   - Check server logs: `📱 DEBUG OTP (fallback): [phone] Code: [otp]`

---

## Understanding the Logs

**✅ Success:**
```
✅ Twilio SMS sent, SID: SMa7e2f23b3bdb05be1a275f43b71b2209
```
- SMS was successfully sent via Twilio
- User should receive SMS with OTP

**❌ Failure (with fallback):**
```
❌ Failed to send SMS via Twilio: [error message]
📱 DEBUG OTP (fallback): +919876543210 Code: 1234
```
- SMS sending failed, but OTP was generated
- OTP code is logged to console for development/testing
- User can still verify using the OTP code from logs

**⚠️ Warning (Twilio not configured):**
```
⚠️ Twilio credentials are not set. SMS sending will be disabled. OTP will be logged to console.
📱 DEBUG OTP (Twilio not configured): +919876543210 Code: 1234
```
- Twilio credentials missing in `.env`
- Service still works, but OTPs only appear in logs
- Add Twilio credentials to enable SMS delivery

---

## Best Practices

1. **Development:**
   - Use console logs for testing
   - Verify test numbers in Twilio Console

2. **Production:**
   - Upgrade to paid Twilio account
   - Use Messaging Service (recommended)
   - Monitor SMS delivery rates
   - Implement proper error handling in frontend

3. **Security:**
   - Never log OTPs in production
   - Use environment variables for credentials
   - Rotate Twilio credentials periodically


