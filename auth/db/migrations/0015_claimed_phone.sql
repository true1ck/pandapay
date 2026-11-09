-- A phone number the person typed in at sign-up. It is NOT verified: no code was
-- sent to it, so it never counts as proof of anything (is_phone_verified is not
-- touched). Its only job is to lock that number to one live account, so one
-- person cannot open many accounts with the same number.
--
-- The hash is the same keyed digest as phone_lookup_hash, so a claimed number and
-- a verified number can be compared directly. Only the hash and an encrypted copy
-- are stored. Rows that already exist get no claim; they are asked at next sign-in
-- once REQUIRE_PHONE_AT_SIGNUP is switched on.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS claimed_phone_enc  TEXT,
    ADD COLUMN IF NOT EXISTS claimed_phone_hash VARCHAR(64),
    ADD COLUMN IF NOT EXISTS claimed_phone_at   TIMESTAMPTZ;

ALTER TABLE users
    ADD CONSTRAINT chk_users_claimed_phone_complete CHECK (
        (claimed_phone_hash IS NULL AND claimed_phone_enc IS NULL AND claimed_phone_at IS NULL)
        OR (claimed_phone_hash ~ '^[0-9a-f]{64}$' AND claimed_phone_enc IS NOT NULL AND claimed_phone_at IS NOT NULL)
    );

-- One live account per claimed number. Deleted accounts keep their rows but free
-- the number, exactly like the existing email and phone indexes.
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_live_claimed_phone
    ON users (claimed_phone_hash)
    WHERE deleted = FALSE AND claimed_phone_hash IS NOT NULL;
