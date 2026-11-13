import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/sync/corrections_sync.dart';
import 'package:pandapay/features/sms_v2/sync/facts_upload.dart';
import 'package:pandapay/features/sms_v2/sync/requeue_for_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Q-09: a correction made while the phone was offline must reach the server
/// once the connection is back; it is never parked because the phone was
/// offline. Synthetic message from the contract fixtures only.
void main() {
  const namespace = 'user:test';
  late AppDatabase database;
  late FinancialStore financial;
  late OutboxStore queue;
  late RuleBundle bundle;
  late String sourceKey;
  late String eventId;
  late DateTime now;
  // The server's memory: it only knows the facts after an upload reached it.
  var serverKnowsFacts = false;
  var online = true;
  var correctionPosts = 0;
  var alwaysNotFound = false;

  setUp(() async {
    now = DateTime.utc(2026, 11, 1, 7);
    serverKnowsFacts = false;
    online = true;
    correctionPosts = 0;
    alwaysNotFound = false;
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    final encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    bundle = RuleBundle.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );
    SmsImportStore(financial).capture(
      namespace,
      QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        receivedAt: now,
      ),
    );
    // Read the message offline with the real runtime (capture only).
    await SmsV2Runtime(
      financial: financial,
      namespace: namespace,
      client: MockClient((_) async => throw StateError('no network')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => now,
      isOffline: () => true,
    ).sync();
    queue = OutboxStore(database.db, namespace: namespace);
    final far = DateTime.utc(2100);
    sourceKey = queue
        .due(far)
        .firstWhere((r) => r.kind == 'source')
        .id
        .substring('source:'.length);
    eventId = queue
        .due(far)
        .firstWhere((r) => r.kind == 'event')
        .id
        .substring('event:'.length);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  http.Client server() => MockClient((request) async {
    if (!online) throw const SocketException('offline');
    switch (request.url.path) {
      case '/sms/v2/facts:batch':
        final body =
            jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
        if ((body['items'] as List).isNotEmpty) serverKnowsFacts = true;
        return http.Response(
          jsonEncode({
            'results': [
              for (final item in body['items'])
                for (final fact in item['facts'])
                  {'kind': 'fact', 'id': fact['factId'], 'status': 'accepted'},
              for (final (key, kind, id) in [
                ('instruments', 'instrument', 'instrumentId'),
                ('events', 'event', 'eventId'),
                ('ledger', 'ledger', 'entryId'),
              ])
                for (final row in body[key])
                  {'kind': kind, 'id': row[id], 'status': 'accepted'},
            ],
          }),
          200,
        );
      case '/sms/v2/corrections':
        correctionPosts++;
        if (!serverKnowsFacts || alwaysNotFound) {
          return http.Response(
            jsonEncode({'error': 'correction_facts_not_found'}),
            400,
          );
        }
        return http.Response(jsonEncode({'caseId': 'case-1'}), 200);
    }
    return http.Response('{}', 404);
  });

  FactsUpload uploader(http.Client client) => FactsUpload(
    queue: queue,
    client: client,
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'test-device',
    appVersion: '2',
    headers: () async => {},
    clock: () => now,
  );

  CorrectionsSync corrections(http.Client client) {
    final intake = SmsIntakeRepository(database);
    return CorrectionsSync(
      queue: queue,
      client: client,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      accountIsCurrent: () => true,
      requeue: (key, event) => requeueForUpload(
        queue: queue,
        intake: intake,
        sourceKey: key,
        eventId: event,
        brandOf: (sender) => uploadBrandOfSender(sender, bundle.senders),
      ),
      clock: () => now,
    );
  }

  void addCorrection() {
    queue.enqueue('correction', 'c1', {
      'sourceKey': sourceKey,
      'eventId': eventId,
      'factIds': <String>[],
    });
    database.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
      namespace,
      'correction:c1',
      'correction',
      '{}',
      'pending',
    ]);
  }

  Map<String, Object?> review() {
    final row = database.db
        .select(
          "SELECT status,payload FROM v2_review_items WHERE review_id='correction:c1'",
        )
        .single;
    return {
      'status': row['status'],
      ...(jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
    };
  }

  OutboxRecord? waiting(String id) =>
      queue.due(DateTime.utc(2100)).where((r) => r.id == id).firstOrNull;

  // What the old offline spell did to the queued uploads: every 15-minute
  // tick counted a failed attempt for the source, the event and the ledger
  // entries sent together, leaving all of them in a back-off. (Another failure
  // that is not the network, such as a server outage, still does the same.)
  void sourceHasFailedSixTimes() {
    for (final record in queue.due(DateTime.utc(2100))) {
      if (record.kind == 'correction') continue;
      for (var i = 0; i < 6; i++) {
        queue.retry(waiting(record.id)!, now);
      }
    }
    expect(queue.due(now), isEmpty);
  }

  test(
    'requeueForUpload leaves the payload as it was and starts the record over',
    () {
      final id = 'source:$sourceKey';
      final before = waiting(id)!;
      sourceHasFailedSixTimes();
      requeueForUpload(
        queue: queue,
        intake: SmsIntakeRepository(database),
        sourceKey: sourceKey,
        eventId: eventId,
        brandOf: (sender) => uploadBrandOfSender(sender, bundle.senders),
      );
      final after = waiting(id)!;
      expect(
        after.payload,
        before.payload,
        reason: 'the resend is byte-identical to what was queued',
      );
      expect(after.attempts, 0, reason: 'but it starts over');
      expect(
        queue.due(now).map((r) => r.id),
        containsAll([id, 'event:$eventId']),
        reason: 'and is due now, not after the old back-off',
      );
    },
  );

  test('a correction made offline is not parked when its source is in '
      'back-off after many failed attempts; it goes through after the '
      'upload', () async {
    sourceHasFailedSixTimes();
    addCorrection();
    final client = server();
    // First pass, in the order a sync takes: upload, then corrections.
    await uploader(client).drain();
    await corrections(client).drain();
    expect(review()['status'], 'pending');
    expect(review()['notSent'], isNull);
    expect(waiting('correction:c1'), isNotNull, reason: 'still queued');
    // Later the back-off ends; the source uploads, then the correction.
    now = now.add(const Duration(hours: 1));
    await uploader(client).drain();
    expect(serverKnowsFacts, isTrue);
    await corrections(client).drain();
    now = now.add(const Duration(hours: 1));
    await corrections(client).drain();
    expect(review()['caseId'], 'case-1');
    expect(waiting('correction:c1'), isNull);
  });

  test('a long offline spell does not park a correction', () async {
    addCorrection();
    final client = server();
    online = false;
    for (var tick = 0; tick < 24; tick++) {
      await uploader(client).drain();
      await corrections(client).drain();
      now = now.add(const Duration(minutes: 15));
    }
    expect(review()['status'], 'pending');
    online = true;
    // The connection returns: one reset, then the normal order.
    queue.resetBackoff();
    await uploader(client).drain();
    await corrections(client).drain();
    now = now.add(const Duration(minutes: 20));
    await corrections(client).drain();
    expect(review()['caseId'], 'case-1');
  });

  test(
    'a source waiting after a network failure (no attempt counted) holds the correction back',
    () async {
      for (final record in queue.due(DateTime.utc(2100))) {
        queue.deferUntil(record.id, now.add(const Duration(hours: 1)));
      }
      addCorrection();
      await corrections(server()).drain();
      expect(correctionPosts, 0);
    },
  );

  test('a correction the server keeps answering with "facts not found" is '
      'tried a few times with growing waits before it stays on the '
      'phone', () async {
    alwaysNotFound = true;
    addCorrection();
    final client = server();
    var passes = 0;
    while (review()['status'] != 'resolved' && passes < 40) {
      await uploader(client).drain();
      await corrections(client).drain();
      now = now.add(const Duration(hours: 1));
      passes++;
    }
    expect(review()['status'], 'resolved');
    expect(review()['notSent'], 'correction_facts_not_found');
    expect(
      correctionPosts,
      CorrectionsSync.maxFactsNotFoundRefusals,
      reason: 'a bounded number of tries, not just two',
    );
    expect(waiting('correction:c1'), isNull);
  });
}
