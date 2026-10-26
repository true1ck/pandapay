import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';

const _namespace = 'user:11111111-2222-4333-8444-555555555555';
const _otherNamespace = 'user:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _session = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _otherSession = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const _importKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherImportKey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _plaintext = Uint8List.fromList(utf8.encode('{"rows":[{"amount":1}]}'));

void main() {
  late _MemorySecureStore store;
  late SecureStatementImportBatchCipher cipher;
  late bool encryptedBatchesExist;

  setUp(() {
    store = _MemorySecureStore();
    encryptedBatchesExist = false;
    cipher = SecureStatementImportBatchCipher(
      secureStore: store,
      installId: 'test-install-id',
      encryptedBatchesExist: (_) async => encryptedBatchesExist,
      lease: _InlineLease(),
    );
  });

  group('statement import batch cipher', () {
    test(
      'round-trips bounded JSON and stores the key outside ciphertext',
      () async {
        final encrypted = await cipher.encrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          plaintext: _plaintext,
        );
        expect(encrypted, hasLength(_plaintext.length + 33));
        expect(encrypted.take(4), [0x50, 0x50, 0x49, 0x4d]);
        expect(
          store.values.values.any((value) => value == base64Encode(encrypted)),
          isFalse,
        );
        final decrypted = await cipher.decrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          ciphertext: encrypted,
        );
        expect(decrypted, _plaintext);
      },
    );

    test('uses a fresh random nonce for every encryption', () async {
      final first = await cipher.encrypt(
        namespace: _namespace,
        sessionId: _session,
        ordinal: 0,
        importKey: _importKey,
        plaintext: _plaintext,
      );
      final second = await cipher.encrypt(
        namespace: _namespace,
        sessionId: _session,
        ordinal: 0,
        importKey: _importKey,
        plaintext: _plaintext,
      );
      expect(first.sublist(5, 17), isNot(second.sublist(5, 17)));
      expect(first, isNot(second));
    });

    test('rejects tampering and any changed AAD binding', () async {
      final encrypted = await cipher.encrypt(
        namespace: _namespace,
        sessionId: _session,
        ordinal: 3,
        importKey: _importKey,
        plaintext: _plaintext,
      );
      final tampered = Uint8List.fromList(encrypted)..[20] ^= 0x01;
      final cases =
          <
            ({
              String namespace,
              String session,
              int ordinal,
              String importKey,
              Uint8List data,
            })
          >[
            (
              namespace: _namespace,
              session: _otherSession,
              ordinal: 3,
              importKey: _importKey,
              data: encrypted,
            ),
            (
              namespace: _otherNamespace,
              session: _session,
              ordinal: 3,
              importKey: _importKey,
              data: encrypted,
            ),
            (
              namespace: _namespace,
              session: _session,
              ordinal: 4,
              importKey: _importKey,
              data: encrypted,
            ),
            (
              namespace: _namespace,
              session: _session,
              ordinal: 3,
              importKey: _otherImportKey,
              data: encrypted,
            ),
            (
              namespace: _namespace,
              session: _session,
              ordinal: 3,
              importKey: _importKey,
              data: tampered,
            ),
          ];
      for (final item in cases) {
        await expectLater(
          cipher.decrypt(
            namespace: item.namespace,
            sessionId: item.session,
            ordinal: item.ordinal,
            importKey: item.importKey,
            ciphertext: item.data,
          ),
          throwsA(
            isA<StatementImportCipherException>().having(
              (error) => error.code,
              'code',
              item.namespace == _otherNamespace
                  ? StatementImportCipherErrorCode.keyMissing
                  : StatementImportCipherErrorCode.authenticationFailed,
            ),
          ),
        );
      }
    });

    test(
      'key is isolated by namespace, session, ordinal and import key',
      () async {
        final encrypted = await cipher.encrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          plaintext: _plaintext,
        );
        await expectLater(
          cipher.decrypt(
            namespace: _otherNamespace,
            sessionId: _session,
            ordinal: 0,
            importKey: _importKey,
            ciphertext: encrypted,
          ),
          throwsA(isA<StatementImportCipherException>()),
        );
      },
    );

    test(
      'rejects malformed headers, short/truncated and oversized ciphertext',
      () async {
        final encrypted = await cipher.encrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          plaintext: _plaintext,
        );
        final malformed = Uint8List.fromList(encrypted)..[0] = 0;
        for (final value in [
          Uint8List(10),
          malformed,
          Uint8List(SecureStatementImportBatchCipher.maxCiphertextBytes + 1),
        ]) {
          await expectLater(
            cipher.decrypt(
              namespace: _namespace,
              sessionId: _session,
              ordinal: 0,
              importKey: _importKey,
              ciphertext: value,
            ),
            throwsA(
              isA<StatementImportCipherException>().having(
                (error) => error.code,
                'code',
                StatementImportCipherErrorCode.malformedCiphertext,
              ),
            ),
          );
        }
        await expectLater(
          cipher.decrypt(
            namespace: _namespace,
            sessionId: _session,
            ordinal: 0,
            importKey: _importKey,
            ciphertext: encrypted.sublist(0, encrypted.length - 1),
          ),
          throwsA(
            isA<StatementImportCipherException>().having(
              (error) => error.code,
              'code',
              StatementImportCipherErrorCode.authenticationFailed,
            ),
          ),
        );
      },
    );

    test(
      'rejects oversized, empty, invalid UTF-8, and non-JSON plaintext',
      () async {
        for (final value in [
          Uint8List(0),
          Uint8List(SecureStatementImportBatchCipher.maxPlaintextBytes + 1),
          Uint8List.fromList([0xff]),
          Uint8List.fromList(utf8.encode('not-json')),
        ]) {
          await expectLater(
            cipher.encrypt(
              namespace: _namespace,
              sessionId: _session,
              ordinal: 0,
              importKey: _importKey,
              plaintext: value,
            ),
            throwsA(isA<StatementImportCipherException>()),
          );
        }
        expect(store.values, isEmpty);
      },
    );

    test(
      'rejects invalid namespace/session/ordinal/import key inputs',
      () async {
        final cases = [
          (
            namespace: 'guest:unsafe',
            session: _session,
            ordinal: 0,
            key: _importKey,
          ),
          (
            namespace: _namespace,
            session: 'not-a-uuid',
            ordinal: 0,
            key: _importKey,
          ),
          (
            namespace: _namespace,
            session: _session,
            ordinal: -1,
            key: _importKey,
          ),
          (namespace: _namespace, session: _session, ordinal: 0, key: ''),
        ];
        for (final item in cases) {
          await expectLater(
            cipher.encrypt(
              namespace: item.namespace,
              sessionId: item.session,
              ordinal: item.ordinal,
              importKey: item.key,
              plaintext: _plaintext,
            ),
            throwsA(
              isA<StatementImportCipherException>().having(
                (error) => error.code,
                'code',
                StatementImportCipherErrorCode.invalidInput,
              ),
            ),
          );
        }
      },
    );

    test(
      'missing secure key never provisions a replacement when ciphertext exists',
      () async {
        final encrypted = await cipher.encrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          plaintext: _plaintext,
        );
        final keySlot = store.values.keys.singleWhere(
          (key) => key.endsWith('pandapay.localdb.key.v1.1'),
        );
        store.values.remove(keySlot);
        final before = store.values.length;
        await expectLater(
          cipher.decrypt(
            namespace: _namespace,
            sessionId: _session,
            ordinal: 0,
            importKey: _importKey,
            ciphertext: encrypted,
          ),
          throwsA(
            isA<StatementImportCipherException>().having(
              (error) => error.code,
              'code',
              StatementImportCipherErrorCode.keyMissing,
            ),
          ),
        );
        expect(store.values.length, before);
      },
    );

    test(
      'database ciphertext inventory blocks replacement even if secure-store marker and key are lost',
      () async {
        final encrypted = await cipher.encrypt(
          namespace: _namespace,
          sessionId: _session,
          ordinal: 0,
          importKey: _importKey,
          plaintext: _plaintext,
        );
        expect(encrypted, isNotEmpty);
        store.values.clear();
        encryptedBatchesExist = true;
        expect(store.values, isEmpty);
        await expectLater(
          cipher.encrypt(
            namespace: _namespace,
            sessionId: _otherSession,
            ordinal: 1,
            importKey: _importKey,
            plaintext: _plaintext,
          ),
          throwsA(
            isA<StatementImportCipherException>().having(
              (error) => error.code,
              'code',
              StatementImportCipherErrorCode.keyMissing,
            ),
          ),
        );
        expect(store.values, isEmpty);
      },
    );

    test(
      'secure-store outage maps to a safe error without exposing payload or key',
      () async {
        store.failReads = true;
        await expectLater(
          cipher.encrypt(
            namespace: _namespace,
            sessionId: _session,
            ordinal: 0,
            importKey: _importKey,
            plaintext: _plaintext,
          ),
          throwsA(isA<StatementImportCipherException>()),
        );
        final error = StatementImportCipherException(
          StatementImportCipherErrorCode.keyUnavailable,
        );
        expect(error.toString(), isNot(contains(_importKey)));
        expect(error.toString(), isNot(contains(utf8.decode(_plaintext))));
      },
    );
  });
}

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw const SecureKeyStoreUnavailable();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failReads) throw const SecureKeyStoreUnavailable();
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    if (failReads) throw const SecureKeyStoreUnavailable();
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}
