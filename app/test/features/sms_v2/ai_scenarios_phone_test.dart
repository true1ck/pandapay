// AI-per-template scenarios on the phone, through the real runtime with a fake
// server: upload, checking, apply, spend counted, rejection, publication,
// consent revoked, and the old invalid statuses. The rule is a real Gemini
// draft (fixtures/real_gemini_rule.json) re-bound to the hash this phone sends.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:ai';

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
  var consent = true;
  var clockNow = DateTime.utc(2026, 11, 20, 12);
  var aiStatus = 'none'; // none | pending | ready | rejected | failed
  String? servedBundle;
  final uploaded = <String>[]; // remote template hashes the phone sent
  final fixture =
      (jsonDecode(
                File(
                  'test/features/sms_v2/fixtures/real_gemini_rule.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  // A rule set that reads nothing: every message of this layout is unknown.
  final baseline = <String, Object?>{
    ...(jsonDecode(
              File(
                '../contracts/sms/v2/fixtures/valid/bundle/full.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>(),
    'rules': <Object?>[],
    'categoryRules': <Object?>[],
  };
  final signature =
      ((jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)['signature']
              as Map)
          .cast<String, Object?>();

  Map<String, Object?> ruleFor(String hash, {String status = 'provisional'}) {
    final rule = (jsonDecode(jsonEncode(fixture['rule'])) as Map)
        .cast<String, Object?>();
    return {
      ...rule,
      'id': 'AI-$hash',
      'status': status,
      'match': {...(rule['match'] as Map), 'templateHash': hash},
    };
  }

  http.Response server(http.Request request) {
    switch (request.url.path) {
      case '/sms/v2/rules':
        return servedBundle == null
            ? http.Response('', 304)
            : http.Response.bytes(utf8.encode(servedBundle!), 200);
      case '/sms/v2/unknown-templates':
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        for (final item in items) {
          uploaded.add((item as Map)['templateHash'] as String);
        }
        return http.Response(
          jsonEncode({
            'accepted': [
              for (final item in items) (item as Map)['templateHash'],
            ],
          }),
          202,
        );
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
        return http.Response('{"accepted":1}', 202);
      case '/sms/v2/sync':
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'cursor': 'one',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                if (aiStatus != 'none')
                  for (final hash in uploaded.toSet())
                    {
                      'templateHash': hash,
                      'status': aiStatus,
                      if (aiStatus == 'ready') ...{
                        'ruleId': 'AI-$hash',
                        'ruleVersion': 1,
                        'rule': ruleFor(hash),
                      },
                    },
              ],
              'corrections': [],
              'latestBundleVersion': servedBundle == null ? 1 : 2,
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
    for (final row in database.db.select(
      'SELECT payload FROM v2_ledger WHERE namespace=?',
      [_namespace],
    )) {
      total +=
          ((jsonDecode(row['payload'] as String) as Map)['amountMinor'] as num)
              .toInt();
    }
    return total;
  }

  List<Map<String, Object?>> openTemplateReviews() => [
    for (final row in database.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status!='resolved'",
      [_namespace],
    ))
      (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  ];

  AiResolution? resolutionOfFirst({Set<String> shared = const {}}) {
    for (final review in openTemplateReviews()) {
      final r = AiStatusReader(
        state,
      ).resolution(review['sourceKey'] as String, sharedRuleIds: shared);
      if (r != null) return r;
    }
    return null;
  }

  setUp(() async {
    consent = true;
    clockNow = DateTime.utc(2026, 11, 20, 12);
    aiStatus = 'none';
    servedBundle = null;
    uploaded.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'ai-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async =>
          RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => jsonEncode(baseline),
      accountIsCurrent: () => true,
      hasSharingConsent: () async => consent,
      clock: () => clockNow,
    );
    state = SyncStateStore(database.db, namespace: _namespace);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test(
    'S1 unreadable layout: reviewed, uploaded, shown as checking, no spend yet',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      expect(openTemplateReviews(), hasLength(1));
      expect(spendMinor(), 0);
      await sync();
      expect(
        uploaded,
        hasLength(1),
        reason: 'the redacted layout was uploaded',
      );
      final local = openTemplateReviews().single['templateHash'] as String;
      expect(
        AiStatusReader(state).templateState(local),
        AiTemplateState.checking,
      );
      aiStatus = 'pending';
      await sync();
      expect(
        AiStatusReader(state).templateState(local),
        AiTemplateState.checking,
      );
      expect(spendMinor(), 0, reason: 'nothing is counted before an answer');
      expect(
        AiStatusReader(state).hasChecking(),
        isTrue,
        reason: 'the needs-review notification waits while the AI is working',
      );
    },
  );

  test(
    'S2 the AI answer reads the message: spend is counted, labelled unverified',
    () async {
      await runtime.capture([
        _msg('RAHUL KUMAR', 450, 1),
        _msg('SWIGGY', 1200, 2),
      ]);
      await sync();
      aiStatus = 'ready';
      await sync();
      expect(
        spendMinor(),
        45000 + 120000,
        reason: 'AI-read spends count in the ledger',
      );
      final r = resolutionOfFirst();
      expect(r, isNotNull);
      expect(r!.verified, isFalse);
      // Still listed in Needs review (labelled), so the person can correct it.
      expect(openTemplateReviews(), isNotEmpty);
    },
  );

  test(
    'S3 a layout the AI could not read falls back to the plain state',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      aiStatus = 'rejected';
      await sync();
      final local = openTemplateReviews().single['templateHash'] as String;
      expect(
        AiStatusReader(state).templateState(local),
        AiTemplateState.unavailable,
      );
      expect(spendMinor(), 0);
      expect(AiStatusReader(state).hasChecking(), isFalse);
    },
  );

  test('S4 old invalid statuses are refused whole', () async {
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    await sync();
    aiStatus = 'failed';
    // The phone refuses the whole response, so it must never be sent.
    await expectLater(sync(), throwsA(isA<ContractException>()));
    expect(
      database.db.select(
        "SELECT 1 FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
        [_namespace],
      ),
      isEmpty,
    );
  });

  test('S5 an admin rejection after the AI reading was applied', () async {
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    await sync();
    aiStatus = 'ready';
    await sync();
    expect(spendMinor(), 45000);
    aiStatus = 'rejected';
    await sync();
    // The private rule is gone from this phone.
    expect(
      (await runtime.activeBundle()).rules.where((r) => r.id.startsWith('AI-')),
      isEmpty,
    );
    // What happens to the spend already counted is the decision this pins.
    expect(
      spendMinor(),
      0,
      reason: 'a rejected AI reading must not keep counting',
    );
    // The message is back as a plain Needs review item, with no AI reading.
    final reviews = openTemplateReviews();
    expect(reviews, hasLength(1));
    expect(resolutionOfFirst(), isNull);
    expect(
      database.db.select(
        "SELECT 1 FROM financial_entities WHERE namespace=? AND entity='transactions' AND coalesce(json_extract(payload,'\$.status'),'active')='active'",
        [_namespace],
      ),
      isEmpty,
      reason: 'the spend is gone from the display list too',
    );
    // A second sync changes nothing further.
    await sync();
    expect(spendMinor(), 0);
    expect(openTemplateReviews(), hasLength(1));
  });

  test(
    'S8 a reading the person already confirmed survives a rejection',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      aiStatus = 'ready';
      await sync();
      final events = EventStore(database.db, namespace: _namespace);
      final event = events.get(
        database.db.select('SELECT event_id FROM v2_events WHERE namespace=?', [
              _namespace,
            ]).single['event_id']
            as String,
      )!;
      events.upsert(
        event.copyWith(status: EventStatus.userConfirmed),
        fromUser: true,
      );
      aiStatus = 'rejected';
      await sync();
      expect(spendMinor(), 45000, reason: 'the person confirmed it; it stays');
    },
  );

  test('S6 publication: the same reading is then verified', () async {
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    await sync();
    aiStatus = 'ready';
    await sync();
    final hash = uploaded.first;
    final published = ruleFor(hash, status: 'active');
    published['match'] = {...(published['match'] as Map)}
      ..remove('templateHash');
    servedBundle = jsonEncode({
      ...baseline,
      'bundleVersion': 2,
      'createdAt': clockNow.toIso8601String(),
      'expiresAt': clockNow.add(const Duration(days: 7)).toIso8601String(),
      'signature': signature,
      'rules': [...(baseline['rules'] as List), published],
    });
    state.put('rules:latest', '2');
    await sync();
    final shared = (await runtime.activeBundle()).rules
        .where((r) => !r.id.contains(':local:'))
        .map((r) => r.id)
        .toSet();
    expect(shared, contains('AI-$hash'));
    expect(resolutionOfFirst(shared: shared)?.verified, isTrue);
  });

  test(
    'S7 turning sharing off clears the AI state and the checking label',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      aiStatus = 'ready';
      await sync();
      consent = false;
      aiStatus = 'none'; // the server returns nothing without consent
      await sync();
      expect(
        database.db.select(
          "SELECT 1 FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
          [_namespace],
        ),
        isEmpty,
      );
    },
  );
}
