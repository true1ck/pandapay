import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
import 'package:pandapay/data/secure_storage/local_receipt_key_custody.dart';

void main() {
  test(
    'receipt keys are independent of DB, account and guest keys, and persist per install',
    () async {
      final storage = _MemoryStore(), lease = _Lease();
      final db = await LocalDatabaseKeyCustody(
        storage,
        lease: lease,
      ).openKey(installId: 'install-A', encryptedManifestExists: false);
      final custody = LocalReceiptKeyCustody(storage, lease: lease),
          values = <String>{};
      values.add(db.handle!.withKeyBytes(base64Encode));
      for (final namespace in [
        'user:account-A',
        'user:account-B',
        'guest:local',
      ]) {
        final first = await custody.openKey(
          installId: 'install-A',
          accountNamespace: namespace,
          encryptedReceiptsExist: false,
        );
        final value = await first.handle!.withSecretKey(
          (key) async => base64Encode(await key.extractBytes()),
        );
        values.add(value);
        final reopened = await custody.openKey(
          installId: 'install-A',
          accountNamespace: namespace,
          encryptedReceiptsExist: true,
        );
        expect(
          await reopened.handle!.withSecretKey(
            (key) async => base64Encode(await key.extractBytes()),
          ),
          value,
        );
        first.handle!.dispose();
        reopened.handle!.dispose();
      }
      expect(values.length, 4);
      db.handle!.dispose();
      expect(
        (await custody.openKey(
          installId: 'different-install',
          accountNamespace: 'user:account-A',
          encryptedReceiptsExist: true,
        )).status,
        LocalKeyStatus.bindingMismatch,
      );
    },
  );
  test(
    'missing receipt key for encrypted records never provisions or falls back',
    () async {
      final storage = _MemoryStore();
      final custody = LocalReceiptKeyCustody(storage, lease: _Lease());
      final result = await custody.openKey(
        installId: 'install',
        accountNamespace: 'user:account',
        encryptedReceiptsExist: true,
      );
      expect(result.status, LocalKeyStatus.missingForEncryptedStore);
      expect(result.handle, isNull);
      expect(storage.values, isEmpty);
      expect(
        (await custody.openKey(
          installId: 'install',
          accountNamespace: 'user:../unsafe',
          encryptedReceiptsExist: false,
        )).status,
        LocalKeyStatus.bindingMismatch,
      );
    },
  );
  test(
    'async receipt key callback remains usable until completion and destroys on both exits',
    () async {
      final custody = LocalReceiptKeyCustody(_MemoryStore(), lease: _Lease());
      final handle = (await custody.openKey(
        installId: 'install',
        accountNamespace: 'guest:local',
        encryptedReceiptsExist: false,
      )).handle!;
      SecretKeyData? captured;
      await handle.withSecretKey((key) async {
        captured = key as SecretKeyData;
        await Future<void>.delayed(Duration.zero);
        expect((await key.extractBytes()).length, 32);
      });
      expect(captured!.hasBeenDestroyed, true);
      await expectLater(
        handle.withSecretKey((key) async {
          captured = key as SecretKeyData;
          throw StateError('synthetic failure');
        }),
        throwsStateError,
      );
      expect(captured!.hasBeenDestroyed, true);
      handle.dispose();
      await expectLater(
        handle.withSecretKey((key) async => 0),
        throwsStateError,
      );
    },
  );
}

final class _Lease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
