import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:sqlite3/sqlite3.dart';

// Every message, name and number is invented. Fixed clock.
void main() {
  late AppDatabase db;
  late SmsIntakeRepository intake;
  late OutboxStore queue;
  late SyncStateStore state;
  var now = DateTime.utc(2026, 11);

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    SmsV2Schema.ensure(db.db);
    intake = SmsIntakeRepository(db);
    queue = OutboxStore(db.db, namespace: 'a');
    state = SyncStateStore(db.db, namespace: 'a');
    now = DateTime.utc(2026, 11);
  });
  tearDown(() => db.db.dispose());

  void open(String body, {String sender = 'HDFCBK'}) {
    final source = smsSourceKey('a', sender, body);
    intake.remember('a', QueuedSms(sender: sender, body: body, receivedAt: now));
    db.db.execute('INSERT OR IGNORE INTO v2_review_items VALUES(?,?,?,?,?)', [
      'a', source, 'template', jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
    ]);
  }

  String plain(int i) => 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
  int words(Map item) => 'info'.allMatches(item['redactedBody'] as String).length;

  TemplateUpload uploader(Future<http.Response> Function(List<Map> items) answer) => TemplateUpload(
    intake: intake,
    queue: queue,
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {},
    hasConsent: () async => true,
    accountIsCurrent: () => true,
    clock: () => now,
    client: MockClient((request) async => answer(((jsonDecode(request.body) as Map)['items'] as List).cast<Map>())),
  );

  Future<http.Response> acceptAll(List<Map> items) async =>
      http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);

  int outboxCount() => db.db.select("SELECT count(*) n FROM v2_outbox WHERE kind='template'").first['n'] as int;
  int sentMarks() => db.db.select("SELECT count(*) n FROM v2_sync_state WHERE key LIKE 'template:sent:%'").first['n'] as int;

  group('F6: one layout the server fails on does not block its neighbours', () {
    test('after a 5xx on a batch the layouts go one to a request, so the poison one fails alone', () async {
      for (var i = 1; i <= 6; i++) {
        open(plain(i));
      }
      final sizes = <int>[];
      final up = uploader((items) async {
        sizes.add(items.length);
        return items.any((i) => words(i) == 3) ? http.Response('boom', 500) : acceptAll(items);
      });
      await up.drain();
      expect(sizes, [6], reason: 'the first attempt is a batch; it fails and waits');
      expect(sentMarks(), 0);
      now = now.add(const Duration(minutes: 2));
      sizes.clear();
      await up.drain();
      expect(sentMarks(), 5, reason: 'the five innocent layouts went up');
      expect(outboxCount(), 1, reason: 'the poison layout is kept, and waits on its own');
      expect(sizes.every((n) => n == 1), isTrue, reason: '$sizes');
    });

    test('a 503 that names a Retry-After is an outage, not a layout: the next attempt is a batch again', () async {
      for (var i = 1; i <= 4; i++) {
        open(plain(i));
      }
      final sizes = <int>[];
      final up = uploader((items) async {
        sizes.add(items.length);
        return http.Response('paused', 503, headers: {'retry-after': '3600'});
      });
      await up.drain();
      now = now.add(const Duration(hours: 2));
      await up.drain();
      expect(sizes, [4, 4]);
      expect(db.db.select("SELECT 1 FROM v2_sync_state WHERE key='template:solo:at'"), isEmpty);
    });

    test('a 413 on a batch is isolated at once, like a 400, and the others are accepted', () async {
      for (var i = 1; i <= 5; i++) {
        open(plain(i));
      }
      final up = uploader((items) async {
        if (items.length > 1 || items.any((i) => words(i) == 2)) return http.Response('too large', 413);
        return acceptAll(items);
      });
      await up.drain();
      expect(sentMarks(), 4);
      expect(outboxCount(), 1);
      expect(db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'template:refused:%'"), hasLength(1));
    });

    test('a request never carries more than about 60 KB of layouts', () async {
      for (var i = 0; i < 12; i++) {
        open(plain(1000 + i * 7));
      }
      final bodies = <int>[];
      final up = uploader((items) async {
        bodies.add(jsonEncode({'items': items}).length);
        return acceptAll(items);
      });
      await up.drain();
      expect(sentMarks(), 12, reason: 'all went up, in more than one request');
      expect(bodies.length, greaterThan(1));
      expect(bodies.every((n) => n <= 60 * 1024), isTrue, reason: '$bodies');
    });
  });

  group('F9: layouts the server forgot', () {
    String hashOfOnly() =>
        (db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'template:sent:%'").single['key'] as String).substring('template:sent:'.length);

    test('a layout sent more than a day ago with no answer at all is sent again, at most once a week', () async {
      open(plain(2));
      var posts = 0;
      final up = uploader((items) async {
        posts += items.length;
        return acceptAll(items);
      });
      await up.drain();
      expect(posts, 1);
      now = now.add(const Duration(hours: 5));
      await up.drain();
      expect(posts, 1, reason: 'too soon: the server may still be reading it');
      now = now.add(const Duration(days: 2));
      await up.drain();
      expect(posts, 2, reason: 'a day and more, no answer: sent again');
      // The server forgot it again right away: not looked at again for a week.
      now = now.add(const Duration(days: 3));
      await up.drain();
      expect(posts, 2);
      now = now.add(const Duration(days: 5));
      await up.drain();
      expect(posts, 3, reason: 'a week on, looked at again');
      expect(db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'ai:%'"), isEmpty, reason: 'the run is recorded under template:');
      expect(state.get('template:sentcheck:at'), isNotNull);
    });

    test('a layout that has any answer is not sent again', () async {
      open(plain(2));
      var posts = 0;
      final up = uploader((items) async {
        posts += items.length;
        return acceptAll(items);
      });
      await up.drain();
      state.put('ai:${hashOfOnly()}', jsonEncode({'status': 'ready'}));
      now = now.add(const Duration(days: 9));
      await up.drain();
      expect(posts, 1);
    });

    test('a look clears at most 50 marks and is repeated the next day', () async {
      for (var i = 1; i <= 60; i++) {
        open(plain(i));
      }
      final up = uploader(acceptAll);
      for (var i = 0; i < 4; i++) {
        await up.drain(); // 60 layouts read over a few passes and sent
      }
      expect(sentMarks(), 60);
      now = now.add(const Duration(days: 2));
      await up.drain();
      // 50 were cleared and sent again (fresh marks); the 10 left keep their old ones.
      bool old(Row r) => DateTime.parse(r['value'] as String).isBefore(now.subtract(const Duration(hours: 25)));
      final marks = db.db.select("SELECT value FROM v2_sync_state WHERE key LIKE 'template:sent:%'");
      expect(marks.where(old), hasLength(10));
      now = now.add(const Duration(days: 1, minutes: 1));
      await up.drain();
      expect(db.db.select("SELECT value FROM v2_sync_state WHERE key LIKE 'template:sent:%'").where(old), isEmpty,
          reason: 'the rest follow a day later, not a week later');
    });
  });
}
