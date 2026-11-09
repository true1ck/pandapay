-- A recovery email: a second address, proven with a code, that can get the person
-- back into the account if they lose the sign-in email. It is separate from the
-- sign-in email (users.email), so nothing that signs in or looks up an account ever
-- reads it. The mailbox form is kept by a trigger, exactly like email_canonical.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS recovery_email VARCHAR(255),
    ADD COLUMN IF NOT EXISTS recovery_email_canonical VARCHAR(320),
    ADD COLUMN IF NOT EXISTS recovery_email_added_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS recovery_reminder_email_sent_at TIMESTAMPTZ;

ALTER TABLE users
    ADD CONSTRAINT chk_users_recovery_email_complete CHECK (
        (recovery_email IS NULL AND recovery_email_canonical IS NULL AND recovery_email_added_at IS NULL)
        OR (recovery_email IS NOT NULL AND recovery_email_canonical IS NOT NULL AND recovery_email_added_at IS NOT NULL)
    ),
    -- The recovery email must be a different mailbox from the sign-in email.
    ADD CONSTRAINT chk_users_recovery_email_differs CHECK (
        recovery_email_canonical IS NULL OR email_canonical IS NULL OR recovery_email_canonical <> email_canonical
    );

CREATE OR REPLACE FUNCTION users_set_recovery_email_canonical() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.recovery_email_canonical := auth_canonical_email(NEW.recovery_email);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_users_recovery_email_canonical ON users;
CREATE TRIGGER trg_users_recovery_email_canonical
    BEFORE INSERT OR UPDATE OF recovery_email ON users
    FOR EACH ROW EXECUTE FUNCTION users_set_recovery_email_canonical();

-- Finds accounts still without a recovery email for the one-time reminder email.
CREATE INDEX IF NOT EXISTS idx_users_recovery_reminder_due
    ON users (created_at)
    WHERE recovery_email IS NULL AND recovery_reminder_email_sent_at IS NULL AND deleted = FALSE;
