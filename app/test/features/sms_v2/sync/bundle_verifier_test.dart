import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/sync/bundle_verifier.dart';

void main() {
  final vectors =
      jsonDecode(
            File(
              '../api/test/sms_v2/fixtures/canonical/vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final vector = vectors['signedBundle'] as Map<String, Object?>;
  final keyId = vector['keyId'] as String;
  final pem = (vectors['testKey'] as Map)['publicKeyPem'] as String;
  final spki = base64Decode(
    pem.split('\n').where((line) => !line.startsWith('-----')).join(),
  );
  // The fixture uses the 12-byte Ed25519 SPKI prefix.
  final rawKey = base64Encode(spki.sublist(12));
  final signed = <String, Object?>{
    ...vector['input'] as Map<String, Object?>,
    'signature': {
      'alg': 'Ed25519',
      'keyId': keyId,
      'value': vector['signatureBase64'],
    },
  };
  final verifier = BundleVerifier(trustedKeys: {keyId: rawKey});

  test('verifies server vector irrespective of wire key order', () async {
    final reversed = Map<String, Object?>.fromEntries(
      signed.entries.toList().reversed,
    );
    final verified = await verifier.verify(jsonEncode(reversed));
    expect(verified?.bundleVersion, 7);
  });

  test('rejects changed contents and unsigned downloads', () async {
    expect(
      await verifier.verify(jsonEncode({...signed, 'bundleVersion': 8})),
      isNull,
    );
    expect(
      await verifier.verify(jsonEncode({...signed, 'signature': null})),
      isNull,
    );
    expect(await verifier.verify('[true]'), isNull);
    expect(await verifier.verify('{'), isNull);
  });

  test('trust comes from installed keys and supports key rotation', () async {
    final next = base64Encode(List<int>.filled(32, 9));
    final both = BundleVerifier(trustedKeys: {keyId: rawKey, 'next': next});
    final rotated = BundleVerifier(trustedKeys: {'next': next});
    final payload = jsonEncode(signed);
    expect(await both.verify(payload), isNotNull);
    expect(await rotated.verify(payload), isNull);
    expect(await BundleVerifier().verify(payload), isNull);
  });

  test('rejects invalid configured key material', () {
    expect(
      () => BundleVerifier(trustedKeys: {'old': 'AA=='}),
      throwsFormatException,
    );
  });
}
