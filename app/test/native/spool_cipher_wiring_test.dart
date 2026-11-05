import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The Swift behaviour is covered by test/native/incoming_sms_spool_test.swift
// (run with swiftc on a Mac). These checks keep the Dart-visible contract and
// the Xcode wiring from drifting: Flutter still receives plain text from the
// spool, and the cipher is compiled into the Runner target.
void main() {
  final spool = File('ios/Runner/IncomingSmsSpool.swift').readAsStringSync();
  final cipher = File('ios/Runner/SpoolCipher.swift').readAsStringSync();
  final project = File(
    'ios/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();

  test('SpoolCipher is part of the Runner target', () {
    expect(project, contains('SpoolCipher.swift in Sources'));
    expect(
      RegExp(
        r'SpoolCipher\.swift \*/ = \{isa = PBXFileReference',
      ).hasMatch(project),
      isTrue,
    );
  });

  test(
    'the key is Keychain-only, first-unlock, this-device and never synced',
    () {
      expect(
        cipher,
        contains('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'),
      );
      expect(cipher, contains('kSecAttrSynchronizable as String] = false'));
      expect(cipher, contains('AES.GCM'));
      expect(cipher, contains('SymmetricKey(size: .bits256)'));
    },
  );

  test(
    'the spool seals on write, opens on handoff and destroys the key on reset',
    () {
      expect(spool, contains('SpoolCipher.seal(body)'));
      expect(spool, contains('sealedSender(sender)'));
      expect(spool, contains('SpoolCipher.openStored('));
      expect(spool, contains('SpoolCipher.destroyKey()'));
      // The raw text columns are never written unsealed.
      expect(
        RegExp(
          r'INSERT INTO captures[^\n]*\n[^\n]*\[id, generation, fingerprint, body',
        ).hasMatch(spool),
        isFalse,
      );
    },
  );

  test('the handoff row keeps the keys Dart reads', () {
    final dart = File(
      'lib/features/sms_import/ios_shortcut_sms.dart',
    ).readAsStringSync();
    for (final key in ['bodyCharacters', 'senderEvidence']) {
      expect(dart, contains("row['$key']"));
      expect(spool, contains('"$key"'));
    }
  });
}
