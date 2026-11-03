import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
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
    },
  );
}
