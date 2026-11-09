-- Account recovery attempts ("Can't sign in?"). One row per attempt, matched or not,
-- so every start looks the same from outside and can be counted and audited. The
-- row carries the state of the recovery: started, proven, waiting out a hold,
-- completed, cancelled or undone. Tokens are stored only as hashes.
CREATE TABLE IF NOT EXISTS recovery_attempts (
    id                  UUID PRIMARY KEY,
    user_id             UUID REFERENCES users(id) ON DELETE CASCADE,
    matched             BOOLEAN NOT NULL DEFAULT FALSE,
    path                TEXT CHECK (path IN ('strong', 'weak')),
    state               TEXT NOT NULL CHECK (state IN
                          ('started', 'proven', 'new_email_sent', 'ready', 'pending_hold',
                           'completed', 'cancelled', 'undone', 'failed')),
    device_hash         VARCHAR(64) NOT NULL,
    ip_address          VARCHAR(45),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ NOT NULL,
    failed_attempts     SMALLINT NOT NULL DEFAULT 0,
    code_identifier     TEXT,
    code_request_id     UUID,
    new_email           VARCHAR(255),
    new_email_identifier TEXT,
    new_email_request_id UUID,
    use_recovery_email  BOOLEAN NOT NULL DEFAULT FALSE,
    old_email           VARCHAR(255),
    hold_until          TIMESTAMPTZ,
    resume_token_hash   VARCHAR(64),
    stop_token_hash     VARCHAR(64),
    stop_until          TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    stopped_at          TIMESTAMPTZ,
    CONSTRAINT chk_recovery_attempts_matched CHECK (matched OR (user_id IS NULL AND path IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_recovery_attempts_user ON recovery_attempts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recovery_attempts_pending ON recovery_attempts (user_id) WHERE state = 'pending_hold';
CREATE UNIQUE INDEX IF NOT EXISTS uq_recovery_attempts_stop_token ON recovery_attempts (stop_token_hash) WHERE stop_token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_recovery_attempts_created ON recovery_attempts (created_at);
