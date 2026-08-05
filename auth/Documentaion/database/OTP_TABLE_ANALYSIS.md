# OTP Tables Analysis - What Your Code Actually Does

## Summary: **NO `user_id` in OTP Tables - This is CORRECT**

Your code uses **phone number only** for OTP tables. Users are created **AFTER** OTP verification.

---

## Database Tables

### 1. `otp_requests` Table (in `init.sql` lines 94-109)
**Status: ❌ NOT USED BY YOUR CODE**

```sql
CREATE TABLE IF NOT EXISTS otp_requests (
    id            UUID PRIMARY KEY,
    phone_number  VARCHAR(20) NOT NULL,  -- NO user_id!
    otp_hash      VARCHAR(255) NOT NULL,
    expires_at    TIMESTAMPTZ NOT NULL,
    consumed_at   TIMESTAMPTZ,           -- Extra field for tracking consumption
    attempt_count INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Note:** This table exists in your database schema but is **never referenced in your code**.

---

### 2. `otp_codes` Table (ACTUALLY USED)
**Status: ✅ ACTIVELY USED BY YOUR CODE**

#### Database Schema (`init.sql` lines 115-122):
```sql
CREATE TABLE IF NOT EXISTS otp_codes (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number VARCHAR(20) NOT NULL,  -- NO user_id!
    otp_hash     VARCHAR(255) NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    attempt_count INT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

#### Code Definition (`src/services/otpService.js` lines 34-41):
```javascript
CREATE TABLE IF NOT EXISTS otp_codes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone_number VARCHAR(20) NOT NULL,  // ← NO user_id!
  otp_hash VARCHAR(255) NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempt_count INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Both schemas match - NO `user_id` column!**

---

## How Your Code Uses `otp_codes`

### Step 1: Request OTP (`/auth/request-otp`)

**Location:** `src/routes/authRoutes.js` line 189
```javascript
const { code } = await createOtp(normalizedPhone);
```

**Function:** `src/services/otpService.js` lines 82-117
```javascript
async function createOtp(phoneNumber) {
  await ensureOtpCodesTable();
  const code = generateOtpCode();
  const expiresAt = new Date(Date.now() + OTP_EXPIRY_MS);
  const otpHash = await bcrypt.hash(code, 10);

  // Encrypt phone number before storing
  const encryptedPhone = encryptPhoneNumber(phoneNumber);

  // Delete any existing OTPs for this phone number
  await db.query(
    'DELETE FROM otp_codes WHERE phone_number = $1 OR phone_number = $2',
    [encryptedPhone, phoneNumber]
  );

  // ← INSERT: Only phone_number, NO user_id!
  await db.query(
    `INSERT INTO otp_codes (phone_number, otp_hash, expires_at, attempt_count)
     VALUES ($1, $2, $3, 0)`,
    [encryptedPhone, otpHash, expiresAt]  // ← NO user_id here!
  );

  return { code };
}
```

**What happens:**
- ✅ User requests OTP with **phone number only**
- ✅ OTP stored in `otp_codes` with **phone_number only**
- ❌ **NO user_id** because user doesn't exist yet!

---

### Step 2: Verify OTP (`/auth/verify-otp`)

#### Part A: Verify OTP Code
**Location:** `src/routes/authRoutes.js` line 267
```javascript
const result = await verifyOtp(normalizedPhone, code);
```

**Function:** `src/services/otpService.js` lines 131-220
```javascript
async function verifyOtp(phoneNumber, code) {
  await ensureOtpCodesTable();
  
  const encryptedPhone = encryptPhoneNumber(phoneNumber);
  
  // ← SELECT: Lookup by phone_number only!
  const result = await db.query(
    `SELECT id, otp_hash, expires_at, attempt_count, phone_number
     FROM otp_codes
     WHERE phone_number = $1 OR phone_number = $2  // ← NO user_id in WHERE clause!
     ORDER BY created_at DESC
     LIMIT 1`,
    [encryptedPhone, phoneNumber]
  );

  // ... verification logic ...
  
  // ← DELETE: Remove OTP after verification
  await db.query('DELETE FROM otp_codes WHERE id = $1', [otpRecord.id]);

  return { ok: true };
}
```

**What happens:**
- ✅ OTP verified using **phone_number only**
- ✅ OTP deleted from `otp_codes` table
- ❌ **Still NO user_id** at this point!

---

#### Part B: Create/Find User (AFTER OTP Verification)
**Location:** `src/routes/authRoutes.js` lines 310-335
```javascript
// ← This happens AFTER OTP verification succeeds!

// find or create user
const encryptedPhone = encryptPhoneNumber(normalizedPhone);
const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);

let user;
const found = await db.query(
  `SELECT id, phone_number, name, role, NULL::user_type_enum as user_type, 
          COALESCE(token_version, 1) as token_version
   FROM users
   WHERE phone_number = $1 OR phone_number = $2`,
  phoneSearchParams
);

if (found.rows.length === 0) {
  // ← CREATE USER HERE (after OTP verified!)
  const inserted = await db.query(
    `INSERT INTO users (phone_number)  // ← Only phone_number, user gets auto-generated UUID id
     VALUES ($1)
     RETURNING id, phone_number, name, role, NULL::user_type_enum as user_type, 
               COALESCE(token_version, 1) as token_version`,
    [encryptedPhone]
  );
  user = inserted.rows[0];  // ← user.id is created HERE!
} else {
  user = found.rows[0];  // ← Existing user found
}

// Now user.id exists!
```

**What happens:**
- ✅ **AFTER** OTP verification succeeds
- ✅ User is **found or created** based on phone_number
- ✅ `user.id` (UUID) is **assigned at this point**
- ✅ This is when user_id first exists!

---

## Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1: Request OTP                                        │
│  POST /auth/request-otp                                     │
│  Body: { phone_number: "+919876543210" }                    │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  INSERT INTO otp_codes                                      │
│  (phone_number, otp_hash, expires_at, attempt_count)       │
│  VALUES ('+919876543210', 'hash...', '2024-...', 0)        │
│                                                             │
│  ❌ NO user_id - User doesn't exist yet!                   │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 2: Verify OTP                                         │
│  POST /auth/verify-otp                                      │
│  Body: { phone_number: "+919876543210", code: "123456" }   │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  SELECT FROM otp_codes                                      │
│  WHERE phone_number = '+919876543210'                       │
│                                                             │
│  ❌ NO user_id in query - phone_number only!                │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼ (if OTP valid)
┌─────────────────────────────────────────────────────────────┐
│  DELETE FROM otp_codes WHERE id = ...                       │
│  (OTP consumed)                                             │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 3: Create/Find User                                   │
│  (AFTER OTP verification succeeds)                          │
│                                                             │
│  SELECT FROM users WHERE phone_number = '+919876543210'     │
│                                                             │
│  If NOT found:                                              │
│    INSERT INTO users (phone_number)                         │
│    VALUES ('+919876543210')                                 │
│    RETURNING id  ← user.id CREATED HERE!                    │
│                                                             │
│  ✅ user.id EXISTS NOW!                                     │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 4: Create Session                                     │
│                                                             │
│  INSERT INTO refresh_tokens                                 │
│  (user_id, token_hash, device_id, ...)                      │
│  VALUES (user.id, ...)  ← user_id used here!               │
│                                                             │
│  INSERT INTO user_devices                                   │
│  (user_id, device_identifier, ...)                          │
│  VALUES (user.id, ...)  ← user_id used here!               │
└─────────────────────────────────────────────────────────────┘
```

---

## Why NO `user_id` in OTP Tables?

### ✅ Current Design (CORRECT):

1. **User doesn't exist when OTP is requested**
   - OTP can be requested for phone numbers that don't have accounts yet
   - User is created **after** successful OTP verification

2. **Phone number is the identifier**
   - Phone number is UNIQUE in `users` table
   - Phone number links OTP → User
   - No need for user_id in OTP table

3. **Supports both registration and login**
   - New users: OTP → Create user
   - Existing users: OTP → Find user
   - Same flow works for both!

### ❌ Alternative (Would Be Wrong):

If you added `user_id` to `otp_codes`:
- ❌ Can't request OTP for new users (user_id doesn't exist)
- ❌ Would need to create user before OTP (defeats purpose of verification)
- ❌ Complicates the flow unnecessarily

---

## Summary Table

| Table | Has `user_id`? | When Used | Purpose |
|-------|---------------|-----------|---------|
| `otp_codes` | ❌ **NO** | Request/Verify OTP | Store OTP codes before user exists |
| `otp_requests` | ❌ **NO** | ❌ **NOT USED** | Legacy table (ignore it) |
| `users` | ✅ **YES** (primary key) | After OTP verification | Store user accounts |
| `refresh_tokens` | ✅ **YES** | After OTP verification | Store sessions (needs user_id) |
| `user_devices` | ✅ **YES** | After OTP verification | Track devices (needs user_id) |

---

## Answer to Your Question

**Q: Should `otp_code` and `otp_req` include user_id?**

**A: ❌ NO** - Your current code is **correct as-is**:

1. **`otp_codes`** - Does NOT have `user_id` ✅ (correct)
2. **`otp_requests`** - Does NOT have `user_id`, but also **NOT USED** by your code

**Q: Are we going to create a user ID before and assign it, or only use phone number?**

**A:** Your code uses **phone number only** for OTP, then creates user_id **AFTER** OTP verification:
- OTP request/verify: Uses **phone_number only**
- User creation: Happens **AFTER** OTP verification succeeds
- User_id assignment: Happens when user is created/found in `users` table

This is the **standard and secure** pattern for phone-based authentication! ✅



