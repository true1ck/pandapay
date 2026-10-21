-- The service backfills these keyed digests after applying this DDL with the
-- configured field-encryption key and PHONE_LOOKUP_HMAC_KEY. Phone ciphertext
-- uses a random IV and cannot be used as an equality index.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS phone_lookup_hash VARCHAR(64);

ALTER TABLE otp_requests
    ADD COLUMN IF NOT EXISTS phone_lookup_hash VARCHAR(64);

CREATE INDEX IF NOT EXISTS idx_users_phone_lookup_hash
    ON users (phone_lookup_hash)
    WHERE phone_lookup_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_otp_phone_lookup_hash_unconsumed
    ON otp_requests (phone_lookup_hash, created_at DESC)
    WHERE phone_lookup_hash IS NOT NULL AND deleted = FALSE AND consumed_at IS NULL;
