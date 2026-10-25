'use strict';

const { maskEmail, maskPhone } = require('../utils/recoveryContacts');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_PROOF_AGE_SECONDS = 300;
const OWN_ACCOUNT_STATUS_SQL = `SELECT u.id,
  NULLIF(pg_catalog.btrim(u.name), '') IS NOT NULL AS profile_complete,
  EXISTS(SELECT 1 FROM public.user_devices d
    WHERE d.user_id=u.id AND d.device_identifier=$2 AND d.is_active=true) AS device_active,
  EXISTS(SELECT 1 FROM public.oauth_accounts o
    WHERE o.user_id=u.id AND o.provider='google') AS google_linked
  FROM public.users u WHERE u.id=$1 AND u.is_active=true AND u.deleted=false`;

function validContact(contact, channel) {
  if (contact?.verified !== true || typeof contact.value !== 'string') return false;
  const value = contact.value;
  return channel === 'email'
    ? value.length <= 255 && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value)
    : /^\+[1-9]\d{9,14}$/.test(value);
}

function validSession(proof) {
  return proof?.valid === true && proof.token_valid === true && proof.guest === false &&
    UUID.test(proof.subject || '') && proof.session?.active === true && proof.session?.revoked === false &&
    typeof proof.device_id === 'string' && Buffer.byteLength(proof.device_id) >= 1 &&
    Buffer.byteLength(proof.device_id) <= 255 && !/[\u0000-\u001f\u007f]/.test(proof.device_id);
}

function recentFactor(proof, now) {
  const timestamp = proof.auth_proof?.verified_at;
  const channel = proof.auth_proof?.channel;
  const age = Math.floor(now() / 1000) - timestamp;
  if (!Number.isInteger(timestamp) || !['phone', 'email', 'google'].includes(channel) || age < 0 || age > MAX_PROOF_AGE_SECONDS) return false;
  return channel === 'google' || validContact(proof.verified_contacts?.[channel], channel);
}

function emptyObject(value) {
  return value === undefined || value === null || (typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0);
}

function createProofLookupHandler({ verifySession, query, now = Date.now } = {}) {
  if (typeof verifySession !== 'function' || typeof query !== 'function' || typeof now !== 'function') throw new Error('Proof lookup requires explicit session and database dependencies');
  return async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Pragma', 'no-cache');
    try {
      const authorization = req.headers?.authorization;
      const matched = typeof authorization === 'string' && /^Bearer ([^\s]{1,8192})$/i.exec(authorization);
      if (!matched) return res.status(401).json({ error: 'proof_required' });
      const token = matched[1];
      const proof = await verifySession(token);
      if (!validSession(proof)) return res.status(401).json({ error: 'proof_required' });
      // This version accepts no contact or subject selector, including the
      // caller's own. Identity always comes from signed, current session proof.
      if (!emptyObject(req.body) || !emptyObject(req.query)) return res.status(400).json({ error: 'invalid_request' });
      if (!recentFactor(proof, now)) return res.status(403).json({ error: 'recent_proof_required' });
      const result = await query(OWN_ACCOUNT_STATUS_SQL, [proof.subject, proof.device_id]);
      const account = result.rows?.length === 1 ? result.rows[0] : null;
      if (!account || account.id !== proof.subject || account.device_active !== true ||
          (proof.auth_proof.channel === 'google' && account.google_linked !== true)) {
        return res.status(403).json({ error: 'proof_required' });
      }
      // Recheck token-version/account/device state after the status query and
      // derive hints from this newer proof, so contact replacements and logout
      // between checks cannot disclose the earlier contact snapshot.
      const current = await verifySession(token);
      if (!validSession(current) || current.subject !== proof.subject || current.device_id !== proof.device_id ||
          current.auth_proof?.channel !== proof.auth_proof.channel || current.auth_proof?.verified_at !== proof.auth_proof.verified_at ||
          !recentFactor(current, now)) return res.status(403).json({ error: 'proof_required' });
      return res.json({
        version: 2,
        account_exists: true,
        profile_complete: account.profile_complete === true,
        contact_hints: {
          email: validContact(current.verified_contacts?.email, 'email') ? maskEmail(current.verified_contacts.email.value) : null,
          phone: validContact(current.verified_contacts?.phone, 'phone') ? maskPhone(current.verified_contacts.phone.value) : null,
        },
      });
    } catch (error) {
      // The legacy anonymous flow and masked-email recovery are separate,
      // unchanged routes. This endpoint never sends OTPs or queries a contact.
      return res.status(error?.message === 'invalid_token' ? 401 : 503)
        .json({ error: error?.message === 'invalid_token' ? 'proof_required' : 'proof_lookup_unavailable' });
    }
  };
}

module.exports = { createProofLookupHandler, OWN_ACCOUNT_STATUS_SQL, MAX_PROOF_AGE_SECONDS };
