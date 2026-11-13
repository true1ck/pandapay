import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/bundle_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/sync/bundle_verifier.dart';
import 'package:pandapay_domain/sms_v2.dart' show ContractException;
import 'package:sqlite3/sqlite3.dart';

/// S-01 (owner task D5): the shipped baseline rules bundle is empty today. The
/// load path already accepts a verified, signed, non-empty baseline, and
/// refuses anything else that is not the empty placeholder. These tests keep
/// that true so shipping a signed baseline is only a matter of replacing
/// `assets/sms_rules/baseline_bundle.json` (see docs/offline/WP-C9.md).
// A non-empty baseline the app cannot trust makes loading throw, which is why
// an unsigned one must never ship: a StateError for an untrusted version-0
// placeholder, a ContractException for a non-empty bundle without a signature.
final refused = throwsA(anyOf(isA<StateError>(), isA<ContractException>()));

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
  final rawKey = base64Encode(spki.sublist(12));
  final signed = <String, Object?>{
    ...vector['input'] as Map<String, Object?>,
    'signature': {
      'alg': 'Ed25519',
      'keyId': keyId,
      'value': vector['signatureBase64'],
    },
  };

  late Database db;
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
  });
  tearDown(() => db.dispose());

  BundleStore storeTrusting(Map<String, String> keys) => BundleStore(
    db,
    verify: BundleVerifier(trustedKeys: keys).verify,
    clock: () => DateTime.utc(2026, 11, 13),
  );

  test('a verified signed non-empty baseline is the starting bundle', () async {
    final bundle = await storeTrusting({
      keyId: rawKey,
    }).load(shippedJson: jsonEncode(signed));
    expect(bundle.bundleVersion, 7);
    expect(bundle.signature, isNotNull);
    expect(bundle.senders, isNotEmpty);
  });

  test(
    'loading the signed baseline installs nothing: it is only the fallback',
    () async {
      // The baseline is only the fallback: nothing installed yet.
      final store = storeTrusting({keyId: rawKey});
      expect(
        (await store.load(shippedJson: jsonEncode(signed))).bundleVersion,
        7,
      );
      expect(db.select('SELECT 1 FROM v2_rule_bundle'), isEmpty);
    },
  );

  test(
    'an unsigned or untrusted non-empty baseline is refused, not used',
    () async {
      final unsigned = jsonEncode({...signed, 'signature': null});
      final tampered = jsonEncode({...signed, 'bundleVersion': 8});
      for (final raw in [unsigned, tampered]) {
        await expectLater(
          storeTrusting({keyId: rawKey}).load(shippedJson: raw),
          refused,
        );
      }
      await expectLater(
        storeTrusting(const {}).load(shippedJson: jsonEncode(signed)),
        refused,
        reason: 'a signature from a key the app does not trust',
      );
    },
  );

  test('the baseline the app ships is the empty placeholder or properly '
      'signed for the production keys', () async {
    final raw = File(
      'assets/sms_rules/baseline_bundle.json',
    ).readAsStringSync();
    final json = (jsonDecode(raw) as Map).cast<String, Object?>();
    final placeholder =
        json['bundleVersion'] == 0 &&
        (json['rules'] as List).isEmpty &&
        (json['ignoreRules'] as List).isEmpty &&
        json['signature'] == null;
    if (!placeholder) {
      expect(
        await BundleVerifier().verify(raw),
        isNotNull,
        reason:
            'an unsigned or wrongly signed non-empty baseline throws '
            'StateError on every launch',
      );
    }
    // And it loads either way.
    expect(
      (await BundleStore(
        db,
        verify: BundleVerifier().verify,
        clock: () => DateTime.utc(2026, 11, 13),
      ).load(shippedJson: raw)).bundleVersion,
      json['bundleVersion'],
    );
  });
}
