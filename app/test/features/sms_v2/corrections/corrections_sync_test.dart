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

  group('a correction the server refuses', () {
    late Database db;
    late OutboxStore queue;
    var now = DateTime.utc(2026, 11, 1);

    void addCorrection(String id, Map<String, Object?> payload) {
      queue.enqueue('correction', id, payload);
      db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'user:a',
        'correction:$id',
        'correction',
        '{}',
        'pending',
      ]);
    }

    Map<String, Object?> review(String id) => {
      'status': db
          .select(
            "SELECT status,payload FROM v2_review_items WHERE review_id='correction:$id'",
          )
          .single['status'],
      ...(jsonDecode(
            db
                    .select(
                      "SELECT payload FROM v2_review_items WHERE review_id='correction:$id'",
                    )
                    .single['payload']
                as String,
          )
          as Map)
          .cast<String, Object?>(),
    };

    CorrectionsSync syncWith(
      http.Response Function(http.Request request) answer, {
      void Function(String sourceKey, String? eventId)? requeue,
    }) => CorrectionsSync(
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      accountIsCurrent: () => true,
      requeue: requeue,
      clock: () => now,
      client: MockClient((request) async => answer(request)),
    );

    setUp(() {
      db = sqlite3.openInMemory();
      SmsV2Schema.ensure(db);
      queue = OutboxStore(db, namespace: 'user:a');
      now = DateTime.utc(2026, 11, 1);
    });
    tearDown(() => db.dispose());

    http.Response refused(String code, [int status = 400]) =>
        http.Response(jsonEncode({'error': code}), status);

    test('is not sent while its source is still waiting to upload', () async {
      queue.enqueue('source', 'S1', {'sourceKey': 'S1'});
      addCorrection('c1', {'sourceKey': 'S1', 'factIds': ['f']});
      var posts = 0;
      final sync = syncWith((_) {
        posts++;
        return http.Response(jsonEncode({'caseId': 'case-1'}), 200);
      });
      expect(await sync.drain(), 0);
      expect(posts, 0, reason: 'the server cannot match facts it has not got');
      queue.acknowledge(queue.due(now).firstWhere((r) => r.kind == 'source'));
      expect(await sync.drain(), 1);
      expect(posts, 1);
    });

    test('stops waiting for a source the server keeps refusing', () async {
      queue.enqueue('source', 'S1', {'sourceKey': 'S1'});
      for (var i = 0; i < 6; i++) {
        queue.retry(queue.due(DateTime.utc(2100)).single, now);
      }
      addCorrection('c1', {'sourceKey': 'S1', 'factIds': <String>[]});
      var posts = 0;
      final sync = syncWith((_) {
        posts++;
        return http.Response(jsonEncode({'caseId': 'case-1'}), 200);
      });
      expect(await sync.drain(), 1);
      expect(posts, 1);
    });

    // The real resend puts the source back in the upload queue; the fake does the same.
    void Function(String, String?) resendInto(List<String> log) =>
        (source, event) {
          log.add('$source/$event');
          queue.enqueue('source', source, {'sourceKey': source, 'again': true});
        };

    void uploaded() {
      for (final record in queue.due(now).where((r) => r.kind == 'source')) {
        queue.acknowledge(record);
      }
    }

    test(
      'facts the server cannot find are sent again, then the correction is tried once more and kept off the queue if refused again',
      () async {
        addCorrection('c1', {
          'sourceKey': 'S1',
          'eventId': 'E1',
          'factIds': ['f'],
        });
        final resent = <String>[];
        var posts = 0;
        final seen = <Map>[];
        final sync = syncWith(
          (request) {
            posts++;
            seen.add(jsonDecode(request.body) as Map);
            return refused('correction_facts_not_found');
          },
          requeue: resendInto(resent),
        );
        expect(await sync.drain(), 0);
        expect(resent, ['S1/E1']);
        expect(posts, 1);
        expect(
          queue.due(now).firstWhere((r) => r.kind == 'correction').json['_resent'],
          true,
        );
        // It waits for the resent facts, so nothing more is asked of the server yet.
        expect(await sync.drain(), 0);
        expect(posts, 1);
        uploaded();
        expect(await sync.drain(), 0);
        expect(posts, 2);
        expect(resent, ['S1/E1'], reason: 'only one resend per correction');
        expect(seen.last.containsKey('_resent'), false, reason: 'markers stay on the phone');
        expect(queue.due(now), isEmpty, reason: 'it left the queue');
        final row = review('c1');
        expect(row['status'], 'resolved');
        expect(row['notSent'], 'correction_facts_not_found');
      },
    );

    test('a resend that works lets the correction through', () async {
      addCorrection('c1', {'sourceKey': 'S1', 'factIds': ['f']});
      final resent = <String>[];
      var known = false;
      final sync = syncWith(
        (_) => known
            ? http.Response(jsonEncode({'caseId': 'case-1'}), 200)
            : refused('correction_facts_not_found'),
        requeue: (source, event) {
          known = true;
          resendInto(resent)(source, event);
        },
      );
      expect(await sync.drain(), 0);
      uploaded();
      expect(await sync.drain(), 1);
      expect(queue.due(now), isEmpty);
      expect(review('c1')['caseId'], 'case-1');
    });

    test('a refused template is dropped and the correction is sent without it', () async {
      addCorrection('c1', {
        'sourceKey': 'S1',
        'factIds': <String>[],
        'redactedTemplate': 'Sent to <VPA>',
        'corrected': {
          'category': 'groceries',
          '_template': {'senderBrand': 'BANK', 'hash': 'h', 'observedAt': 'x'},
        },
      });
      final bodies = <Map>[];
      final sync = syncWith((request) {
        final body = jsonDecode(request.body) as Map;
        bodies.add(body);
        return body.containsKey('redactedTemplate')
            ? refused('redacted_template_invalid')
            : http.Response(jsonEncode({'caseId': 'case-1'}), 200);
      });
      expect(await sync.drain(), 1);
      expect(bodies, hasLength(2));
      expect(bodies.last.containsKey('redactedTemplate'), false);
      expect((bodies.last['corrected'] as Map).keys, ['category']);
      expect(bodies.last.containsKey('_templateDropped'), false);
    });

    test('a refusal retrying cannot change takes it off the queue and does not block the next one', () async {
      addCorrection('bad', {'sourceKey': 'S1', 'correctionKind': 'nonsense'});
      addCorrection('good', {'sourceKey': 'S2', 'factIds': <String>[]});
      final sync = syncWith((request) {
        final body = jsonDecode(request.body) as Map;
        return body['sourceKey'] == 'S1'
            ? refused('correction_stage_mismatch')
            : http.Response(jsonEncode({'caseId': 'case-2'}), 200);
      });
      expect(await sync.drain(), 1);
      expect(queue.due(now), isEmpty);
      expect(review('bad')['notSent'], 'correction_stage_mismatch');
      expect(review('good')['caseId'], 'case-2');
    });

    test('a busy server, a stale sign-in or an unreadable answer is retried later, not given up on', () async {
      for (final answer in [
        http.Response('{"error":"rate_limited"}', 429),
        http.Response('{"error":"attestation_required"}', 403),
        http.Response('{"error":"corrections_unavailable"}', 503),
        http.Response('<html>Bad request</html>', 400),
      ]) {
        addCorrection('c', {'sourceKey': 'S'});
        final sync = syncWith((_) => answer);
        expect(await sync.drain(), 0, reason: '${answer.statusCode}');
        expect(queue.due(now), isEmpty, reason: 'waiting for the next try');
        expect(queue.due(DateTime.utc(2100)), hasLength(1));
        expect(review('c')['status'], 'pending');
        db.execute('DELETE FROM v2_outbox');
        db.execute('DELETE FROM v2_review_items');
      }
    });
  });
}
