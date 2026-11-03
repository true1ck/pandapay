/// Release trust anchors for SMS v2 rule bundles.
///
/// Each key is the base64 encoding of the 32 raw Ed25519 public-key bytes.
/// Keep both public keys installed during rotation. Populate this list before
/// the first signed rules release. See the signing-keys runbook.
const smsV2RuleKeys = <String, String>{};
