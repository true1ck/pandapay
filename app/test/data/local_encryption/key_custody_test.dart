import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'provisions once; encrypted marker with missing metadata never resets',
    () async {
      final storage = _MemoryStore();
      final custody = LocalDatabaseKeyCustody(
        storage,
        random: Random(4),
        lease: _InlineLease(),
      );
      final first = await custody.openKey(
        installId: 'install-A',
        encryptedManifestExists: false,
      );
      expect(first.status, LocalKeyStatus.provisioned);
      final key = first.handle!.withKeyBytes(base64Encode);
      final second = await custody.openKey(
        installId: 'install-A',
        encryptedManifestExists: true,
      );
      expect(second.status, LocalKeyStatus.existing);
      expect(second.handle!.withKeyBytes(base64Encode), key);
      second.handle!.dispose();
      expect(
        () => second.handle!.withKeyBytes((bytes) => bytes),
        throwsStateError,
      );

      storage.values.clear();
      expect(
        (await custody.openKey(
          installId: 'install-A',
          encryptedManifestExists: true,
        )).status,
        LocalKeyStatus.missingForEncryptedStore,
      );
    },
  );

  test('wrong installation binding refuses existing key', () async {
    final custody = LocalDatabaseKeyCustody(
      _MemoryStore(),
      random: Random(4),
      lease: _InlineLease(),
    );
    await custody.openKey(
      installId: 'install-A',
      encryptedManifestExists: false,
    );
    expect(
      (await custody.openKey(
        installId: 'install-B',
        encryptedManifestExists: true,
      )).status,
      LocalKeyStatus.bindingMismatch,
    );
  });

  test('metadata tampering is reported as corrupt', () async {
    final store = _MemoryStore();
    final custody = LocalDatabaseKeyCustody(
      store,
      random: Random(4),
      lease: _InlineLease(),
    );
    await custody.openKey(
      installId: 'install-A',
      encryptedManifestExists: false,
    );
    store.values['pandapay.localdb.key_metadata.v1'] =
        '{"version":1,"install":"install-A","mac":"bad"}';
    expect(
      (await custody.openKey(
        installId: 'install-A',
        encryptedManifestExists: true,
      )).status,
      LocalKeyStatus.corruptMetadata,
    );
  });

  test(
    'orphan slot is retained and authenticated only before conversion',
    () async {
      final store = _MemoryStore();
      final orphanKey = List<int>.generate(32, (index) => index);
      store.values['pandapay.localdb.key.v1.1'] = base64Encode(orphanKey);
      final custody = LocalDatabaseKeyCustody(
        store,
        random: Random(99),
        lease: _InlineLease(),
      );
      final recovered = await custody.openKey(
        installId: 'install-A',
        encryptedManifestExists: false,
      );
      expect(recovered.status, LocalKeyStatus.existing);
      expect(
        recovered.handle!.withKeyBytes(base64Encode),
        base64Encode(orphanKey),
      );
      expect(
        (await LocalDatabaseKeyCustody(
              _MemoryStore()..values.addAll(store.values),
              lease: _InlineLease(),
            ).openKey(installId: 'install-A', encryptedManifestExists: true))
            .status,
        LocalKeyStatus.existing,
      );
    },
  );

  test(
    'temporarily unavailable secure storage does not create a replacement key',
    () async {
      final storage = _MemoryStore()..unavailable = true;
      final result = await LocalDatabaseKeyCustody(
        storage,
        lease: _InlineLease(),
      ).openKey(installId: 'install-A', encryptedManifestExists: true);
      expect(result.status, LocalKeyStatus.unavailable);
      expect(storage.values, isEmpty);
    },
  );
  test(
    'two real isolates provision one shared key under SQLite lease',
    () async {
      final directory = await Directory.systemTemp.createTemp('key-lease-');
      try {
        final replies = ReceivePort();
        final a = await Isolate.spawn(_openInIsolate, [
          replies.sendPort,
          directory.path,
        ]);
        final b = await Isolate.spawn(_openInIsolate, [
          replies.sendPort,
          directory.path,
        ]);
        final results = await replies
            .take(2)
            .toList()
            .timeout(const Duration(seconds: 15));
        a.kill(priority: Isolate.immediate);
        b.kill(priority: Isolate.immediate);
        expect((results[0] as Map)['status'], anyOf('provisioned', 'existing'));
        expect((results[1] as Map)['status'], anyOf('provisioned', 'existing'));
        expect((results[0] as Map)['key'], (results[1] as Map)['key']);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('corrupt lease file fails unavailable', () async {
    final directory = await Directory.systemTemp.createTemp('bad-key-lease-');
    try {
      final leaseFile = File('${directory.path}/lease.sqlite')
        ..writeAsStringSync('not a sqlite database');
      await expectLater(
        SqliteLocalKeyProvisioningLease(
          leaseFile.path,
        ).runExclusive(() async => true),
        throwsA(isA<LocalKeyProvisioningLeaseUnavailable>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'held lease times out as busy and duration bounds are enforced',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'busy-key-lease-',
      );
      final holder = sqlite3.open('${directory.path}/lease.sqlite');
      try {
        holder.execute('BEGIN IMMEDIATE');
        final lease = SqliteLocalKeyProvisioningLease(
          '${directory.path}/lease.sqlite',
          timeout: const Duration(milliseconds: 120),
          retryInterval: const Duration(milliseconds: 10),
        );
        await expectLater(
          lease.runExclusive(() async => true),
          throwsA(isA<LocalKeyProvisioningLeaseBusy>()),
        );
        expect(
          () => SqliteLocalKeyProvisioningLease(
            '${directory.path}/invalid.sqlite',
            timeout: Duration.zero,
          ),
          throwsArgumentError,
        );
        expect(
          () => SqliteLocalKeyProvisioningLease(
            '${directory.path}/invalid.sqlite',
            retryInterval: Duration.zero,
          ),
          throwsArgumentError,
        );
        expect(
          () => SqliteLocalKeyProvisioningLease(
            '${directory.path}/invalid.sqlite',
            timeout: const Duration(seconds: 2),
            retryInterval: const Duration(seconds: 3),
          ),
          throwsArgumentError,
        );
      } finally {
        holder.execute('ROLLBACK');
        holder.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('lease refuses symlink parent paths', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linked-key-lease-',
    );
    final target = await Directory('${directory.path}/target').create();
    final link = Directory('${directory.path}/link');
    try {
      await Link(link.path).create(target.path);
      await expectLater(
        SqliteLocalKeyProvisioningLease(
          '${link.path}/lease.sqlite',
        ).runExclusive(() async => true),
        throwsA(isA<LocalKeyProvisioningLeaseUnavailable>()),
      );
    } finally {
      await link.delete();
      await directory.delete(recursive: true);
    }
  });
  test(
    'unknown metadata fields and oversized key slots fail without replacement',
    () async {
      final store = _MemoryStore();
      final checked = LocalDatabaseKeyCustody(store, lease: _InlineLease());
      final first = await checked.openKey(
        installId: 'install',
        encryptedManifestExists: false,
      );
      first.handle!.dispose();
      const metaKey = 'pandapay.localdb.key_metadata.v1',
          slotKey = 'pandapay.localdb.key.v1.1';
      final original = store.values[metaKey]!;
      final metadata = jsonDecode(original) as Map<String, dynamic>;
      metadata.remove('previous_version');
      metadata['unexpected'] = null;
      store.values[metaKey] = jsonEncode(metadata);
      expect(
        (await checked.openKey(
          installId: 'install',
          encryptedManifestExists: true,
        )).status,
        LocalKeyStatus.corruptMetadata,
      );
      store.values[metaKey] = original;
      store.values[slotKey] = 'A' * 100000;
      expect(
        (await checked.openKey(
          installId: 'install',
          encryptedManifestExists: true,
        )).status,
        LocalKeyStatus.corruptMetadata,
      );
      expect(store.values[slotKey]!.length, 100000);
    },
  );
}

Future<void> _openInIsolate(List<Object?> args) async {
  final send = args[0] as SendPort;
  final directory = args[1] as String;
  final custody = LocalDatabaseKeyCustody(
    _FileStore('$directory/secure.json'),
    lease: SqliteLocalKeyProvisioningLease('$directory/lease.sqlite'),
  );
  final result = await custody.openKey(
    installId: 'fixture-install',
    encryptedManifestExists: false,
  );
  final key = result.handle!.withKeyBytes(base64Encode);
  result.handle!.dispose();
  send.send({'status': result.status.name, 'key': key});
}

final class _FileStore implements SecureKeyValueStore {
  final String path;
  _FileStore(this.path);
  Future<Map<String, dynamic>> _load() async {
    final file = File(path);
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<String?> read(String key) async => (await _load())[key] as String?;
  @override
  Future<void> write(String key, String value) async {
    final values = await _load()
      ..[key] = value;
    await File(path).writeAsString(jsonEncode(values), flush: true);
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    final values = await _load();
    if (values.containsKey(key)) return false;
    values[key] = value;
    await File(path).writeAsString(jsonEncode(values), flush: true);
    return true;
  }

  @override
  Future<void> delete(String key) async {
    final values = await _load()
      ..remove(key);
    await File(path).writeAsString(jsonEncode(values), flush: true);
  }
}

final class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  bool unavailable = false;
  @override
  Future<String?> read(String key) async {
    if (unavailable) throw const SecureKeyStoreUnavailable();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    if (unavailable) throw const SecureKeyStoreUnavailable();
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
