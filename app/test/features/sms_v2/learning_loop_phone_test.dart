// The phone's side of the learning loop (learning-loop Task B8, step 4): a new
// shared rule set re-categorises what the rules chose, never what the person
// chose, and shop signals leave the phone only while sharing is on.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/rules.dart';

const _namespace = 'user:loop';

QueuedSms _purchase(String shop, int rupees, int minute) => QueuedSms(
  sender: 'VM-HDFCBK-S',
  body:
      'Sent Rs.$rupees.00 From HDFC Bank A/C **1797 to $shop UPI on 10-11-26. Avl Bal Rs.12,345.67',
  receivedAt: DateTime.utc(2026, 11, 10, 7, minute),
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late SmsV2Runtime runtime;
  var consent = false;
  var clockNow = DateTime.utc(2026, 11, 10, 12);
  String? servedBundle; // what GET /sms/v2/rules answers, null for "no change"
  var signalStatus = 202;
  var aiResults = <Map<String, Object?>>[];
  final signalPosts = <Map<String, Object?>>[];

  // The shipped rule set, with no shop categories yet: every purchase is Other.
  final baseline = <String, Object?>{
    ...testRuleBundle().toJson(),
    'categoryRules': <Object?>[],
  };
  final baselineJson = jsonEncode(baseline);
  final signature =
      ((jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)['signature']
              as Map)
          .cast<String, Object?>();

  /// The next rule set: SWIGGY is Dining for everyone.
  String nextRuleSet() => jsonEncode({
    ...baseline,
    'bundleVersion': 2,
    'createdAt': clockNow.toIso8601String(),
    'expiresAt': clockNow.add(const Duration(days: 7)).toIso8601String(),
    'signature': signature,
    'categoryRules': [
      {
        'merchantKey': 'SWIGGY',
        'match': 'token',
        'senders': ['*'],
        'context': <Object?>[],
        'category': 'dining',
        'priority': 100,
        'source': 'shared',
      },
    ],
  });

  LedgerStore ledger() => LedgerStore(database.db, namespace: _namespace);

  http.Response server(http.Request request) {
    switch (request.url.path) {
      case '/sms/v2/rules':
        return servedBundle == null
            ? http.Response('', 304)
            : http.Response.bytes(utf8.encode(servedBundle!), 200);
      case '/sms/v2/facts:batch':
        final body =
            jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
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
      case '/sms/v2/rule-stats:batch':
        return http.Response('{}', 202);
      case '/sms/v2/learning-signals':
        signalPosts.add(
          (jsonDecode(request.body) as Map).cast<String, Object?>(),
        );
        return http.Response(
          signalStatus == 202
              ? '{"accepted":1}'
              : '{"error":"learning_paused"}',
          signalStatus,
        );
      case '/sms/v2/sync':
        return http.Response(
          jsonEncode({
            'cursor': 'one',
            'instruments': [],
            'events': [],
            'ledger': [],
            'facts': [],
            'aiResults': aiResults,
            'corrections': [],
            'latestBundleVersion': 1,
          }),
          200,
        );
      default:
        fail('Unexpected endpoint ${request.url.path}');
    }
  }

  Future<void> sync() async {
    await runtime.sync();
  }

  setUp(() {
    consent = false;
    clockNow = DateTime.utc(2026, 11, 10, 12);
    servedBundle = null;
    signalStatus = 202;
    aiResults = [];
    signalPosts.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'loop-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async =>
          RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => baselineJson,
      accountIsCurrent: () => true,
      hasSharingConsent: () async => consent,
      clock: () => clockNow,
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  Future<Map<String, String>> eventsByAmount() async {
    final out = <String, String>{};
    for (final row in database.db.select(
      'SELECT event_id,payload FROM v2_ledger WHERE namespace=?',
      [_namespace],
    )) {
      out['${(jsonDecode(row['payload'] as String) as Map)['amountMinor']}'] =
          row['event_id'] as String;
    }
    return out;
  }

  test(
    'a new rule set re-categorises what the rules chose and keeps the user\'s own choice',
    () async {
      await runtime.capture([
        _purchase('SWIGGY', 499, 1),
        _purchase('SWIGGY', 500, 2),
        _purchase('SWIGGY', 501, 3),
      ]);
      await sync();
      var events = await eventsByAmount();
      expect(events, hasLength(3));
      final decisions = ledger().categoryDecisions();
      expect(decisions.values.map((d) => d.slug), everyElement('other'));
      expect(
        decisions.values.map((d) => d.source),
        everyElement(CategorySource.fallback),
      );
      // The person puts one of the three in Groceries.
      final mine = events['50100']!;
      // (The row carries the category on the wire as well as the local decision,
      // exactly as the corrections service writes it.)
      ledger().replaceForEvent(
        mine,
        [
          for (final entry in ledger().forEvent(mine))
            entry.withCategory('groceries', CategorySource.user),
        ],
        category: const CategoryDecision(
          slug: 'groceries',
          source: CategorySource.user,
          confidence: 1,
        ),
      );

      // The next rule set arrives with the next rule check.
      servedBundle = nextRuleSet();
      clockNow = clockNow.add(const Duration(hours: 7));
      await sync();
      final after = ledger().categoryDecisions();
      for (final amount in ['49900', '50000']) {
        expect(
          after[events[amount]]!.slug,
          'dining',
          reason: 'Rs.$amount follows the new rule',
        );
        expect(after[events[amount]]!.source, CategorySource.shared);
      }
      expect(
        after[mine]!.slug,
        'groceries',
        reason: 'the person\'s choice wins',
      );
      expect(after[mine]!.source, CategorySource.user);
      // The pass ran for this rule-set revision and is not repeated.
      expect(
        SyncStateStore(
          database.db,
          namespace: _namespace,
        ).get('pipeline:category-revision'),
        isNotNull,
      );
    },
  );

  test(
    'shop signals are queued and sent only while sharing is on, and withdrawing empties the outbox',
    () async {
      servedBundle = nextRuleSet();
      await runtime.capture([
        _purchase('SWIGGY', 499, 1),
        _purchase('BLINKIT', 250, 2),
      ]);
      await sync();
      int signalRows() => database.db.select(
        "SELECT 1 FROM v2_outbox WHERE namespace=? AND kind='signal'",
        [_namespace],
      ).length;

      // Sharing off: BLINKIT sits in Other, and nothing is queued or sent.
      expect(signalPosts, isEmpty);
      expect(signalRows(), 0);
      expect(
        SyncStateStore(
          database.db,
          namespace: _namespace,
        ).get('signal:uncat:BLINKIT'),
        isNull,
      );

      // Sharing on (the server pauses intake for now): the shop is sent, kept for later.
      consent = true;
      signalStatus = 503;
      await sync();
      expect(signalPosts, hasLength(1));
      final item = (signalPosts.single['items'] as List).single as Map;
      expect(item, {
        'kind': 'uncategorised',
        'senderBrand': 'HDFCBK',
        'merchantKey': 'BLINKIT UPI',
        'value': '',
        'eventType': 'purchase',
        'taxonomyVersion': 1,
      });
      expect(
        signalRows(),
        1,
        reason:
            'a paused server is a temporary failure; the signal stays queued',
      );
      // SWIGGY has a rule now, so it is not reported as left in Other.
      expect(
        signalPosts
            .expand((post) => post['items'] as List)
            .where((i) => (i as Map)['merchantKey'] == 'SWIGGY'),
        isEmpty,
      );

      // Withdrawing sharing empties the outbox and forgets what was reported.
      consent = false;
      await sync();
      expect(signalRows(), 0);
      expect(
        SyncStateStore(
          database.db,
          namespace: _namespace,
        ).get('signal:uncat:BLINKIT'),
        isNull,
      );
      final sent = signalPosts.length;
      await sync();
      expect(
        signalPosts.length,
        sent,
        reason: 'nothing leaves the phone without sharing',
      );
    },
  );
  test(
    'a rejected AI layout makes the phone drop its private rule at the next sync',
    () async {
      await runtime.capture([_purchase('SWIGGY', 499, 1)]);
      await sync();
      final fixture =
          (jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, Object?>();
      final rule = RuleBundle.fromJson(
        fixture,
      ).rules.firstWhere((r) => r.status == RuleStatus.provisional);
      final hash = rule.match.templateHash!;
      final state = SyncStateStore(database.db, namespace: _namespace);
      TemplateOriginStore(state).remember(
        remoteHash: hash,
        localHash: 'a' * 64,
        senderBrand: rule.senders.single,
      );
      state.put(
        'ai:$hash',
        jsonEncode({
          'templateHash': hash,
          'status': 'ready',
          'rule': rule.toJson(),
        }),
      );
      final shared = RuleBundle.fromJson(baseline);
      final withRule = ProvisionalStore(state).overlay(shared).bundle;
      expect(
        withRule.rules.length,
        shared.rules.length + 1,
        reason: 'the private rule is on this phone',
      );

      // The owner rejects the layout; the next sync carries the verdict.
      aiResults = [
        {'templateHash': hash, 'status': 'rejected'},
      ];
      await sync();
      expect(
        ProvisionalStore(state).overlay(shared).bundle.rules.length,
        shared.rules.length,
      );
    },
  );
}
