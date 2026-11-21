// L1: the corrections, learning-signal and draft-rejection uploads each ask the outbox only for their own kind, so a
// big backlog of another kind (facts) cannot hide them. L2: one signal the server refuses (400) no longer holds up
// the other 49 in its request. Every name and number is invented; the clock is fixed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/corrections_sync.dart';
import 'package:pandapay/features/sms_v2/sync/draft_feedback.dart';
import 'package:pandapay/features/sms_v2/sync/learning_signals.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:a';
const _draft = '11111111-1111-4111-8111-111111111111';

void main() {
  late AppDatabase database;
  late OutboxStore queue;
  var now = DateTime.utc(2026, 11, 20, 10);

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    SmsV2Schema.ensure(database.db);
    queue = OutboxStore(database.db, namespace: _ns);
    now = DateTime.utc(2026, 11, 20, 10);
  });
  tearDown(() => database.db.dispose());

  void backlogOfFacts() {
    for (var i = 0; i < 2600; i++) {
      queue.enqueue('source', 'row$i', {'n': i});
    }
  }

  int queued(String kind) =>
      database.db.select('SELECT count(*) n FROM v2_outbox WHERE kind=?', [kind]).first['n'] as int;

  group('L1: a backlog of another kind does not hide the work', () {
    test('a correction behind 2,600 fact rows is sent', () async {
      backlogOfFacts();
      queue.enqueue('correction', 'local', {});
      var posts = 0;
      final sync = CorrectionsSync(
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          posts++;
          return http.Response(jsonEncode({'caseId': 'case-1'}), 200);
        }),
      );
      expect(await sync.drain(), 1);
      expect(posts, 1);
      expect(queued('correction'), 0);
    });

    test('a draft rejection behind 2,600 fact rows is sent', () async {
      backlogOfFacts();
      queue.enqueue('draft_rejection', _draft, {'draftId': _draft, 'reason': 'no_match'});
      var posts = 0;
      final upload = DraftRejectionUpload(
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => true,
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          posts++;
          return http.Response('{}', 200);
        }),
      );
      expect(await upload.drain(), 1);
      expect(posts, 1);
      expect(queued('draft_rejection'), 0);
    });

    test('a learning signal behind 2,600 fact rows is sent', () async {
      backlogOfFacts();
      enqueueLearningSignal(queue, const LearningSignal(kind: 'uncategorised', senderBrand: 'HDFCBK', merchantKey: 'BLINKIT'));
      var posts = 0;
      final upload = _signals(database, queue, () => now, (items) async {
        posts += items.length;
        return http.Response('{"accepted":1}', 202);
      });
      await upload.drain();
      expect(posts, 1);
      expect(queued('signal'), 0);
    });
  });

  group('L2: one refused signal does not hold up the others', () {
    LearningSignal signal(String key) => LearningSignal(kind: 'uncategorised', senderBrand: 'HDFCBK', merchantKey: key);

    test('the others go up, the refused one gets one more try and is then dropped', () async {
      for (final key in ['AAA STORE', 'POISON SHOP', 'CCC STORE']) {
        enqueueLearningSignal(queue, signal(key));
      }
      final accepted = <String>[];
      var refusedAlone = 0;
      final upload = _signals(database, queue, () => now, (items) async {
        if (items.any((i) => i['merchantKey'] == 'POISON SHOP')) {
          if (items.length == 1) refusedAlone++;
          return http.Response('{"error":"invalid_signal"}', 400);
        }
        accepted.addAll([for (final i in items) '${i['merchantKey']}']);
        return http.Response('{"accepted":${items.length}}', 202);
      });
      await upload.drain();
      expect(accepted..sort(), ['AAA STORE', 'CCC STORE'], reason: 'before: all three failed together, for ever');
      expect(queued('signal'), 1, reason: 'the refused one is kept for one more try');
      expect(refusedAlone, 1);

      now = now.add(const Duration(minutes: 5));
      await upload.drain();
      expect(refusedAlone, 2);
      expect(queued('signal'), 0, reason: 'refused alone a second time: dropped');
      expect(SyncStateStore(database.db, namespace: _ns).get('signal:refused:signal:uncategorised:POISON SHOP:'), isNull);

      now = now.add(const Duration(hours: 1));
      final before = refusedAlone;
      await upload.drain();
      expect(refusedAlone, before, reason: 'nothing left to send');
    });

    test('a server that refuses everything stops after a few refusals in a pass', () async {
      for (var i = 0; i < 20; i++) {
        enqueueLearningSignal(queue, signal('SHOP NUMBER ${String.fromCharCode(65 + i)}'));
      }
      var requests = 0;
      final upload = _signals(database, queue, () => now, (items) async {
        requests++;
        return http.Response('{"error":"nope"}', 400);
      });
      await upload.drain();
      expect(requests, lessThanOrEqualTo(8), reason: 'one request that finds the batch bad, then a few singles');
      expect(queued('signal'), 20, reason: 'nothing is lost on a pass that only met refusals');
    });
  });
}

LearningSignalUpload _signals(
  AppDatabase database,
  OutboxStore queue,
  DateTime Function() clock,
  Future<http.Response> Function(List<Map> items) answer,
) => LearningSignalUpload(
  intake: SmsIntakeRepository(database),
  queue: queue,
  baseUri: Uri.parse('https://api.invalid'),
  headers: () async => {},
  hasConsent: () async => true,
  accountIsCurrent: () => true,
  taxonomyVersion: () => 1,
  clock: clock,
  client: MockClient((request) async => answer(((jsonDecode(request.body) as Map)['items'] as List).cast<Map>())),
);
