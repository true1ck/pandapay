// V2a: the A4a/A4b phone fixes against dev's later consent work (f1a8494e: a failed consent lookup keeps the saved
// AI answers, lost answers are fetched again). Through the real runtime with a fake server that, like the real one,
// sends each answer once per position of the sync cursor. Synthetic messages and ids only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/ai_withdrawal.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:merge';
const _draft1 = '11111111-1111-4111-8111-111111111111';
const _draft2 = '22222222-2222-4222-8222-222222222222';

enum _Consent { granted, lookupFailed, withdrawn }

QueuedSms _msg(String shop, int rupees, int minute) => QueuedSms(
  sender: 'AX-HDFCBK-S',
  body:
      'Sent Rs.$rupees.00 from HDFC Bank A/c XX1234 to $shop on 20-11-26. Ref 61234567890$minute.',
  receivedAt: DateTime.utc(2026, 11, 20, 7, minute),
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late SmsV2Runtime runtime;
  late SyncStateStore state;
  var consent = _Consent.granted;
  var clockNow = DateTime.utc(2026, 11, 20, 12);
  var purpose = 'purchase';
  var draftId = _draft1;
  var answerStatus = 'ready';
  final uploaded = <String>[];
  var answersSent = 0;
  final fixture = (jsonDecode(
    File('test/features/sms_v2/fixtures/real_gemini_rule.json').readAsStringSync(),
  ) as Map).cast<String, Object?>();
  final fullBundle = (jsonDecode(
    File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync(),
  ) as Map).cast<String, Object?>();
  final baseline = <String, Object?>{...fullBundle, 'rules': <Object?>[], 'categoryRules': <Object?>[]};

  Map<String, Object?> ruleFor(String hash) {
    final rule = (jsonDecode(jsonEncode(fixture['rule'])) as Map).cast<String, Object?>();
    final emit = (rule['emit'] as List).cast<Map>().single;
    return {
      ...rule,
      'id': 'AI-$hash',
      'senders': ['HDFCBK'],
      'status': 'provisional',
      'match': {...(rule['match'] as Map), 'templateHash': hash},
      'emit': [
        {
          ...emit,
          'attrs': {...(emit['attrs'] as Map), 'purpose': purpose},
        },
      ],
    };
  }

  // The real server sends an answer once per position of the cursor: the cursor holds an `a` part once it has.
  String cursorOf(Map<String, Object?> parts) =>
      base64Url.encode(utf8.encode(jsonEncode(parts))).replaceAll('=', '');
  bool cursorHasAnswers(String? raw) {
    if (raw == null) return false;
    try {
      final parts = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw)))) as Map;
      return parts.containsKey('a');
    } catch (_) {
      return false;
    }
  }

  http.Response server(http.Request request) {
    switch (request.url.path) {
      case '/sms/v2/rules':
        return http.Response('', 304);
      case '/sms/v2/unknown-templates':
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        for (final item in items) {
          uploaded.add((item as Map)['templateHash'] as String);
        }
        return http.Response(
          jsonEncode({'accepted': [for (final item in items) (item as Map)['templateHash']]}),
          202,
        );
      case '/sms/v2/facts:batch':
        final body = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
        return http.Response(
          jsonEncode({
            'results': [
              for (final item in body['items'])
                for (final fact in item['facts']) {'kind': 'fact', 'id': fact['factId'], 'status': 'accepted'},
              for (final (key, kind, id) in [
                ('instruments', 'instrument', 'instrumentId'),
                ('events', 'event', 'eventId'),
                ('ledger', 'ledger', 'entryId'),
              ])
                for (final row in body[key]) {'kind': kind, 'id': row[id], 'status': 'accepted'},
            ],
          }),
          200,
        );
      case '/sms/v2/rule-stats:batch':
        return http.Response('{}', 202);
      case '/sms/v2/learning-signals':
        return http.Response('{"accepted":1}', 202);
      case '/sms/v2/sync':
        final send = !cursorHasAnswers(request.url.queryParameters['cursor']);
        if (send) answersSent++;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'cursor': cursorOf({'a': '$answersSent'}),
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                if (send)
                  for (final hash in uploaded.toSet())
                    {
                      'templateHash': hash,
                      'status': answerStatus,
                      if (answerStatus == 'ready') ...{
                        'ruleId': 'AI-$hash',
                        'ruleVersion': 1,
                        'rule': ruleFor(hash),
                        'draftId': draftId,
                      },
                    },
              ],
              'corrections': [],
              'latestBundleVersion': 1,
            }),
          ),
          200,
        );
      default:
        fail('Unexpected endpoint ${request.url.path}');
    }
  }

  Future<void> sync() => runtime.sync();

  int spendMinor() {
    var total = 0;
    for (final row in database.db.select('SELECT payload FROM v2_ledger WHERE namespace=?', [_namespace])) {
      total += ((jsonDecode(row['payload'] as String) as Map)['amountMinor'] as num).toInt();
    }
    return total;
  }

  List<String?> purposes() => [
    for (final row in database.db.select(
      "SELECT payload FROM v2_facts WHERE namespace=? AND fact_type='movement'",
      [_namespace],
    ))
      ((jsonDecode(row['payload'] as String) as Map)['attrs'] as Map)['purpose'] as String?,
  ];

  int rows(String like) => database.db.select(
    'SELECT count(*) AS n FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
    [_namespace, like],
  ).single['n'] as int;

  setUp(() {
    consent = _Consent.granted;
    clockNow = DateTime.utc(2026, 11, 20, 12);
    purpose = 'purchase';
    draftId = _draft1;
    answerStatus = 'ready';
    uploaded.clear();
    answersSent = 0;
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'merge-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async => RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => jsonEncode(baseline),
      accountIsCurrent: () => true,
      hasSharingConsent: () async => consent == _Consent.granted,
      consentWithdrawn: () async => consent == _Consent.withdrawn,
      clock: () => clockNow,
    );
    state = SyncStateStore(database.db, namespace: _namespace);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test(
    'MERGE-1 a failed consent lookup keeps the AI answers, the overlay cache still serves them, '
    'and neither the A4a markers nor the reading change',
    () async {
      final shared = RuleBundle.fromJson(baseline);
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync(); // uploads the layout and its link
      await sync(); // the draft arrives and reads it
      expect(purposes(), ['purchase']);
      expect(spendMinor(), 45000);
      final hash = uploaded.first;
      final answer = state.get('ai:$hash');
      expect(answer, isNotNull);
      final overlay = ProvisionalStore(state).overlay(shared);
      expect(overlay.bundle.rules.where((r) => r.id.startsWith('AI-')), isNotEmpty);
      final marker = state.get('${AiWithdrawal.ruleMarker}$hash');
      expect(marker, isNotNull, reason: 'the draft offered is recorded by A4a');

      consent = _Consent.lookupFailed; // offline / expired login: not a withdrawal
      for (var i = 0; i < 3; i++) {
        await sync();
      }
      expect(state.get('ai:$hash'), answer, reason: 'dev: a failed lookup erases nothing');
      expect(state.get('wipe:ai:at'), isNull);
      expect(state.get('template:origins:$hash'), isNotNull);
      expect(state.get('${AiWithdrawal.ruleMarker}$hash'), marker);
      expect(
        identical(ProvisionalStore(state).overlay(shared).bundle, overlay.bundle),
        isTrue,
        reason: 'A4b cache: the very same overlay, no recompile',
      );
      expect(purposes(), ['purchase']);
      expect(spendMinor(), 45000, reason: 'A4a: nothing is withdrawn on an unknown consent');

      consent = _Consent.granted;
      await sync();
      expect(purposes(), ['purchase']);
      expect(spendMinor(), 45000);
    },
  );

  test(
    'MERGE-2 a clear withdrawal erases the answers (cache falls back to the shared bundle); the lost answers are '
    'fetched again, the cache is rebuilt, and a revision that arrived meanwhile is still applied once (A4a)',
    () async {
      final shared = RuleBundle.fromJson(baseline);
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      // A second message in a layout the draft does not cover stays unread: a format still waiting for an answer.
      // That open question, not a confidently read message, is what makes the phone ask for lost answers again.
      await runtime.capture([
        QueuedSms(
          sender: 'AX-HDFCBK-S',
          body: 'Paid Rs.99.00 from HDFC Bank A/c XX1234 to SOME SHOP on 20-11-26. Ref 6123456789099.',
          receivedAt: DateTime.utc(2026, 11, 20, 7, 9),
        ),
      ]);
      await sync();
      await sync();
      expect(purposes(), ['purchase']);
      final hash = uploaded.first;
      final first = ProvisionalStore(state).overlay(shared);
      final offered = state.get('${AiWithdrawal.ruleMarker}$hash');

      consent = _Consent.withdrawn;
      await sync();
      expect(rows('ai:%'), 0, reason: 'dev: a clear withdrawal erases the saved answers');
      expect(state.get('wipe:ai:at'), isNotNull);
      expect(state.get('template:origins:$hash'), isNull);
      expect(ProvisionalStore(state).overlay(shared).bundle, same(shared));
      expect(spendMinor(), 45000, reason: 'readings are not touched by the erase (unchanged behaviour)');
      expect(state.get('${AiWithdrawal.ruleMarker}$hash'), offered, reason: 'the A4a marker is not an AI answer');

      // Sharing is agreed again; the server has moved on to a second revision in the meantime.
      consent = _Consent.granted;
      // The first sync of a phone with an open format and no answer already used one restore; it waits six hours.
      clockNow = clockNow.add(const Duration(hours: 7));
      purpose = 'p2p';
      draftId = _draft2;
      for (var i = 0; i < 4; i++) {
        await sync();
      }
      expect(rows('ai:%'), 2, reason: 'the answers (one per uploaded layout) were fetched again');
      expect(state.get('restore:ai:count'), '2');
      final again = ProvisionalStore(state).overlay(shared);
      expect(identical(again.bundle, first.bundle), isFalse, reason: 'the cache was invalidated');
      expect(again.revision, isNot(first.revision));
      expect(purposes(), ['p2p'], reason: 'A4a: the new revision reads what the old one read');
      expect(spendMinor(), 45000, reason: 'counted once');
      expect(
        database.db.select('SELECT count(*) AS n FROM v2_ledger WHERE namespace=?', [_namespace]).single['n'],
        1,
      );
    },
  );

  test(
    'MERGE-3 a draft taken back (pending) while the lookup failed withdraws only once the answer really arrives',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      await sync();
      expect(spendMinor(), 45000);
      consent = _Consent.lookupFailed;
      await sync();
      expect(spendMinor(), 45000);
      consent = _Consent.granted;
      answerStatus = 'pending';
      // The server sends it again once the position is not at the answers any more.
      state.put('pull:cursor', cursorOf({'i': 'x'}));
      await sync();
      expect(spendMinor(), 0, reason: 'A4a: a pending answer takes back what the draft read');
      expect(purposes(), isEmpty);
    },
  );
}
