'use strict';

// Profile avatars. A preset id (drawn by the app) and/or a small photo. The photo
// is only ever returned to its owner. Nothing here is a credential, so changing an
// avatar needs no fresh sign-in code.

// The app draws these; the server only needs to know the ids are real, so a
// client cannot store arbitrary text in the column.
// The first line is the older symbol avatars (still valid, so nobody loses theirs);
// the rest are the panda illustrations the picker offers now (app/assets/avatars).
const PRESETS = Object.freeze([
  'panda', 'bamboo', 'sun', 'wave', 'berry', 'forest', 'dusk', 'night',
  'cool', 'coin', 'explorer', 'snack', 'verified', 'party',
  'phone', 'sleepy', 'hero', 'shopper', 'secure', 'music',
]);

const MAX_PHOTO_BYTES = 200 * 1024;
const MIN_PHOTO_BYTES = 100;

const STATUS_BY_CODE = Object.freeze({
  preset_invalid: 400,
  sharing_invalid: 400,
  photo_invalid: 400,
  photo_too_large: 413,
  photo_type_unsupported: 415,
  no_photo: 404,
  account_unavailable: 401,
});

class AvatarError extends Error {
  constructor(code) {
    super(code);
    this.name = 'AvatarError';
    this.code = code;
    this.status = STATUS_BY_CODE[code] || 400;
  }
}

/**
 * What the bytes really are, from their first bytes, whatever the client claimed.
 * Only JPEG and PNG are accepted: the app sends JPEG, and these two cannot carry
 * script when served back as an image.
 */
function sniffImageType(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 8) return null;
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'image/jpeg';
  if (buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  return null;
}

async function getAvatar({ query, userId }) {
  const { rows } = await query(
    `SELECT avatar_preset, (avatar_photo IS NOT NULL) AS has_photo, avatar_photo_shared, avatar_updated_at
       FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  const user = rows[0];
  if (!user) throw new AvatarError('account_unavailable');
  return {
    preset: user.avatar_preset || null,
    has_photo: user.has_photo === true,
    // Whether other people may see the photo. Off until the owner turns it on.
    share_photo: user.avatar_photo_shared === true,
    // Changes whenever the avatar does, so the app can tell when its copy is stale.
    version: user.avatar_updated_at ? new Date(user.avatar_updated_at).getTime() : 0,
  };
}

/** `preset` null clears it (back to the initial letter). */
async function setPreset({ query, userId, preset }) {
  if (preset !== null && (typeof preset !== 'string' || !PRESETS.includes(preset))) {
    throw new AvatarError('preset_invalid');
  }
  const { rows } = await query(
    `UPDATE users SET avatar_preset = $2, avatar_updated_at = NOW(), updated_at = NOW()
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
    [userId, preset],
  );
  if (rows.length === 0) throw new AvatarError('account_unavailable');
  return getAvatar({ query, userId });
}

/** Turn photo sharing on or off. Allowed with no photo (harmless: nothing to show). */
async function setSharing({ query, userId, share }) {
  if (typeof share !== 'boolean') throw new AvatarError('sharing_invalid');
  const { rows } = await query(
    `UPDATE users SET avatar_photo_shared = $2, avatar_updated_at = NOW(), updated_at = NOW()
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
    [userId, share],
  );
  if (rows.length === 0) throw new AvatarError('account_unavailable');
  return getAvatar({ query, userId });
}

async function setPhoto({ query, userId, bytes, declaredType }) {
  if (!Buffer.isBuffer(bytes) || bytes.length < MIN_PHOTO_BYTES) throw new AvatarError('photo_invalid');
  if (bytes.length > MAX_PHOTO_BYTES) throw new AvatarError('photo_too_large');
  const type = sniffImageType(bytes);
  if (!type) throw new AvatarError('photo_type_unsupported');
  // A client that says "jpeg" while sending something else is lying or buggy.
  if (declaredType && declaredType !== type) throw new AvatarError('photo_invalid');
  const { rows } = await query(
    `UPDATE users SET avatar_photo = $2, avatar_photo_type = $3, avatar_updated_at = NOW(), updated_at = NOW()
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
    [userId, bytes, type],
  );
  if (rows.length === 0) throw new AvatarError('account_unavailable');
  return getAvatar({ query, userId });
}

async function getPhoto({ query, userId }) {
  const { rows } = await query(
    `SELECT avatar_photo, avatar_photo_type FROM users
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  const user = rows[0];
  if (!user) throw new AvatarError('account_unavailable');
  if (!user.avatar_photo) throw new AvatarError('no_photo');
  return { bytes: user.avatar_photo, type: user.avatar_photo_type };
}

async function removePhoto({ query, userId }) {
  const { rows } = await query(
    `UPDATE users SET avatar_photo = NULL, avatar_photo_type = NULL, avatar_photo_shared = FALSE, avatar_updated_at = NOW(), updated_at = NOW()
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
    [userId],
  );
  if (rows.length === 0) throw new AvatarError('account_unavailable');
  return getAvatar({ query, userId });
}

// What another person's app may show. Used only by the service-secret internal API;
// the API service has already checked the two people share a group. A photo that is
// not shared is never mentioned: photo_shared is true only when it exists AND is
// shared. Unknown, deleted and inactive accounts all look the same (null).
async function getPublicAvatar({ query, userId }) {
  const { rows } = await query(
    `SELECT avatar_preset, (avatar_photo IS NOT NULL AND avatar_photo_shared = TRUE) AS photo_shared, avatar_updated_at
       FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE`,
    [userId],
  );
  const user = rows[0];
  if (!user) return null;
  return {
    preset: user.avatar_preset || null,
    photo_shared: user.photo_shared === true,
    version: user.avatar_updated_at ? new Date(user.avatar_updated_at).getTime() : 0,
  };
}

/** The photo bytes, only if present AND shared; otherwise null (no hint which). */
async function getPublicPhoto({ query, userId }) {
  const { rows } = await query(
    `SELECT avatar_photo, avatar_photo_type FROM users
      WHERE id = $1 AND deleted = FALSE AND is_active = TRUE
        AND avatar_photo_shared = TRUE AND avatar_photo IS NOT NULL`,
    [userId],
  );
  const user = rows[0];
  if (!user) return null;
  return { bytes: user.avatar_photo, type: user.avatar_photo_type };
}

module.exports = {
  AvatarError, PRESETS, MAX_PHOTO_BYTES, sniffImageType,
  getAvatar, setPreset, setSharing, setPhoto, getPhoto, removePhoto,
  getPublicAvatar, getPublicPhoto,
};
