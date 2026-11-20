import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'consent gates a redacted template and revocation prevents a queued retry',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(db.db.dispose);
      SmsV2Schema.ensure(db.db);
      final intake = SmsIntakeRepository(db);
      final now = DateTime.utc(2026, 11);
      const raw =
          'Rs.12345.67 debited from A/c XX6789 to RAHUL SHARMA. Ref 1234567890 https://bank.example.in';
      const sender = 'HDFCBK';
      final source = smsSourceKey('a', sender, raw);
      intake.remember(
        'a',
        QueuedSms(sender: sender, body: raw, receivedAt: now),
      );
      db.db.execute("INSERT INTO v2_review_items VALUES(?,?,?,?,?)", [
        'a',
        source,
        'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}),
        'open',
      ]);
      var consent = false;
      var calls = 0;
      final queue = OutboxStore(db.db, namespace: 'a');
      final uploader = TemplateUpload(
        intake: intake,
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => consent,
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          final item = (jsonDecode(request.body) as Map)['items'].single;
          final redacted = item['redactedBody'] as String;
          expect(redacted, isNot(contains('12345.67')));
          expect(redacted, isNot(contains('6789')));
          expect(item.containsKey('sample'), isFalse, reason: 'wording is not sent until the consent text allows it');
          expect(redacted.toLowerCase(), isNot(contains('rahul')));
          expect(RegExp(r'\d{6,}|https?://').hasMatch(redacted), isFalse);
          return http.Response('{}', 503);
        }),
      );
      await uploader.drain();
      expect(calls, 0);
      expect(queue.due(now), isEmpty);
      consent = true;
      await uploader.drain();
      expect(calls, 1);
      expect(db.db.select('SELECT * FROM v2_outbox'), hasLength(1));
      consent = false;
      await uploader.drain();
      expect(calls, 1);
      expect(
        db.db.select("SELECT * FROM v2_outbox WHERE kind='template'"),
        isEmpty,
      );
    },
  );

  test('the wording goes with the layout, numbers made up and names kept; a queued layout without one goes without', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    const raw =
        'Rs.12345.67 debited from A/c XX6789 to RAHUL SHARMA. Ref 1234567890 https://bank.example.in';
    final source = smsSourceKey('a', 'HDFCBK', raw);
    intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
    db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
      'a',
      source,
      'template',
      jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}),
      'open',
    ]);
    // A layout queued by an older build carries no sample.
    const legacyBody = '<AMT> credited to your account.';
    final legacyHash = smsTemplateHash('HDFCBK', legacyBody);
    final queue = OutboxStore(db.db, namespace: 'a');
    queue.enqueue('template', legacyHash, {
      'templateHash': legacyHash,
      'senderBrand': 'HDFCBK',
      'redactedBody': legacyBody,
      'observedAt': now.toIso8601String(),
    });
    final sent = <Map>[];
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      shareWording: true,
      client: MockClient((request) async {
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        sent.addAll(items.cast<Map>());
        return http.Response(
          jsonEncode({'accepted': [for (final item in items) item['templateHash']]}),
          202,
        );
      }),
    );
    await uploader.drain();
    expect(sent, hasLength(2));
    final withSample = sent.firstWhere((item) => item['templateHash'] != legacyHash);
    final sample = withSample['sample'] as String;
    for (final secret in ['12345', '6789', '1234567890', 'bank.example']) {
      expect(sample.toLowerCase(), isNot(contains(secret)), reason: secret);
    }
    expect(sample, contains('debited from A/c'));
    // The wording keeps the names; the layout it is sent with hides them.
    expect(sample, contains('RAHUL SHARMA'));
    expect(withSample['redactedBody'], isNot(contains('RAHUL')));
    final legacy = sent.firstWhere((item) => item['templateHash'] == legacyHash);
    expect(legacy.containsKey('sample'), isFalse, reason: 'no null is sent for a missing sample');
  });

  test('a 401, a 5xx or a timeout is retried after a flat minute, never pushed out by doubling', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    var now = DateTime.utc(2026, 11);
    const raw = 'Alert info Rs.500.00 debited from A/c XX6789';
    final source = smsSourceKey('a', 'HDFCBK', raw);
    intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
    db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
      'a',
      source,
      'template',
      jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}),
      'open',
    ]);
    var calls = 0;
    Object? failure = 401;
    final queue = OutboxStore(db.db, namespace: 'a');
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        calls++;
        final fault = failure;
        if (fault is int) return http.Response('{}', fault);
        if (fault == 'timeout') throw http.ClientException('connection dropped');
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        return http.Response(
          jsonEncode({'accepted': [for (final item in items) item['templateHash']]}),
          202,
        );
      }),
    );
    // Five failures of three kinds in a row: each one is due again 60 seconds later.
    for (final kind in <Object>[401, 503, 'timeout', 401, 503]) {
      failure = kind;
      await uploader.drain();
      expect(queue.due(now), isEmpty, reason: 'it waits after a failure ($kind)');
      now = now.add(const Duration(seconds: 61));
      expect(queue.due(now), hasLength(1), reason: 'and is due a minute later ($kind)');
    }
    expect(calls, 5);
    failure = 'ok';
    await uploader.drain();
    expect(queue.due(now), isEmpty);
    expect(db.db.select("SELECT * FROM v2_outbox WHERE kind='template'"), isEmpty);
    expect(queue.hasDue(now), isFalse);
  });

  test('one layout the server refuses (400) is set aside; the rest of the inbox still goes up', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    for (var i = 1; i <= 25; i++) {
      final raw = 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a', source, 'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
      ]);
    }
    bool isPoison(Map item) => 'info'.allMatches(item['redactedBody'] as String).length == 3;
    var requests = 0;
    final accepted = <String>{};
    final queue = OutboxStore(db.db, namespace: 'a');
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        requests++;
        final items = ((jsonDecode(request.body) as Map)['items'] as List).cast<Map>();
        if (items.any(isPoison)) return http.Response('{"error":"template_invalid"}', 400);
        accepted.addAll(items.map((item) => item['templateHash'] as String));
        return http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);
      }),
    );
    await uploader.drain();
    expect(accepted, hasLength(24), reason: 'every layout but the refused one is sent in the same pass');
    final left = db.db.select("SELECT * FROM v2_outbox WHERE kind='template'");
    expect(left, hasLength(1), reason: 'the refused layout is kept, not lost');
    expect(queue.due(now), isEmpty, reason: 'and it is not retried straight away');
    expect(queue.due(now.add(const Duration(hours: 7))), hasLength(1));
    expect(requests, lessThan(40), reason: 'finding it costs a few requests, not one per layout every pass');
  });

  test('a server that refuses everything with 400 is given up on after a few requests', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    for (var i = 1; i <= 40; i++) {
      final raw = 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a', source, 'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
      ]);
    }
    var requests = 0;
    final uploader = TemplateUpload(
      intake: intake,
      queue: OutboxStore(db.db, namespace: 'a'),
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 400);
      }),
    );
    await uploader.drain();
    expect(requests, lessThanOrEqualTo(6), reason: 'it gives up after six refusals');
  });

  test('a 503 with Retry-After is waited out (a paused intake says an hour), never under a minute', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    var now = DateTime.utc(2026, 11);
    const raw = 'Alert info Rs.500.00 debited from A/c XX6789';
    final source = smsSourceKey('a', 'HDFCBK', raw);
    intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
    db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
      'a', source, 'template',
      jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
    ]);
    final queue = OutboxStore(db.db, namespace: 'a');
    var retryAfter = '3600';
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async => http.Response('{"error":"learning_paused"}', 503, headers: {'retry-after': retryAfter})),
    );
    await uploader.drain();
    now = now.add(const Duration(minutes: 30));
    expect(queue.due(now), isEmpty, reason: 'the server asked for an hour');
    now = now.add(const Duration(minutes: 31));
    expect(queue.due(now), hasLength(1));
    retryAfter = '5';
    await uploader.drain();
    expect(queue.due(now.add(const Duration(seconds: 30))), isEmpty, reason: 'never under a minute');
    expect(queue.due(now.add(const Duration(seconds: 61))), hasLength(1));
  });

  test('consent is asked of the server once per few seconds, not three times for every batch', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    for (var i = 1; i <= 60; i++) {
      final raw = 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a', source, 'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
      ]);
    }
    var consentReads = 0;
    var uploads = 0;
    final uploader = TemplateUpload(
      intake: intake,
      queue: OutboxStore(db.db, namespace: 'a'),
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async {
        consentReads++;
        return true;
      },
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        uploads++;
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        return http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);
      }),
    );
    await uploader.drain();
    expect(uploads, 6);
    expect(consentReads, lessThanOrEqualTo(2), reason: 'it was 3 per batch: 18 for these 6 batches');
    consentReads = 0;
    await uploader.drain();
    expect(consentReads, greaterThanOrEqualTo(1), reason: 'a new pass always asks again');
  });

  test('after an update, waits an older build left (a six-hour hold, a 30-minute back-off) no longer keep layouts unsent', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    var now = DateTime.utc(2026, 11);
    for (var i = 1; i <= 12; i++) {
      final raw = 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a', source, 'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
      ]);
    }
    final queue = OutboxStore(db.db, namespace: 'a');
    var calls = 0;
    var status = 202;
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        calls++;
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        if (status != 202) return http.Response('{}', status, headers: {'retry-after': '3600'});
        return http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);
      }),
    );
    // Queue the layouts, then leave them as the old build would have: a six-hour hold and a far-off try.
    status = 500;
    await uploader.drain();
    db.db.execute("DELETE FROM v2_sync_state WHERE namespace='a' AND key='template:waits:cleared:v2'");
    db.db.execute("UPDATE v2_outbox SET next_attempt_at=? WHERE namespace='a' AND kind='template'", [now.add(const Duration(hours: 5)).millisecondsSinceEpoch]);
    SyncStateStore(db.db, namespace: 'a').put('template:wait', now.add(const Duration(hours: 6)).toIso8601String());
    status = 202;
    calls = 0;
    await uploader.drain();
    expect(calls, greaterThan(0), reason: 'the update makes them due now');
    expect(db.db.select("SELECT * FROM v2_outbox WHERE kind='template'"), isEmpty);
    // The clean-up runs once: a hold the new build sets itself is respected.
    final again = DateTime.utc(2026, 11, 2);
    now = again;
    status = 429;
    for (var i = 1; i <= 3; i++) {
      final raw = 'Notice ${List.filled(i, 'memo').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', ['a', source, 'template', jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open']);
    }
    await uploader.drain();
    calls = 0;
    await uploader.drain();
    expect(calls, 0, reason: 'the 429 hold set by this build is not cleared again');
  });

  test('a pass skips items already queued or sent (no re-redaction of a long backlog); a re-send still queues them again', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    for (var i = 1; i <= 300; i++) {
      final raw = 'Alert ${List.filled(1 + i % 60, 'info').join(' ')} w${i % 7} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw + '$i');
      intake.remember('a', QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now));
      db.db.execute('INSERT OR IGNORE INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a', smsSourceKey('a', 'HDFCBK', raw), 'template',
        jsonEncode({'sourceKey': smsSourceKey('a', 'HDFCBK', raw), 'templateHash': 'a' * 64}), 'open',
      ]);
      source.length;
    }
    final queue = OutboxStore(db.db, namespace: 'a');
    var server = 503;
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        if (server != 202) return http.Response('{}', server);
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        return http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);
      }),
    );
    await uploader.drain();
    final queued = db.db.select("SELECT count(*) n FROM v2_outbox WHERE kind='template'").first['n'] as int;
    expect(queued, greaterThan(0));
    final sw = Stopwatch()..start();
    await uploader.drain();
    final second = sw.elapsedMilliseconds;
    expect(db.db.select("SELECT count(*) n FROM v2_outbox WHERE kind='template'").first['n'], queued, reason: 'nothing doubled');
    // Everything is sent; then the person re-sends (held layouts): the items are queued again.
    server = 202;
    db.db.execute("UPDATE v2_outbox SET next_attempt_at=0 WHERE kind='template'");
    await uploader.drain();
    expect(db.db.select("SELECT count(*) n FROM v2_outbox WHERE kind='template'").first['n'], 0);
    db.db.execute("DELETE FROM v2_sync_state WHERE namespace='a' AND key LIKE 'template:sent:%'");
    await uploader.drain();
    expect(db.db.select("SELECT count(*) n FROM v2_sync_state WHERE namespace='a' AND key LIKE 'template:sent:%'").first['n'], queued,
        reason: 'after a re-send every layout goes up again');
    expect(second, lessThan(2000));
  });

  test('layouts go in batches of at most ten, and a 429 is waited out', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    var now = DateTime.utc(2026, 11);
    // Each layout differs in how many plain words it has, so every one has its
    // own skeleton (merchant-like words are masked and would all collapse).
    for (var i = 1; i <= 25; i++) {
      final raw =
          'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';
      final source = smsSourceKey('a', 'HDFCBK', raw);
      intake.remember(
        'a',
        QueuedSms(sender: 'HDFCBK', body: raw, receivedAt: now),
      );
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a',
        source,
        'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}),
        'open',
      ]);
    }
    final sizes = <int>[];
    var status = 429;
    final queue = OutboxStore(db.db, namespace: 'a');
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        sizes.add(items.length);
        if (status == 429) {
          return http.Response(
            '{"error":"template_daily_cap"}',
            429,
            headers: {'retry-after': '86400'},
          );
        }
        return http.Response(
          jsonEncode({
            'accepted': [for (final item in items) item['templateHash']],
          }),
          202,
        );
      }),
    );
    // Over the allowance: one small request, then it waits (no retry storm).
    await uploader.drain();
    expect(sizes, [10]);
    await uploader.drain();
    expect(sizes, [10], reason: 'nothing is sent again straight away');
    now = now.add(const Duration(seconds: 90));
    await uploader.drain();
    expect(sizes, [
      10,
    ], reason: 'still inside the two minutes: the server asked for a day, the phone waits at most 2 minutes');
    // Once the wait is over and the server accepts, everything goes in tens.
    now = now.add(const Duration(seconds: 40));
    status = 202;
    await uploader.drain();
    expect(sizes.skip(1), [10, 10, 5]);
    expect(sizes.every((n) => n <= 10), isTrue);
  });

  test(
    'a message waiting on history is never sent for AI rule drafting',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(db.db.dispose);
      SmsV2Schema.ensure(db.db);
      final intake = SmsIntakeRepository(db);
      final now = DateTime.utc(2026, 11);
      const sender = 'HDFCBK';
      const reminder =
          'Reminder: your credit card bill of Rs 23,540 is due. Pay on or before the due date.';
      const ordinary =
          'Your Sample Bank account was updated with a new feature.';
      final held = smsSourceKey('a', sender, reminder);
      final normal = smsSourceKey('a', sender, ordinary);
      intake.remember(
        'a',
        QueuedSms(sender: sender, body: reminder, receivedAt: now),
      );
      intake.remember(
        'a',
        QueuedSms(sender: sender, body: ordinary, receivedAt: now),
      );
      for (final (key, payload) in [
        (
          held,
          {'sourceKey': held, 'templateHash': 'a' * 64, 'aiHold': 'history'},
        ),
        (normal, {'sourceKey': normal, 'templateHash': 'b' * 64}),
      ]) {
        db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
          'a',
          key,
          'template',
          jsonEncode(payload),
          'open',
        ]);
      }
      final sent = <String>[];
      final queue = OutboxStore(db.db, namespace: 'a');
      final uploader = TemplateUpload(
        intake: intake,
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => true,
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          for (final item
              in (jsonDecode(request.body) as Map)['items'] as List) {
            sent.add((item as Map)['redactedBody'] as String);
          }
          return http.Response('{}', 503);
        }),
      );
      await uploader.drain();
      expect(sent.join(' ').toLowerCase(), contains('feature'));
      expect(sent.join(' ').toLowerCase(), isNot(contains('credit card bill')));
    },
  );

  test(
    'consented safe hash maps authenticated private rules back to original formats',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(db);
      addTearDown(() {
        financial.dispose();
        db.db.dispose();
      });
      SmsV2Schema.ensure(db.db);
      const namespace = 'user:template';
      const sender = 'VM-HDFCCC-S (smsft_fi)';
      const original = 'Rs.125.40 paid from card XX1234 to RAHUL SHARMA.';
      const another = 'Rs.700.15 paid from card XX1234 to ALICE FERNANDES.';
      final now = DateTime.utc(2026, 11, 4);
      final full = RuleBundle.fromJson(
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>(),
      );
      final shared = RuleBundle.fromJson({
        ...full.toJson(),
        'rules': [
          for (final rule in full.rules)
            if (rule.status != RuleStatus.provisional) rule.toJson(),
        ],
      });
      final sharedJson = jsonEncode(shared.toJson());
      final intake = SmsIntakeRepository(db);
      final pipeline = SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: shared,
        appVersion: 'test',
      );
      for (final body in [original, another]) {
        intake.remember(
          namespace,
          QueuedSms(sender: sender, body: body, receivedAt: now),
        );
        pipeline.process(
          SmsMessage(
            sender: sender,
            body: body,
            observedAt: now,
            sourceKey: smsSourceKey(namespace, sender, body),
          ),
        );
      }
      final queue = OutboxStore(db.db, namespace: namespace);
      final state = SyncStateStore(db.db, namespace: namespace);
      var consent = true, current = true, offline = false;
      var submissions = 0;
      Map<String, Object?>? submitted;
      final uploader = TemplateUpload(
        intake: intake,
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {'Authorization': 'Bearer account-template'},
        hasConsent: () async {
          if (offline) throw const SocketException('offline');
          return consent;
        },
        accountIsCurrent: () => current,
        clock: () => now,
        client: MockClient((request) async {
          submissions++;
          final items = (jsonDecode(request.body) as Map)['items'] as List;
          expect(items, hasLength(1));
          final item = (items.single as Map).cast<String, Object?>();
          submitted = item;
          // Same digest bytes as the server acceptance check, over the body sent.
          final acceptedHash = sha256
              .convert(
                utf8.encode('${item['senderBrand']}\n${item['redactedBody']}'),
              )
              .toString();
          expect(item['templateHash'], acceptedHash);
          expect(item['senderBrand'], smsTemplateBrand(sender));
          expect(
            item.keys,
            unorderedEquals([
              'templateHash',
              'senderBrand',
              'redactedBody',
              'observedAt',
            ]),
          );
          for (final raw in [
            '125.40',
            '700.15',
            '1234',
            'RAHUL',
            'SHARMA',
            'ALICE',
            'FERNANDES',
          ]) {
            expect(
              request.body.toUpperCase(),
              isNot(contains(raw.toUpperCase())),
            );
          }
          expect(
            item['redactedBody'],
            smsSkeleton(item['redactedBody'] as String),
          );
          return http.Response(
            jsonEncode({
              'accepted': [acceptedHash],
            }),
            202,
          );
        }),
      );
      // An older queued original hash must not be retried with a redacted body.
      queue.enqueue('template', 'b' * 64, {
        'templateHash': 'b' * 64,
        'senderBrand': 'HDFCCC',
        'redactedBody': '<AMT> paid.',
        'observedAt': now.toIso8601String(),
      });
      await uploader.drain();
      final remoteHash = submitted!['templateHash'] as String;
      final localHash = smsTemplateHash(
        smsTemplateBrand(sender),
        smsSkeleton(original),
      );
      expect(remoteHash, isNot(localHash));
      final origin = TemplateOriginStore(state).get(remoteHash)!;
      expect(origin.localHashes, hasLength(2));
      expect(origin.localHashes, contains(localHash));
      expect(
        intake
            .capturedById(namespace, smsSourceKey(namespace, sender, original))!
            .message
            .body,
        original,
      );
      final rule = {
        ...full.rules.first.toJson(),
        'id': 'AI-$remoteHash',
        'version': 1,
        'status': 'provisional',
        'createdBy': 'ai:synthetic',
        'senders': [smsTemplateBrand(sender)],
        'match': {
          'pattern':
              r'^Rs\.(?<amt>\d+(?:\.\d{1,2})?) paid from card XX(?<mask>\d{4}) to (?<merchant>[A-Z ]+)\.$',
          'flags': 'i',
          'templateHash': remoteHash,
        },
        'emit': [
          {
            'factType': 'movement',
            'attrs': {
              'direction': 'debit',
              'purpose': 'purchase',
              'rail': 'card',
            },
            'amounts': [
              {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
            ],
            'instrument': {'kind': 'credit_card', 'maskFrom': 'mask'},
            'counterparty': {'nameFrom': 'merchant', 'kind': 'merchant'},
          },
        ],
      };
      await SyncPull(
        financial: financial,
        namespace: namespace,
        bundle: shared,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {'Authorization': 'Bearer account-template'},
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'cursor': 'private-result',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                {
                  'templateHash': remoteHash,
                  'status': 'ready',
                  'ruleId': rule['id'],
                  'ruleVersion': 1,
                  'rule': rule,
                },
              ],
              'corrections': [],
              'latestBundleVersion': shared.bundleVersion,
            }),
            200,
          ),
        ),
      ).pull();
      final overlay = ProvisionalStore(state).overlay(shared);
      expect(overlay.bundle.rules, hasLength(shared.rules.length + 2));
      final varied = original.replaceFirst('125.40', '999.25');
      final result = RuleEngine().interpret(
        SmsMessage(
          sender: sender,
          body: varied,
          observedAt: now,
          sourceKey: 'varying',
        ),
        overlay.bundle,
        appVersion: 'test',
      );
      expect(result.outcome, InterpretOutcome.matched);
      expect(result.facts.single.amounts.single.minor, 99925);
      expect(result.facts.single.instrument!.issuerSlug, 'hdfc');
      SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: overlay.bundle,
        appVersion: 'test',
        revision: overlay.revision,
      ).process(
        SmsMessage(
          sender: sender,
          body: varied,
          observedAt: now,
          sourceKey: 'varying',
        ),
      );
      // A private AI rule reports under its layout's AI id (never its
      // per-phone local id), counted as sent to review.
      final stats = db.db.select(
        'SELECT rule_id,rule_version,hits,to_review,corrected FROM v2_rule_stats_by_account WHERE namespace=?',
        [namespace],
      );
      expect(stats, hasLength(1));
      expect(stats.single['rule_id'], matches(RegExp(r'^AI-[0-9a-f]{64}$')));
      expect(
        [
          stats.single['hits'],
          stats.single['to_review'],
          stats.single['corrected'],
        ],
        [1, 1, 0],
      );
      expect(
        ProvisionalStore(
          SyncStateStore(db.db, namespace: 'user:other'),
        ).overlay(shared).bundle,
        shared,
      );
      expect(jsonEncode(shared.toJson()), sharedJson);
      state.put('personal:rule:keep', 'private user choice');
      state.put('category:keep', 'category choice');
      final otherState = SyncStateStore(db.db, namespace: 'user:other');
      otherState.put('ai:keep', 'other account');
      offline = true;
      await uploader.drain();
      expect(
        ProvisionalStore(state).overlay(shared).bundle.rules,
        hasLength(shared.rules.length + 2),
      );
      offline = false;
      consent = false;
      await uploader.drain();
      expect(TemplateOriginStore(state).get(remoteHash), isNull);
      expect(state.get('ai:$remoteHash'), isNull);
      expect(state.get('template:sent:$remoteHash'), isNull);
      expect(state.get('personal:rule:keep'), 'private user choice');
      expect(state.get('category:keep'), 'category choice');
      expect(otherState.get('ai:keep'), 'other account');
      expect(ProvisionalStore(state).overlay(shared).bundle, shared);
      consent = true;
      current = false;
      await uploader.drain();
      expect(submissions, 1);
      current = true;
      await uploader.drain();
      expect(submissions, 2);
      expect(TemplateOriginStore(state).get(remoteHash), isNotNull);
      expect(ProvisionalStore(state).overlay(shared).bundle, shared);
    },
  );
}
