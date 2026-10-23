-- Durable, privacy-preserving OTP and enumeration rate-limit state.
-- Only domain-separated HMAC bucket keys are stored; identifiers never are.
CREATE TABLE auth_abuse_buckets (
    bucket_key BYTEA PRIMARY KEY CHECK (octet_length(bucket_key) = 32),
    bucket_kind TEXT NOT NULL CHECK (bucket_kind IN ('counter', 'marker')),
    counter_value BIGINT NOT NULL DEFAULT 0 CHECK (counter_value >= 0),
    marker_value TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT auth_abuse_bucket_value_shape CHECK (
        (bucket_kind = 'counter' AND marker_value IS NULL) OR
        (bucket_kind = 'marker' AND counter_value = 0 AND marker_value IS NOT NULL)
    ),
    CONSTRAINT auth_abuse_marker_size CHECK (marker_value IS NULL OR length(marker_value) <= 128)
);

CREATE INDEX idx_auth_abuse_buckets_expiry
    ON auth_abuse_buckets (expires_at);

REVOKE ALL ON TABLE auth_abuse_buckets FROM PUBLIC;
