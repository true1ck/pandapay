import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/portable_backup/account_recovery_crypto.dart';
import 'package:pandapay/data/portable_backup/account_recovery_repository.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';
import 'package:pandapay/data/portable_backup/account_recovery_local_snapshot.dart';
import 'package:pandapay/data/local/app_database.dart';

const account = '11111111-1111-4111-8111-111111111111',
    snapshot = '22222222-2222-4222-8222-222222222222',
    other = '33333333-3333-4333-8333-333333333333';
Uint8List localPayload(String text) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'format': 'pandapay-account-local-v1',
      'account_id': account,
      'namespace': 'user:$account',
      'include_receipts': true,
      'include_unsynced': true,
      'tables': {'example': text},
      'receipts': [],
    }),
  ),
);
void main() {
  test(
    'password-free cipher authenticates account, snapshot and ciphertext',
    () async {
      const cipher = AccountRecoveryCipher();
      final key = AccountRecoveryArchiveKey.generate();
      final source = Uint8List.fromList(
        utf8.encode('pending receipt and original UUID'),
      );
      final encrypted = await cipher.encrypt(
        source,
        accountId: account,
        snapshotId: snapshot,
        key: key,
      );
      expect(
        await cipher.decrypt(
          encrypted,
          accountId: account,
          snapshotId: snapshot,
          key: key,
        ),
        source,
      );
      await expectLater(
        cipher.decrypt(
          encrypted,
          accountId: other,
          snapshotId: snapshot,
          key: key,
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        cipher.decrypt(
          encrypted,
          accountId: account,
          snapshotId: other,
          key: key,
        ),
        throwsA(isA<Exception>()),
      );
      final changed = Uint8List.fromList(encrypted);
      changed[45] ^= 1;
      await expectLater(
        cipher.decrypt(
          changed,
          accountId: account,
          snapshotId: snapshot,
          key: key,
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        cipher.encrypt([], accountId: account, snapshotId: snapshot, key: key),
        throwsFormatException,
      );
      expect(key.toString(), 'AccountRecoveryArchiveKey(redacted)');
      key.destroy();
    },
  );
  test(
    'fresh device recovers encrypted local payload through existing OTP account',
    () async {
      Map<String, dynamic>? stored;
      var uploads = 0;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer existing-otp-token');
        expect(request.followRedirects, isFalse);
        if (request.method == 'POST') {
          uploads++;
          final length = ByteData.sublistView(request.bodyBytes).getUint32(0);
          final metadata =
              jsonDecode(utf8.decode(request.bodyBytes.sublist(4, 4 + length)))
                  as Map<String, dynamic>;
          final encrypted = request.bodyBytes.sublist(4 + length);
          expect(metadata['consent_version'], 'account-recovery-v1');
          expect(metadata['include_unsynced'], isTrue);
          stored = {
            ...metadata,
            'account_id': account,
            'encrypted_archive': base64Encode(encrypted),
            'archive_sha256': sha256.convert(encrypted).toString(),
          };
          return http.Response(
            jsonEncode({
              'snapshot_id': snapshot,
              'archive_sha256': stored!['archive_sha256'],
            }),
            201,
          );
        }
        return http.Response(jsonEncode(stored), 200);
      });
      AccountRecoveryRepository device() => AccountRecoveryRepository(
        apiBaseUrl: Uri.parse('https://api.example.test'),
        accountId: account,
        accessToken: () async => 'existing-otp-token',
        client: client,
        enabled: true,
      );
      final original = localPayload(
        'original pending UUID, receipt bytes, queue mutation id',
      );
      await device().upload(
        snapshotId: snapshot,
        plaintextArchive: original,
        consent: const AccountRecoveryConsent(
          includeReceipts: true,
          includeUnsynced: true,
          explicitlyApproved: true,
        ),
      );
      expect(await device().downloadAndDecrypt(snapshot), original);
      expect(uploads, 1);
      stored!['account_id'] = other;
      await expectLater(
        device().downloadAndDecrypt(snapshot),
        throwsStateError,
      );
      client.close();
    },
  );
  test('unapproved or disabled recovery never uploads', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 500);
    });
    for (final enabled in [false, true]) {
      final repository = AccountRecoveryRepository(
        apiBaseUrl: Uri.parse('https://api.example.test'),
        accountId: account,
        accessToken: () async => 'token',
        client: client,
        enabled: enabled,
      );
      await expectLater(
        repository.upload(
          snapshotId: snapshot,
          plaintextArchive: Uint8List.fromList([1]),
          consent: const AccountRecoveryConsent(
            includeReceipts: true,
            includeUnsynced: true,
            explicitlyApproved: false,
          ),
        ),
        throwsStateError,
      );
    }
    expect(calls, 0);
    client.close();
  });
  test(
    'private workspace deletes copies and links while preserving gallery originals',
    () async {
      final root = await Directory.systemTemp.createTemp(
            'private-recovery-test-',
          ),
          gallery = await Directory.systemTemp.createTemp(
            'gallery-original-test-',
          );
      try {
        final original = File('${gallery.path}/receipt.jpg')
          ..writeAsStringSync('original');
        final workspace = await PrivateTemporaryWorkspace.create(root);
        await workspace.file('copy.jpg').writeAsString('copy');
        await Link(
          '${workspace.directory.path}/gallery-link',
        ).create(original.path);
        expect(() => workspace.file('../receipt.jpg'), throwsFormatException);
        expect(await workspace.cleanup(), isTrue);
        expect(await original.readAsString(), 'original');
        expect(await workspace.directory.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
        await gallery.delete(recursive: true);
      }
    },
  );
  test('startup reaper removes only owned inactive stale directories', () async {
    final root = await Directory.systemTemp.createTemp('private-reaper-test-');
    try {
      final unrelated = Directory('${root.path}/gallery')..createSync(),
          active = await PrivateTemporaryWorkspace.create(root);
      expect(
        await PrivateTemporaryWorkspace.reapStale(
          root,
          now: DateTime.now().add(const Duration(days: 2)),
        ),
        0,
      );
      expect(await active.cleanup(), isTrue);
      final token = List.filled(32, 'a').join(),
          stale = Directory(
            '${root.path}/${PrivateTemporaryWorkspace.prefix}${List.filled(32, 'a').join()}',
          )..createSync();
      await File(
        '${stale.path}/${PrivateTemporaryWorkspace.markerName}',
      ).writeAsString(
        jsonEncode({
          'version': 1,
          'token': token,
          'created_at': DateTime.now()
              .subtract(const Duration(days: 2))
              .toUtc()
              .toIso8601String(),
        }),
      );
      expect(await PrivateTemporaryWorkspace.reapStale(root), 1);
      expect(await unrelated.exists(), isTrue);
      expect(await stale.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'recovery retry reads retained original ciphertext and HTTPS prevents remote key exposure',
    () async {
      Map<String, dynamic>? stored;
      var posts = 0;
      var reads = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          posts++;
          if (stored != null) return http.Response('{}', 409);
          final n = ByteData.sublistView(request.bodyBytes).getUint32(0);
          final m =
              jsonDecode(utf8.decode(request.bodyBytes.sublist(4, 4 + n)))
                  as Map<String, dynamic>;
          final encrypted = request.bodyBytes.sublist(4 + n);
          stored = {
            ...m,
            'account_id': account,
            'encrypted_archive': base64Encode(encrypted),
            'archive_sha256': sha256.convert(encrypted).toString(),
          };
          return http.Response(
            jsonEncode({
              'snapshot_id': snapshot,
              'archive_sha256': stored!['archive_sha256'],
            }),
            201,
          );
        }
        reads++;
        return http.Response(jsonEncode(stored), 200);
      });
      AccountRecoveryRepository repository(String origin) =>
          AccountRecoveryRepository(
            apiBaseUrl: Uri.parse(origin),
            accountId: account,
            accessToken: () async => 'token',
            client: client,
            enabled: true,
          );
      const consent = AccountRecoveryConsent(
        includeReceipts: true,
        includeUnsynced: true,
        explicitlyApproved: true,
      );
      final source = localPayload('same pending snapshot');
      await repository('https://api.example.test').upload(
        snapshotId: snapshot,
        plaintextArchive: source,
        consent: consent,
      );
      await repository('https://api.example.test').upload(
        snapshotId: snapshot,
        plaintextArchive: source,
        consent: consent,
      );
      expect(posts, 2);
      expect(reads, 2);
      await expectLater(
        repository('https://api.example.test').upload(
          snapshotId: snapshot,
          plaintextArchive: localPayload('changed snapshot'),
          consent: consent,
        ),
        throwsStateError,
      );
      await expectLater(
        repository('http://remote.example.test').upload(
          snapshotId: snapshot,
          plaintextArchive: source,
          consent: consent,
        ),
        throwsFormatException,
      );
      expect(posts, 3);
      client.close();
    },
  );

  test(
    'account SQLite recovery preserves unsynced UUIDs and receipt bytes without replacing existing history',
    () async {
      final storage = await Directory.systemTemp.createTemp('recovery-sqlite-');
      AppDatabase database(String name) {
        final owner = AppDatabase.openFile('${storage.path}/$name.sqlite');
        final db = owner.db;
        // Deliberately small versioned schema fixture; the native lease still
        // comes from a real, separately opened, file-backed AppDatabase.
        for (final row in db.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )) {
          db.execute('DROP TABLE "${row['name']}"');
        }
        db.execute(
          'CREATE TABLE financial_entities(namespace TEXT,entity TEXT,id TEXT,payload TEXT,pending INTEGER,PRIMARY KEY(namespace,entity,id)); CREATE TABLE sync_pending_changes(namespace TEXT,id TEXT,mutation_id TEXT,in_flight INTEGER); CREATE TABLE transaction_attachments(id TEXT PRIMARY KEY,transaction_id TEXT,file_name TEXT,local_path TEXT); CREATE TABLE cached_responses(key TEXT,raw_json TEXT);',
        );
        return owner;
      }

      final sourceOwner = database('source'), targetOwner = database('target');
      final source = sourceOwner.db, target = targetOwner.db;
      final private = await Directory.systemTemp.createTemp(
            'recovery-restore-',
          ),
          gallery = await Directory.systemTemp.createTemp('recovery-gallery-');
      try {
        final receipt = File('${gallery.path}/original.jpg')
          ..writeAsBytesSync([1, 2, 3, 4]);
        source.execute(
          "INSERT INTO financial_entities VALUES('user:$account','transactions','original-txn','pending-payload',1),('different','transactions','other-txn','private-other-account',0)",
        );
        source.execute(
          "INSERT INTO sync_pending_changes VALUES('user:$account','queue-id','stable-mutation-id',1)",
        );
        source.execute('INSERT INTO transaction_attachments VALUES(?,?,?,?)', [
          'receipt-id',
          'original-txn',
          'original.jpg',
          receipt.path,
        ]);
        source.execute(
          "INSERT INTO cached_responses VALUES('private-cache','private-other-account')",
        );
        final bytes = await sourceOwner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.capture(
            lease: lease,
            accountId: account,
            namespace: 'user:$account',
            includeReceipts: true,
          ),
        );
        expect(utf8.decode(bytes).contains('private-other-account'), isFalse);
        await expectLater(
          sourceOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.capture(
              lease: lease,
              accountId: other,
              namespace: 'user:$account',
              includeReceipts: true,
            ),
          ),
          throwsFormatException,
        );
        source.execute(
          "INSERT INTO financial_entities VALUES('user:$other','transactions','original-txn','ambiguous',0)",
        );
        await expectLater(
          sourceOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.capture(
              lease: lease,
              accountId: account,
              namespace: 'user:$account',
              includeReceipts: true,
            ),
          ),
          throwsFormatException,
        );
        source.execute(
          "DELETE FROM financial_entities WHERE namespace='user:$other'",
        );
        target.execute(
          "INSERT INTO financial_entities VALUES('user:$other','transactions','original-txn','foreign-history',0)",
        );
        await expectLater(
          targetOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
              lease: lease,
              payload: bytes,
              accountId: account,
              namespace: 'user:$account',
              attachmentsDirectory: private,
            ),
          ),
          throwsFormatException,
        );
        expect(
          target
              .select('SELECT payload FROM financial_entities')
              .single['payload'],
          'foreign-history',
        );
        target.execute(
          "DELETE FROM financial_entities WHERE namespace='user:$other'",
        );

        await targetOwner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
            lease: lease,
            payload: bytes,
            accountId: account,
            namespace: 'user:$account',
            attachmentsDirectory: private,
          ),
        );
        final pending = target
            .select('SELECT * FROM sync_pending_changes')
            .single;
        expect(pending['mutation_id'], 'stable-mutation-id');
        expect(pending['in_flight'], 0);
        expect(
          target
              .select('SELECT id,pending FROM financial_entities')
              .single['id'],
          'original-txn',
        );
        final installed = File(
          target
                  .select('SELECT local_path FROM transaction_attachments')
                  .single['local_path']
              as String,
        );
        expect(await installed.readAsBytes(), [1, 2, 3, 4]);
        expect(await receipt.readAsBytes(), [1, 2, 3, 4]);
        await expectLater(
          targetOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
              lease: lease,
              payload: bytes,
              accountId: account,
              namespace: 'user:$account',
              attachmentsDirectory: private,
            ),
          ),
          throwsStateError,
        );
        source.execute(
          'CREATE TABLE unknown_unscoped(secret TEXT); INSERT INTO unknown_unscoped VALUES(\'ambiguous\')',
        );
        await expectLater(
          sourceOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.capture(
              lease: lease,
              accountId: account,
              namespace: 'user:$account',
              includeReceipts: true,
            ),
          ),
          throwsFormatException,
        );
      } finally {
        sourceOwner.close();
        targetOwner.close();
        await storage.delete(recursive: true);
        await private.delete(recursive: true);
        await gallery.delete(recursive: true);
      }
    },
  );

  test('account and consent scopes are checked before upload', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 500);
    });
    final repository = AccountRecoveryRepository(
      apiBaseUrl: Uri.parse('https://api.example.test'),
      accountId: account,
      accessToken: () async => 'token',
      client: client,
      enabled: true,
    );
    for (final consent in [
      const AccountRecoveryConsent(
        includeReceipts: false,
        includeUnsynced: true,
        explicitlyApproved: true,
      ),
      const AccountRecoveryConsent(
        includeReceipts: true,
        includeUnsynced: false,
        explicitlyApproved: true,
      ),
    ]) {
      await expectLater(
        repository.upload(
          snapshotId: snapshot,
          plaintextArchive: localPayload('private'),
          consent: consent,
        ),
        throwsFormatException,
      );
    }
    final wrong =
        jsonDecode(utf8.decode(localPayload('private')))
            as Map<String, dynamic>;
    wrong['namespace'] = 'user:$other';
    await expectLater(
      repository.upload(
        snapshotId: snapshot,
        plaintextArchive: Uint8List.fromList(utf8.encode(jsonEncode(wrong))),
        consent: const AccountRecoveryConsent(
          includeReceipts: true,
          includeUnsynced: true,
          explicitlyApproved: true,
        ),
      ),
      throwsFormatException,
    );
    expect(calls, 0);
    client.close();
  });
}
