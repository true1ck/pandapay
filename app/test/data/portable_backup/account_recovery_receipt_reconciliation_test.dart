import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_local_snapshot.dart';

void main() {
  late Directory temp;
  late Directory attachments;
  late AppDatabase owner;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recovery-reconcile-');
    attachments = Directory('${temp.path}/attachments')..createSync();
    owner = AppDatabase.openFile('${temp.path}/local.sqlite');
    for (final row in owner.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    )) {
      owner.db.execute('DROP TABLE "${row['name']}"');
    }
    owner.db.execute(
      'CREATE TABLE transaction_attachments(id TEXT, local_path TEXT); '
      'CREATE TABLE other_references(value TEXT);',
    );
  });

  tearDown(() async {
    owner.close();
    await temp.delete(recursive: true);
  });

  Future<int> reconcile() => owner.withRecoveryDatabase(
    (lease) => AccountRecoveryLocalSnapshot.reconcileOrphanedReceipts(
      lease: lease,
      attachmentsDirectory: attachments,
    ),
  );

  Future<File> journaledFile(String suffix) async {
    final directory = Directory('${attachments.path}/account_recovery_receipts')
      ..createSync();
    final name = 'receipt-${suffix.padLeft(32, '0')}.bin';
    final file = File('${directory.path}/$name')..writeAsBytesSync([1, 2, 3]);
    File('${directory.path}/.receipt-intents.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'files': [name],
      }),
    );
    return file;
  }

  test('deletes a journaled orphan in the recovery-owned directory', () async {
    final file = await journaledFile('a');

    expect(await reconcile(), 1);
    expect(await file.exists(), isFalse);
  });

  test('preserves files referenced by any table and namespace', () async {
    final file = await journaledFile('b');
    owner.db.execute('INSERT INTO transaction_attachments VALUES(?, ?)', [
      'other-account-receipt',
      await file.resolveSymbolicLinks(),
    ]);

    expect(await reconcile(), 0);
    expect(await file.exists(), isTrue);
  });

  test('checks path references outside the attachment table too', () async {
    final file = await journaledFile('f');
    owner.db.execute('INSERT INTO other_references VALUES(?)', [
      await file.resolveSymbolicLinks(),
    ]);

    expect(await reconcile(), 0);
    expect(await file.exists(), isTrue);
  });

  test('retains a basename embedded in pending JSON or BLOB values', () async {
    final file = await journaledFile('3');
    owner.db.execute('CREATE TABLE pending_outbox(payload TEXT, raw BLOB)');
    owner.db.execute('INSERT INTO pending_outbox VALUES(?, ?)', [
      jsonEncode({'receipt': file.path.split('/').last}),
      utf8.encode('pending:${file.path.split('/').last}'),
    ]);

    expect(await reconcile(), 0);
    expect(await file.exists(), isTrue);
  });

  test(
    'preflights every candidate before deleting an earlier orphan',
    () async {
      final directory = Directory(
        '${attachments.path}/account_recovery_receipts',
      )..createSync();
      final firstName = 'receipt-${'1' * 32}.bin';
      final secondName = 'receipt-${'2' * 32}.bin';
      final first = File('${directory.path}/$firstName')..writeAsBytesSync([1]);
      final target = File('${temp.path}/gallery-original.jpg')
        ..writeAsBytesSync([9]);
      Link('${directory.path}/$secondName').createSync(target.path);
      File('${directory.path}/.receipt-intents.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'files': [firstName, secondName],
        }),
      );

      await expectLater(reconcile(), throwsFormatException);
      expect(await first.exists(), isTrue);
      expect(await target.readAsBytes(), [9]);
    },
  );

  test('refuses an oversized journal without deleting its candidate', () async {
    final file = await journaledFile('4');
    File(
      '${file.parent.path}/.receipt-intents.json',
    ).writeAsStringSync(' ' * (32 * 1024 + 1));

    await expectLater(reconcile(), throwsFormatException);
    expect(await file.exists(), isTrue);
  });

  test('refuses over-budget schemas before deleting any candidates', () async {
    final file = await journaledFile('5');
    for (var index = 0; index < 129; index++) {
      owner.db.execute('CREATE TABLE extra_$index(value TEXT)');
    }

    await expectLater(reconcile(), throwsFormatException);
    expect(await file.exists(), isTrue);
  });

  test(
    'rejects an unsafe journal temp symlink before deleting candidates',
    () async {
      final file = await journaledFile('6');
      final target = File('${temp.path}/user-journal')
        ..writeAsStringSync('keep');
      Link(
        '${file.parent.path}/.receipt-intents.json.tmp',
      ).createSync(target.path);

      await expectLater(reconcile(), throwsFormatException);
      expect(await file.exists(), isTrue);
      expect(await target.readAsString(), 'keep');
    },
  );

  test(
    'refuses a symlinked owned directory without touching its target',
    () async {
      final external = Directory('${temp.path}/external-receipts')
        ..createSync();
      final target = File('${external.path}/receipt-${'k' * 32}.bin')
        ..writeAsBytesSync([7]);
      final root = Directory('${attachments.path}/account_recovery_receipts');
      Link(root.path).createSync(external.path);

      await expectLater(reconcile(), throwsFormatException);
      expect(await target.readAsBytes(), [7]);
    },
  );

  test(
    'preserves all candidates when the intent journal is malformed',
    () async {
      final file = await journaledFile('c');
      File('${file.parent.path}/.receipt-intents.json').writeAsStringSync('{');

      await expectLater(reconcile(), throwsFormatException);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'opaque binary references conservatively preserve all candidates',
    () async {
      final file = await journaledFile('a');
      owner.db.execute('INSERT INTO other_references VALUES(?)', [
        Uint8List.fromList([0, 1, 2]),
      ]);
      expect(await reconcile(), 0);
      expect(await file.exists(), isTrue);
    },
  );

  test('ignores unjournaled names and symlinks', () async {
    final directory = Directory('${attachments.path}/account_recovery_receipts')
      ..createSync();
    final unjournaled = File('${directory.path}/receipt-${'d' * 32}.bin')
      ..writeAsBytesSync([4]);
    final target = File('${temp.path}/gallery-original.jpg')
      ..writeAsBytesSync([5]);
    final link = Link('${directory.path}/receipt-${'e' * 32}.bin')
      ..createSync(target.path);
    File('${directory.path}/.receipt-intents.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'files': [link.path.split('/').last],
      }),
    );

    await expectLater(reconcile(), throwsFormatException);
    expect(await unjournaled.exists(), isTrue);
    expect(await target.readAsBytes(), [5]);
    expect(await link.exists(), isTrue);
  });
}
