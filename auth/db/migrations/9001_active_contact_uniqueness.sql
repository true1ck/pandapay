-- This post-backfill migration is deliberately not eligible until the runner
-- has verified and completed phone_lookup_hash values using the retained keys.
-- It preserves deleted rows and IDs; active conflicts stop the migration.
DO $active_contact_uniqueness_preflight$
DECLARE
    null_deleted_rows BIGINT;
    email_lower_duplicate_groups BIGINT;
    email_trimmed_lower_duplicate_groups BIGINT;
    phone_hash_duplicate_groups BIGINT;
    missing_phone_hash_rows BIGINT;
    malformed_phone_hash_rows BIGINT;
    orphan_phone_hash_rows BIGINT;
BEGIN
    SELECT COUNT(*) INTO null_deleted_rows
      FROM users WHERE deleted IS NULL;

    SELECT COUNT(*) INTO email_lower_duplicate_groups
      FROM (
        SELECT lower(email)
          FROM users
         WHERE deleted IS FALSE AND email IS NOT NULL
         GROUP BY lower(email)
        HAVING COUNT(*) > 1
      ) AS duplicate_email_lower;

    SELECT COUNT(*) INTO email_trimmed_lower_duplicate_groups
      FROM (
        SELECT lower(btrim(email))
          FROM users
         WHERE deleted IS FALSE AND email IS NOT NULL
         GROUP BY lower(btrim(email))
        HAVING COUNT(*) > 1
      ) AS duplicate_email_trimmed_lower;

    SELECT COUNT(*) INTO phone_hash_duplicate_groups
      FROM (
        SELECT phone_lookup_hash
          FROM users
         WHERE deleted IS FALSE AND phone_lookup_hash IS NOT NULL
         GROUP BY phone_lookup_hash
        HAVING COUNT(*) > 1
      ) AS duplicate_phone_hash;

    SELECT COUNT(*) INTO missing_phone_hash_rows
      FROM users
     WHERE deleted IS FALSE AND phone_number IS NOT NULL AND phone_lookup_hash IS NULL;

    SELECT COUNT(*) INTO malformed_phone_hash_rows
      FROM users
     WHERE deleted IS FALSE AND phone_lookup_hash IS NOT NULL
       AND phone_lookup_hash !~ '^[0-9a-fA-F]{64}$';

    SELECT COUNT(*) INTO orphan_phone_hash_rows
      FROM users
     WHERE deleted IS FALSE AND phone_number IS NULL AND phone_lookup_hash IS NOT NULL;

    IF null_deleted_rows > 0 OR email_lower_duplicate_groups > 0 OR
       email_trimmed_lower_duplicate_groups > 0 OR phone_hash_duplicate_groups > 0 OR
       missing_phone_hash_rows > 0 OR malformed_phone_hash_rows > 0 OR
       orphan_phone_hash_rows > 0 THEN
        RAISE EXCEPTION
          'active contact uniqueness preflight blocked (count-only): null_deleted_rows=% email_lower_duplicate_groups=% email_trimmed_lower_duplicate_groups=% phone_hash_duplicate_groups=% missing_phone_hash_rows=% malformed_phone_hash_rows=% orphan_phone_hash_rows=%',
          null_deleted_rows, email_lower_duplicate_groups,
          email_trimmed_lower_duplicate_groups, phone_hash_duplicate_groups,
          missing_phone_hash_rows, malformed_phone_hash_rows, orphan_phone_hash_rows;
    END IF;
END
$active_contact_uniqueness_preflight$;

CREATE UNIQUE INDEX uq_users_active_email_lower
    ON users (lower(email))
    WHERE deleted = FALSE AND email IS NOT NULL;

CREATE UNIQUE INDEX uq_users_active_phone_lookup_hash
    ON users (phone_lookup_hash)
    WHERE deleted = FALSE AND phone_lookup_hash IS NOT NULL;
