/// Release trust anchors for SMS v2 rule bundles.
///
/// Each key is the base64 encoding of the 32 raw Ed25519 public-key bytes.
/// Keep both public keys installed during rotation. Populate this list before
/// the first signed rules release. See the signing-keys runbook.
const smsV2RuleKeys = <String, String>{
  // Active production key (private half only on the production server,
  // /home/ubuntu/pandapay-secrets/sms-v2/prod-2026-11-a.pem).
  'prod-2026-11-a': 'K/M952psIFGG0Fy5mwjOanHSQ1pxALMV0edh3lqYknk=',
  // Spare, shipped one release ahead so a leaked active key can be replaced
  // without an app release (runbook, LO-13).
  'prod-2026-11-b': 'lopxJ7QzBSnemrK0cAKzIBIGIHMzuz9LhE76iQzUCI4=',
};
