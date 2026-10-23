-- Bind newly issued OTP challenges to their authorized action. Historical
-- rows remain NULL because their original purpose cannot be reconstructed;
-- the service treats NULL as sign-in only.
ALTER TABLE otp_requests
    ADD COLUMN IF NOT EXISTS purpose VARCHAR(20);

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_otp_requests_purpose'
          AND conrelid = 'otp_requests'::regclass
    ) THEN
        ALTER TABLE otp_requests
            ADD CONSTRAINT chk_otp_requests_purpose
            CHECK (purpose IS NULL OR purpose IN ('signin', 'recovery', 'replacement'));
    END IF;
END $$;
