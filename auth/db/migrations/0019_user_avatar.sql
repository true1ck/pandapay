-- A profile avatar: either one of a fixed set of preset avatars (the app draws
-- them; only the id is stored) or a small photo the person chose. The photo is
-- re-encoded on the phone to a small square JPEG (a few tens of KB) before upload,
-- so it is kept right on the user row: no separate storage service, and it goes
-- away with the account because it IS part of the row.
--
-- users.avatar_url (a picture URL a Google sign-in may have saved) is untouched.
-- Nothing here reads or serves the photo to anyone but its owner.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS avatar_preset     VARCHAR(24),
    ADD COLUMN IF NOT EXISTS avatar_photo      BYTEA,
    ADD COLUMN IF NOT EXISTS avatar_photo_type VARCHAR(16),
    ADD COLUMN IF NOT EXISTS avatar_updated_at TIMESTAMPTZ;

ALTER TABLE users
    ADD CONSTRAINT chk_users_avatar_preset CHECK (
        avatar_preset IS NULL OR avatar_preset ~ '^[a-z][a-z0-9_]{1,23}$'
    ),
    ADD CONSTRAINT chk_users_avatar_photo_complete CHECK (
        (avatar_photo IS NULL AND avatar_photo_type IS NULL)
        OR (avatar_photo IS NOT NULL AND avatar_photo_type IN ('image/jpeg', 'image/png')
            AND octet_length(avatar_photo) BETWEEN 100 AND 204800)
    );
