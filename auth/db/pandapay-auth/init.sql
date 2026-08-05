-- init.sql — PandaPay Auth Service database
-- Adapted from PandaPal_Auth_Service (FarmMarket auth); farm-domain tables
-- (species/breeds/locations/animals/listings/listing_images) removed —
-- this service owns identity only. PandaPay's product schema (database.sql,
-- migrations 0001-0014) references this service's `users.id` as the
-- identity FK for `profiles.id` and `admin_users.id`.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =========================
-- ENUM TYPES
-- =========================
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role_enum') THEN
        CREATE TYPE user_role_enum AS ENUM ('user','admin','moderator');
    END IF;
END $$;

-- =========================
-- users table (persistent)
-- =========================
-- phone_number/email are stored encrypted by src/utils/fieldEncryption.js —
-- widened past a plain E.164 VARCHAR(20) to hold ciphertext, and no longer
-- UNIQUE at the column level since encryption isn't deterministic here;
-- src/utils/encryptedPhoneSearch.js is what enforces lookup uniqueness.
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number    VARCHAR(255),
    email           VARCHAR(255),
    country_code    VARCHAR(10),
    name            VARCHAR(255),                  -- allow NULL until profile completed

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at   TIMESTAMPTZ,

    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    deleted         BOOLEAN NOT NULL DEFAULT FALSE,  -- soft delete; auth routes filter on this
    is_phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
    is_email_verified  BOOLEAN NOT NULL DEFAULT FALSE,
    role            user_role_enum NOT NULL DEFAULT 'user',  -- system role
    token_version   INT NOT NULL DEFAULT 1,          -- bump to invalidate all outstanding JWTs

    avatar_url      TEXT,
    language        VARCHAR(10),
    timezone        VARCHAR(50),

    CONSTRAINT chk_users_identifier CHECK (phone_number IS NOT NULL OR email IS NOT NULL)
);

-- updated_at trigger function (idempotent creation)
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_set_updated_at ON users;
CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- =========================
-- otp_requests (phone/email OTP login)
-- =========================
-- Shape matches src/services/otpService.js exactly (phone_number is stored
-- encrypted by that service, not plaintext, despite the column name).
CREATE TABLE IF NOT EXISTS otp_requests (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number  VARCHAR(255),
    email         VARCHAR(255),
    type          VARCHAR(10) NOT NULL DEFAULT 'phone' CHECK (type IN ('phone','email')),
    country_code  VARCHAR(10),
    otp_hash      VARCHAR(255) NOT NULL, -- store hashed OTP only
    expires_at    TIMESTAMPTZ NOT NULL,
    consumed_at   TIMESTAMPTZ,
    deleted       BOOLEAN NOT NULL DEFAULT FALSE,
    attempt_count INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_otp_phone_created
    ON otp_requests (phone_number, created_at);

CREATE INDEX IF NOT EXISTS idx_otp_phone_unconsumed
    ON otp_requests (phone_number)
    WHERE deleted = FALSE AND consumed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_otp_email_unconsumed
    ON otp_requests (email)
    WHERE deleted = FALSE AND consumed_at IS NULL;

-- =========================
-- otp_codes (legacy/simple OTP storage — kept for parity with source service)
-- =========================
CREATE TABLE IF NOT EXISTS otp_codes (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number VARCHAR(20) NOT NULL,
    otp_hash     VARCHAR(255) NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    attempt_count INT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_otp_codes_phone ON otp_codes (phone_number);
CREATE INDEX IF NOT EXISTS idx_otp_codes_expires ON otp_codes (expires_at);

-- =========================
-- user_devices (device info tracked when logged in)
-- =========================
CREATE TABLE IF NOT EXISTS user_devices (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    device_identifier   TEXT,                     -- Firebase installation id, vendor id, etc.

    device_platform     TEXT NOT NULL,             -- 'android' / 'ios'
    device_model        TEXT,
    os_version          TEXT,
    app_version         TEXT,
    language_code       TEXT,
    timezone            TEXT,
    fcm_token           TEXT,

    first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at        TIMESTAMPTZ,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, device_identifier)
);

DROP TRIGGER IF EXISTS trg_user_devices_set_updated_at ON user_devices;
CREATE TRIGGER trg_user_devices_set_updated_at
BEFORE UPDATE ON user_devices
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_user_devices_user ON user_devices (user_id);
CREATE INDEX IF NOT EXISTS idx_user_devices_device_identifier ON user_devices (device_identifier);
CREATE INDEX IF NOT EXISTS idx_user_devices_platform ON user_devices (device_platform);
CREATE INDEX IF NOT EXISTS idx_user_devices_last_seen ON user_devices (last_seen_at);

-- =========================
-- refresh_tokens (JWT refresh token rotation)
-- =========================
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_id            UUID NOT NULL UNIQUE,
    token_hash          VARCHAR(255) NOT NULL,  -- bcrypt hash of refresh token
    device_id           VARCHAR(255) NOT NULL,  -- device identifier from client
    user_agent          TEXT,
    ip_address          VARCHAR(45),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ NOT NULL,
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at          TIMESTAMPTZ,            -- NULL = active, set when revoked
    reuse_detected_at   TIMESTAMPTZ,
    rotated_from_id     UUID REFERENCES refresh_tokens(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_device ON refresh_tokens(user_id, device_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires ON refresh_tokens(expires_at);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_revoked ON refresh_tokens(revoked_at);

-- =========================
-- auth_audit (authentication event logging)
-- =========================
CREATE TABLE IF NOT EXISTS auth_audit (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    action          VARCHAR(100) NOT NULL,      -- 'otp_verify', 'token_refresh', 'logout', ...
    status          VARCHAR(50) NOT NULL,       -- 'success', 'failed', 'error'
    ip_address      VARCHAR(45),
    user_agent      TEXT,
    device_id       VARCHAR(255),
    meta            JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_auth_audit_user ON auth_audit(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_audit_created ON auth_audit(created_at);
CREATE INDEX IF NOT EXISTS idx_auth_audit_action ON auth_audit(action);
CREATE INDEX IF NOT EXISTS idx_auth_audit_status ON auth_audit(status);

-- =========================
-- oauth_accounts (Google Sign-In etc.)
-- =========================
CREATE TABLE IF NOT EXISTS oauth_accounts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider            VARCHAR(50) NOT NULL,       -- 'google', 'apple', ...
    provider_user_id    VARCHAR(255) NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_oauth_accounts_user ON oauth_accounts(user_id);

-- =========================
-- Final notes:
-- - All tables have created_at/updated_at with triggers keeping updated_at current.
-- - This service is the identity root for PandaPay: database.sql's `profiles.id`
--   and `admin_users.id` reference `users.id` here (see db/supabase/migrations
--   0004_user_domain.sql and 0008_admin_console.sql in pandapay-docs).
-- - RLS in the product DB uses current_setting('app.user_id')::uuid, which the
--   product backend must SET per-request after verifying the JWT this service
--   issues — there is no Supabase auth.uid() available outside Supabase.
-- =========================
