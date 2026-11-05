import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/storage_paths.dart';

void main() {
  late Directory support;
  late List<String> excluded;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('support');
    excluded = [];
  });
  tearDown(() => support.delete(recursive: true));

  Future<StoragePaths> make() => StoragePaths.create(
    supportDirectory: () async => support,
    excludeFromBackup: (path) async => excluded.add(path),
  );

  test('all account files live under Application Support/PandaPay', () async {
    final paths = await make();
    expect(paths.databasePath, '${support.path}/PandaPay/pandapay.sqlite');
    expect(paths.receiptsDir.path, '${support.path}/PandaPay/receipts');
    expect(excluded, ['${support.path}/PandaPay']);
  });

  test('wipe deletes everything and re-excludes the empty root', () async {
    final paths = await make();
    await File(paths.databasePath).writeAsString('x');
    await File('${paths.databasePath}-wal').writeAsString('x');
    await paths.receiptsDir.create(recursive: true);
    await File('${paths.receiptsDir.path}/a.bin').writeAsString('x');
    await paths.wipe();
    expect(File(paths.databasePath).existsSync(), isFalse);
    expect(File('${paths.databasePath}-wal').existsSync(), isFalse);
    expect(paths.receiptsDir.existsSync(), isFalse);
    expect(Directory('${support.path}/PandaPay').existsSync(), isTrue);
    expect(excluded.length, 2);
  });

  test('wipe works when the root was never populated or already removed', () async {
    final paths = await make();
    await paths.root.delete(recursive: true);
    await paths.wipe();
    expect(paths.root.existsSync(), isTrue);
    await paths.wipe();
    expect(excluded.length, 3);
  });

  test('a backup exclusion failure surfaces instead of storing unprotected', () async {
    await expectLater(
      StoragePaths.create(
        supportDirectory: () async => support,
        excludeFromBackup: (_) async => throw StateError('exclusion failed'),
      ),
      throwsStateError,
    );
  });

  group('platform configuration', () {
    test('Android blocks cloud backup and device transfer', () {
      final rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      for (final section in ['cloud-backup', 'device-transfer']) {
        final block = RegExp(
          '<$section>(.*?)</$section>',
          dotAll: true,
        ).firstMatch(rules)!.group(1)!;
        for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
          expect(block, contains('<exclude domain="$domain" path="." />'));
        }
        expect(block, isNot(contains('<include')));
      }
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:fullBackupContent="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    });

    test('iOS registers the storage channel in the app and the background engine', () {
      final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final background = File(
        'ios/Runner/SmsImportBackgroundHost.swift',
      ).readAsStringSync();
      final bridge = File('ios/Runner/StorageBackupBridge.swift').readAsStringSync();
      expect(bridge, contains('"pandapay/storage"'));
      expect(bridge, contains('isExcludedFromBackup = true'));
      expect(
        RegExp(r'StorageBackupBridge\.register').allMatches(delegate).length,
        greaterThanOrEqualTo(2),
        reason: 'device and simulator branches',
      );
      expect(background, contains('StorageBackupBridge.register'));
    });
  });
}
