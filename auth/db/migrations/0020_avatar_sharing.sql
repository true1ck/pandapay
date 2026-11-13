-- Consent for showing a profile photo to other people. A person's PRESET avatar is
-- just an id of a stock picture and is visible by default; their PHOTO is personal
-- and is shown to others only if they turned this on. Default is FALSE, so every
-- existing photo stays private until its owner opts in.
--
-- This flag is only the owner's consent. Who may look (people who share a Split
-- group) is decided by the API service; the auth service never serves a photo to
-- another person unless this flag is TRUE.
--
-- It is cleared when the photo is removed (see userAvatar.removePhoto) so a later
-- photo starts private again. A new column on an existing table needs no new grants.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS avatar_photo_shared BOOLEAN NOT NULL DEFAULT FALSE;
