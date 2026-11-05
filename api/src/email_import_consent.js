'use strict';

/**
 * Email import reads mail on the server (IMAP polling and forwarded email),
 * so the server checks the `email_import` consent itself instead of trusting
 * the app's consent sheet. A connection or forwarding address is only issued
 * while the user's latest `email_import` row is a grant, is not revoked, and
 * was given against the current policy version (config.productTermsVersion,
 * the same date the app records as `consentPolicyVersion`).
 */

const EMAIL_IMPORT_CONSENT_REQUIRED = 'email_import_consent_required';

/**
 * Runs inside the caller's withUserClient transaction, so row-level security
 * limits the read to the caller's own consents. user_consents is an
 * append-only log: the latest row decides, and a withdrawal recorded in the
 * same instant as a grant wins (the same order the SMS consents use).
 */
async function hasCurrentEmailImportConsent(client, profileId, policyVersion) {
  if (!policyVersion) return false;
  const result = await client.query(
    `SELECT granted, revoked_at, policy_version
       FROM user_consents
      WHERE profile_id = $1 AND purpose = 'email_import'
      ORDER BY granted_at DESC, granted ASC, id DESC
      LIMIT 1`,
    [profileId],
  );
  const latest = result.rows[0];
  return latest?.granted === true && latest.revoked_at == null && latest.policy_version === policyVersion;
}

async function requireEmailImportConsent(client, profileId, policyVersion) {
  if (await hasCurrentEmailImportConsent(client, profileId, policyVersion)) return;
  const error = new Error(EMAIL_IMPORT_CONSENT_REQUIRED);
  error.code = EMAIL_IMPORT_CONSENT_REQUIRED;
  throw error;
}

function isEmailImportConsentRequired(error) {
  return error?.code === EMAIL_IMPORT_CONSENT_REQUIRED;
}

module.exports = {
  EMAIL_IMPORT_CONSENT_REQUIRED,
  hasCurrentEmailImportConsent,
  requireEmailImportConsent,
  isEmailImportConsentRequired,
};
