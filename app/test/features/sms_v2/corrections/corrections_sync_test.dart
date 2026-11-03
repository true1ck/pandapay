import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/sync/corrections_sync.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'offline correction retries, acknowledges once, and applies owner status',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final queue = OutboxStore(db, namespace: 'user:a');
      queue.enqueue('correction', 'local', {'correctionKind': 'missing'});
      db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'user:a',
        'correction:local',
        'correction',
        '{}',
        'pending',
      ]);
      var now = DateTime.utc(2026, 11, 1);
      var online = false;
      final sync = CorrectionsSync(
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          if (!online) throw StateError('offline');
          expect(request.url.path, '/sms/v2/corrections');
          return http.Response(jsonEncode({'caseId': 'server-case'}), 200);
        }),
      );
      expect(await sync.drain(), 0);
      expect(queue.due(now), isEmpty);
      now = now.add(const Duration(minutes: 1));
      online = true;
      expect(await sync.drain(), 1);
      expect(queue.due(now), isEmpty);
      sync.applyStatuses([
        {'caseId': 'server-case', 'status': 'decided', 'decision': 'data_fix'},
      ]);
      expect(
        db
            .select(
              "SELECT status FROM v2_review_items WHERE namespace='user:a'",
            )
            .single['status'],
        'decided',
      );
      expect(OutboxStore(db, namespace: 'user:b').due(now), isEmpty);
    },
  );

  test(
    'account change during header acquisition prevents sending private data',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final queue = OutboxStore(db, namespace: 'user:a');
      queue.enqueue('correction', 'local', {});
      var current = true;
      var requests = 0;
      final sync = CorrectionsSync(
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async {
          current = false;
          return {};
        },
        accountIsCurrent: () => current,
        client: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      expect(await sync.drain(), 0);
      expect(requests, 0);
      expect(queue.due(DateTime.now()), hasLength(1));
    },
  );
}
