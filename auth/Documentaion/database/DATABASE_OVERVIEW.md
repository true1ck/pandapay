# Database Overview - Urban Link Authentication Service

## Database Purpose

Your PostgreSQL database is the **central data store** for the **Urban Link Authentication Service** that handles:
1. **User Authentication** (Phone-based OTP login)
2. **Session Management** (Multi-device support with refresh tokens)
3. **Security & Audit Logging**
4. **Device Fingerprinting & Risk Detection**

> **Note**: This auth service shares the database with the Urban Link Backend Service. 
> Auth service owns authentication tables; Backend service owns business tables (leads, wallets, etc.)

---

## Architecture: Dual Service Model

```
┌─────────────────────────────────────────────────────────────────┐
│                        PostgreSQL Database                       │
│  ┌──────────────────────┐    ┌────────────────────────────────┐ │
│  │   AUTH SERVICE ZONE  │    │    BACKEND SERVICE ZONE        │ │
│  │  ─────────────────── │    │  ───────────────────────────── │ │
│  │  • users (shared)    │    │  • leads                       │ │
│  │  • otp_codes         │◄───┤  • properties                  │ │
│  │  • refresh_tokens    │    │  • wallets                     │ │
│  │  • user_devices      │    │  • transactions                │ │
│  │  • auth_audit        │    │  • referrals                   │ │
│  │                      │    │  • partner_tiers               │ │
│  │                      │    │  • user_trust_scores           │ │
│  │                      │    │  • notifications               │ │
│  └──────────────────────┘    └────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Table Categories

### 🔐 **AUTHENTICATION TABLES** (Auth Service Owned)

#### 1. `users` - User Accounts (SHARED)
**Purpose:** Store user account information
**Key Fields:**
- `id` (UUID) - Primary key
- `phone_number` (UNIQUE) - Encrypted phone (login identifier)
- `name` - User's name (can be NULL until profile completed)
- `role` - System role: 'user', 'admin', 'moderator'
- `partner_tier_id` - Urban Link partner tier (1-5)
- `referral_code` - Unique referral code (auto-generated)
- `token_version` - Incremented on logout-all to invalidate tokens
- `is_phone_verified` - TRUE after OTP verification
- `last_login_at` - Tracks last login time

**Auth Service Usage:**
- Created **AFTER** OTP verification (find-or-create pattern)
- Phone number is encrypted before storage
- One phone number = One account (UNIQUE constraint)
- Updates `last_login_at` on each login

**Backend Service Usage:**
- Reads user info for authorization
- Updates `partner_tier_id` based on lead count
- Updates `total_leads_submitted`, `total_earnings`

#### 2. `otp_codes` - OTP Storage
**Purpose:** Store OTP codes for phone verification
**Key Fields:**
- `id` (UUID)
- `phone_number` - Encrypted phone requesting OTP
- `otp_hash` - Hashed OTP code (bcrypt)
- `expires_at` - OTP expiry (2 minutes default)
- `attempt_count` - Failed verification attempts

**Current Usage:**
- Created when `/auth/request-otp` is called
- Deleted after successful verification or expiry
- Used for OTP verification in `/auth/verify-otp`

#### 3. `refresh_tokens` - Session Management
**Purpose:** Store refresh tokens for JWT authentication
**Key Fields:**
- `id` (UUID)
- `user_id` - Links to users table
- `device_id` - Device identifier from client
- `token_id` (UNIQUE) - UUID identifier for token
- `token_hash` - Hashed refresh token (bcrypt)
- `expires_at` - Token expiry (7 days default)
- `revoked_at` - NULL = active, timestamp = revoked
- `rotated_from_id` - Links to previous token (rotation tracking)
- `reuse_detected_at` - Detects token theft/reuse

**Current Usage:**
- Created during OTP verification
- Rotated on each refresh (old token revoked, new one created)
- Tracks which device each token belongs to
- Supports multi-device logins (one token per device)

#### 4. `user_devices` - Device Tracking
**Purpose:** Track user's logged-in devices
**Key Fields:**
- `id` (UUID)
- `user_id` - Links to users
- `device_identifier` - Unique device ID
- `device_platform` - 'android', 'ios'
- `device_model`, `os_version`, `app_version`
- `fcm_token` - Firebase Cloud Messaging token
- `is_emulator`, `is_rooted` - Risk flags
- `is_active` - Whether device session is active
- `total_leads_from_device` - Lead count per device (fraud detection)
- UNIQUE(`user_id`, `device_identifier`) - One record per user-device pair

**Auth Service Usage:**
- Created/updated during OTP verification
- Tracks all devices a user is logged in from
- Used for device management (view/revoke devices)

**Backend Service Usage:**
- Reads for fraud detection (leads per device)
- Updates `total_leads_from_device` counter

#### 5. `auth_audit` - Security Audit Log
**Purpose:** Log all authentication events for security monitoring
**Key Fields:**
- `id` (UUID)
- `user_id` - NULL if user doesn't exist yet (e.g., failed login)
- `action` - 'otp_request', 'otp_verify', 'token_refresh', 'logout', etc.
- `status` - 'success', 'failed', 'error'
- `risk_level` - 'INFO', 'SUSPICIOUS', 'HIGH_RISK'
- `ip_address`, `user_agent`, `device_id`
- `meta` (JSONB) - Additional metadata (errors, risk scores, etc.)

**Current Usage:**
- Logs every authentication event
- Used for security monitoring
- Used for risk scoring and anomaly detection
- Tracks suspicious activities (enumeration, brute force, etc.)

---

### 💰 **URBAN LINK TABLES** (Backend Service Owned)

These tables are created by the shared database but managed by the Backend Service:

#### 6. `partner_tiers` - Reward Tiers
**Purpose:** Define partner levels and their benefits
**Key Fields:**
- `id` (SERIAL) - 1=Starter, 2=Bronze, 3=Silver, 4=Gold, 5=Elite
- `name` - Tier name
- `min_verified_leads` - Leads required to reach tier
- `reward_per_lead` - Reward amount per verified lead
- `daily_lead_cap` - Max leads per day at this tier

#### 7. `wallets` - User Wallets
**Purpose:** Track user earnings and withdrawals
**Key Fields:**
- `user_id` - Links to users (1:1 relationship)
- `balance` - Current available balance
- `lifetime_earnings` - Total earnings ever
- `pending_withdrawal` - Amount being processed
- `upi_id`, `bank_account_number` - Payout details

**Auto-Created:** Trigger creates wallet when user signs up

#### 8. `user_trust_scores` - Fraud Prevention
**Purpose:** Track user trust and fraud risk
**Key Fields:**
- `user_id` - Links to users (1:1 relationship)
- `trust_score` - 0-100 score
- `risk_level` - 'LOW', 'MEDIUM', 'HIGH', 'BLOCKED'
- `rejected_leads_count`, `duplicate_photo_count`, `gps_mismatch_count`

**Auto-Created:** Trigger creates trust score when user signs up

#### 9. `referrals` - Referral Program
**Purpose:** Track referral relationships and rewards
**Key Fields:**
- `referrer_user_id` - Who referred
- `referred_user_id` - Who was referred
- `status` - 'PENDING', 'QUALIFIED', 'REWARDED'

---

## Key Relationships & Constraints

### Foreign Key Relationships:
```
users (1) ──< (many) user_devices
users (1) ──< (many) refresh_tokens
users (1) ──1 (1) wallets           [Auto-created on signup]
users (1) ──1 (1) user_trust_scores [Auto-created on signup]
users (1) ──< (many) referrals (as referrer)
users (1) ──< (many) referrals (as referred)
users (1) ──< (many) leads          [Backend Service]
```

### Database Triggers (Auto-Actions):
- `generate_referral_code_trigger` - Creates unique referral code on user INSERT
- `create_wallet_trigger` - Creates wallet row on user INSERT
- `create_trust_score_trigger` - Creates trust score row on user INSERT

---

## Current Data Flow

### Authentication Flow:
```
1. User requests OTP
   └─> INSERT into `otp_codes` (phone_number, otp_hash, expires_at)

2. User verifies OTP
   ├─> Verify OTP from `otp_codes` table
   ├─> DELETE OTP from `otp_codes`
   ├─> FIND or CREATE user in `users` table
   │   └─> TRIGGERS auto-create wallet, trust_score, referral_code
   ├─> INSERT/UPDATE `user_devices` table
   ├─> INSERT into `refresh_tokens` table
   └─> INSERT into `auth_audit` (log event)

3. User refreshes token
   ├─> Verify refresh token from `refresh_tokens` table
   ├─> ROTATE token (revoke old, create new)
   └─> INSERT into `auth_audit` (log event)
```

### JWT Token Contents:
```json
{
  "sub": "user-uuid",
  "phone_number": "+919876543210",
  "role": "user",
  "partner_tier_id": 1,
  "token_version": 1,
  "device_id": "device-identifier",
  "is_guest": false,
  "high_assurance": true,
  "iat": 1234567890,
  "exp": 1234567890
}
```

---

## Database Features

### 1. **Automatic Timestamps**
- All tables have `created_at` and `updated_at`
- `updated_at` automatically updated via database triggers

### 2. **UUID Primary Keys**
- All tables use UUIDs (not auto-increment integers)
- Generated via PostgreSQL `uuid-ossp` extension

### 3. **Auto-Created Records**
- Wallet created automatically when user signs up
- Trust score created automatically when user signs up
- Referral code generated automatically when user signs up

### 4. **Indexes**
- Indexes on foreign keys for fast joins
- Indexes on frequently queried fields (phone_number, expires_at, status)
- Partial indexes for performance (e.g., active devices only)

### 5. **Data Integrity**
- CHECK constraints (e.g., trust_score BETWEEN 0 AND 100)
- UNIQUE constraints (phone_number, user+device pairs)
- Foreign key constraints with appropriate CASCADE/RESTRICT behaviors

---

## What's NOT in Auth Service Database

1. **Access Tokens (JWT)** - Stored only on client, validated via signature
2. **Rate Limiting Counters** - Stored in Redis (not PostgreSQL)
3. **OTP Codes (Plain)** - Only hashed versions stored
4. **SMS Messages** - Sent via Twilio, not stored
5. **Lead Details** - Handled by Backend Service
6. **Wallet Transactions** - Handled by Backend Service

---

## Security Features

### ✅ Phone Number Encryption
- Phone numbers are **encrypted at application level**
- Database stores encrypted values, not plaintext
- Encryption handled by `src/utils/fieldEncryption.js`

### ✅ Multi-Device Support
- Users can log in from multiple devices simultaneously
- Each device has its own refresh token
- Devices can be managed (viewed/revoked) via API

### ✅ Token Security
- OTP attempt tracking (prevents brute force)
- Token rotation (prevents token reuse)
- Audit logging (tracks all auth events)
- Risk scoring (detects suspicious activity)

### ✅ Global Logout
- `token_version` field in users table
- Incrementing version invalidates all existing tokens
- `/users/me/logout-all-devices` endpoint

---

## Summary

The database is a **well-structured PostgreSQL database** that:
- ✅ Handles phone-based authentication securely
- ✅ Supports Urban Link partner tiers and referrals
- ✅ Auto-creates wallet and trust score on signup
- ✅ Tracks multi-device user sessions
- ✅ Logs security events for monitoring
- ✅ Uses proper constraints and relationships
- ✅ Shares cleanly with Backend Service
