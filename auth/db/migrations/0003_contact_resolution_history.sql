-- Retain an encrypted, auditable copy before an explicitly approved contact
-- conflict is cleared from a secondary account. This migration does not edit
-- users or choose which account owns a contact.
CREATE TABLE contact_resolution_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    resolution_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    retained_phone_account_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    original_row_age BYTEA NOT NULL,
    archive_sha256 CHAR(64) NOT NULL,
    reason TEXT NOT NULL CHECK (reason = 'approved_test_phone_conflict'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_contact_resolution_history_resolution_user UNIQUE (resolution_id, user_id)
);

REVOKE ALL ON TABLE contact_resolution_history FROM PUBLIC;
