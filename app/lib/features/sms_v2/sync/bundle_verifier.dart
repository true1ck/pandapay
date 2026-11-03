import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:pandapay_domain/sms_v2.dart';

import 'rule_keys.dart';

/// Verifies signed bundle JSON received from the rule service or local cache.
final class BundleVerifier {
  BundleVerifier({Map<String, String> trustedKeys = smsV2RuleKeys})
    : _trustedKeys = Map.unmodifiable({
        for (final entry in trustedKeys.entries)
          entry.key: _publicKey(entry.value),
      });

  final Map<String, SimplePublicKey> _trustedKeys;
  final Ed25519 _algorithm = Ed25519();

  /// Returns null for malformed, unsigned, untrusted, or modified JSON.
  /// The caller owns version and expiry policy and retains its last good copy.
  Future<RuleBundle?> verify(String encodedBundle) async {
    try {
      final decoded = jsonDecode(encodedBundle);
      if (decoded is! Map<String, Object?>) return null;
      final bundle = RuleBundle.fromJson(decoded);
      final signature = bundle.signature;
      if (signature == null || signature.alg != 'Ed25519') return null;
      final key = _trustedKeys[signature.keyId];
      if (key == null) return null;
      final bytes = base64Decode(signature.value);
      if (bytes.length != 64) return null;

      // Signatures cover the wire fields. A model round-trip may normalize
      // optional fields or dates and would verify a different payload.
      final unsigned = Map<String, Object?>.of(decoded)..remove('signature');
      final valid = await _algorithm.verify(
        utf8.encode(canonicalJson(unsigned)),
        signature: Signature(bytes, publicKey: key),
      );
      return valid ? bundle : null;
    } on ContractException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static SimplePublicKey _publicKey(String encoded) {
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) {
      throw const FormatException('Expected a raw 32-byte Ed25519 public key');
    }
    return SimplePublicKey(bytes, type: KeyPairType.ed25519);
  }
}
