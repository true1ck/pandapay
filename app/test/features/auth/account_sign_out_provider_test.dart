import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/auth/account_sign_out_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('readPhoneOnlyCounts', () {
    test('counts receipts, queued SMS facts and open review items', () {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final db = database.db;
      db.execute('''CREATE TABLE v2_outbox (namespace TEXT, id TEXT, kind TEXT,
        payload TEXT, attempts INTEGER, next_attempt_at INTEGER)''');
      db.execute(
        '''CREATE TABLE v2_review_items (namespace TEXT, review_id TEXT,
        kind TEXT, payload TEXT, status TEXT)''',
      );
      db.execute(
        "INSERT INTO v2_outbox VALUES ('user:a','f1','fact','{}',0,0),"
        "('user:a','f2','fact','{}',0,0),('user:b','f3','fact','{}',0,0)",
      );
      db.execute(
        "INSERT INTO v2_review_items VALUES ('user:a','r1','k','{}','open'),"
        "('user:a','r2','k','{}','resolved'),('user:b','r3','k','{}','open')",
      );
      db.execute(
        "INSERT INTO transaction_attachments VALUES "
        "('1','t1','a.jpg','/x/a.jpg','image/jpeg',1),"
        "('2','t2','b.jpg','/x/b.jpg','image/jpeg',2)",
      );

      final counts = readPhoneOnlyCounts(db, 'user:a');

      expect(counts.smsOutbox, 2);
      expect(counts.receipts, 2);
      expect(counts.reviewItems, 1);
    });

    test('missing SMS tables count as zero', () {
      final database = openInMemoryForTesting();
      addTearDown(database.close);

      final counts = readPhoneOnlyCounts(database.db, 'user:a');

      expect(counts.smsOutbox, 0);
      expect(counts.reviewItems, 0);
      expect(counts.receipts, 0);
    });
  });

  test('wipeAccountFiles removes the database, receipts and cache', () async {
    final root = await Directory.systemTemp.createTemp('wipe_test');
    addTearDown(() => root.delete(recursive: true));
    final documents = Directory(p.join(root.path, 'documents'))..createSync();
    final cache = Directory(p.join(root.path, 'cache'))..createSync();
    for (final name in [
      'pandapay.sqlite',
      'pandapay.sqlite-wal',
      'pandapay.sqlite-shm',
      'unrelated.txt',
    ]) {
      File(p.join(documents.path, name)).writeAsStringSync('x');
    }
    Directory(
      p.join(documents.path, 'transaction_attachments', 't1'),
    ).createSync(recursive: true);
    File(
      p.join(documents.path, 'transaction_attachments', 't1', 'r.jpg'),
    ).writeAsStringSync('x');
    File(p.join(cache.path, 'old.bin')).writeAsStringSync('x');

    await wipeAccountFiles(documents: documents, cache: cache);

    final left = documents.listSync().map((e) => p.basename(e.path)).toList();
    expect(left, ['unrelated.txt']);
    expect(cache.existsSync(), isTrue);
    expect(cache.listSync(), isEmpty);
  });

  test('clearPreferencesExcept keeps only the preserved keys', () async {
    SharedPreferences.setMockInitialValues({
      'install_marker': 'yes',
      'pandapay_app.access_token_hint': true,
      'biometric_lock_enabled_v1': true,
    });
    final prefs = await SharedPreferences.getInstance();

    await clearPreferencesExcept(prefs, {'install_marker'});

    expect(prefs.getKeys(), {'install_marker'});
  });
}
