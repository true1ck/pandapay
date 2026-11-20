// What the phone does with an AI draft over its life, through the real runtime
// with a fake server (same harness idea as ai_scenarios_phone_test.dart):
//  - a second revision of a draft reaches messages the first revision read,
//  - a draft the server took back (quarantined, so the phone sees "pending")
//    stops counting what it read,
//  - a withdrawal leaves nothing queued for upload (source, event, ledger),
//  - a message read again by another rule leaves one reading, not two,
//  - the withdrawal pass does no whole-history work when there is nothing to do.
// Synthetic messages and ids only.
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
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:life';
const _draft1 = '11111111-1111-4111-8111-111111111111';
const _draft2 = '22222222-2222-4222-8222-222222222222';

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
  var clockNow = DateTime.utc(2026, 11, 20, 12);
  // What the server answers for every layout this phone uploaded.
  var answer = <String, Object?>{'status': 'none'};
  var factsStatus = 200;
  String? servedBundle;
  final uploaded = <String>[];
  final fixture =
      (jsonDecode(
                File(
                  'test/features/sms_v2/fixtures/real_gemini_rule.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  final fullBundle =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  // A rule set that reads nothing: every message of this layout is unknown.
  final baseline = <String, Object?>{
    ...fullBundle,
    'rules': <Object?>[],
    'categoryRules': <Object?>[],
  };

  /// The draft's rule for [hash]; [purpose] is what tells revision 1 from 2.
  Map<String, Object?> ruleFor(String hash, {String purpose = 'purchase'}) {
    final rule = (jsonDecode(jsonEncode(fixture['rule'])) as Map)
        .cast<String, Object?>();
    final emit = (rule['emit'] as List).cast<Map>().single;
    return {
      ...rule,
      'id': 'AI-$hash',
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

  void ready(String purpose, String draftId) =>
      answer = {'status': 'ready', 'purpose': purpose, 'draftId': draftId};
  void pending() => answer = {'status': 'pending'};
  void rejected() => answer = {'status': 'rejected'};

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
        if (factsStatus != 200) return http.Response('{}', factsStatus);
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
        final status = answer['status'] as String;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'cursor': 'one',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                if (status != 'none')
                  for (final hash in uploaded.toSet())
                    {
                      'templateHash': hash,
                      'status': status,
                      if (status == 'ready') ...{
                        'ruleId': 'AI-$hash',
                        'ruleVersion': 1,
                        'rule': ruleFor(
                          hash,
                          purpose: answer['purpose'] as String,
                        ),
                        'draftId': answer['draftId'],
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

  /// The purpose each stored money movement was read with.
  List<String?> purposes() => [
    for (final row in database.db.select(
      "SELECT payload FROM v2_facts WHERE namespace=? AND fact_type='movement'",
      [_namespace],
    ))
      ((jsonDecode(row['payload'] as String) as Map)['attrs'] as Map)['purpose']
          as String?,
  ];

  List<String> outboxIds() => [
    for (final row in database.db.select(
      'SELECT id FROM v2_outbox WHERE namespace=? ORDER BY id',
      [_namespace],
    ))
      row['id'] as String,
  ];

  int count(String sql) =>
      database.db.select(sql, [_namespace]).single.values.first as int;

  setUp(() {
    clockNow = DateTime.utc(2026, 11, 20, 12);
    answer = {'status': 'none'};
    factsStatus = 200;
    servedBundle = null;
    uploaded.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'life-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async =>
          RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => jsonEncode(baseline),
      accountIsCurrent: () => true,
      hasSharingConsent: () async => true,
      clock: () => clockNow,
    );
    state = SyncStateStore(database.db, namespace: _namespace);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  /// One unreadable layout, uploaded, then read by the first draft.
  Future<void> readByFirstDraft() async {
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    await sync();
    ready('purchase', _draft1);
    await sync();
    expect(spendMinor(), 45000, reason: 'the first draft read the message');
    expect(purposes(), ['purchase']);
  }

  test(
    'F-3 a second revision of the draft reaches what the first read',
    () async {
      await readByFirstDraft();
      ready('p2p', _draft2);
      await sync();
      expect(purposes(), [
        'p2p',
      ], reason: 'revision 2 must replace the reading revision 1 made');
      expect(spendMinor(), 45000, reason: 'and the spend is counted once');
      await sync();
      expect(purposes(), ['p2p'], reason: 'a later sync changes nothing');
      expect(spendMinor(), 45000);
    },
  );

  test('F-3 a revision the person already confirmed is left alone', () async {
    await readByFirstDraft();
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
    ready('p2p', _draft2);
    await sync();
    expect(purposes(), ['purchase'], reason: 'the person confirmed it');
    expect(spendMinor(), 45000);
  });

  test(
    'S5-02 a draft the server took back stops counting what it read',
    () async {
      await readByFirstDraft();
      // Quarantine: the server queues a replacement, phones see "pending".
      pending();
      await sync();
      expect(
        spendMinor(),
        0,
        reason: 'a draft that is no longer offered must not keep counting',
      );
      expect(purposes(), isEmpty);
      expect(
        count(
          "SELECT count(*) FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
        ),
        1,
        reason: 'the message is a plain Needs review item again',
      );
      // The replacement arrives and reads it again.
      ready('p2p', _draft2);
      await sync();
      expect(purposes(), ['p2p']);
      expect(spendMinor(), 45000);
    },
  );

  test(
    'S5-02 a pending answer before any draft read anything changes nothing',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      pending();
      await sync();
      await sync();
      expect(spendMinor(), 0);
      ready('purchase', _draft1);
      await sync();
      expect(spendMinor(), 45000);
    },
  );

  test('F-5 a withdrawal leaves nothing queued for upload', () async {
    // The server is down, so what the draft's reading queued stays queued.
    factsStatus = 503;
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    try {
      await sync();
    } catch (_) {}
    ready('purchase', _draft1);
    try {
      await sync();
    } catch (_) {}
    expect(spendMinor(), 45000);
    final queued = outboxIds().where(
      (id) =>
          id.startsWith('event:') ||
          id.startsWith('ledger:') ||
          id.startsWith('source:'),
    );
    expect(
      queued.map((id) => id.split(':').first).toSet(),
      containsAll(['event', 'ledger', 'source']),
      reason: 'precondition: the reading is waiting to be sent',
    );
    rejected();
    try {
      await sync();
    } catch (_) {}
    expect(spendMinor(), 0);
    final left = outboxIds().where(
      (id) =>
          id.startsWith('event:') ||
          id.startsWith('ledger:') ||
          id.startsWith('source:'),
    );
    expect(
      left,
      isEmpty,
      reason: 'nothing of the withdrawn reading may be sent to the server',
    );
  });

  test('F-6 a message read again by another rule leaves one reading', () async {
    await readByFirstDraft();
    final before = database.db.select(
      'SELECT fact_id FROM v2_facts WHERE namespace=? ORDER BY fact_id',
      [_namespace],
    );
    ready('p2p', _draft2);
    await sync();
    int rows(String table) =>
        count('SELECT count(*) FROM $table WHERE namespace=?');
    expect(rows('v2_events'), 1, reason: 'one event for one message');
    expect(rows('v2_ledger'), 1, reason: 'one ledger row, no double count');
    expect(
      database.db.select(
        'SELECT fact_id FROM v2_facts WHERE namespace=? ORDER BY fact_id',
        [_namespace],
      ).length,
      before.length,
      reason: 'no orphan facts of the earlier reading',
    );
    expect(
      count(
        "SELECT count(*) FROM financial_entities WHERE namespace=? AND entity='transactions' AND coalesce(json_extract(payload,'\$.status'),'active')='active'",
      ),
      1,
      reason: 'one live row in the display list',
    );
  });

  test(
    'F-6 the queue holds one reading after another rule read the message',
    () async {
      factsStatus = 503; // nothing is sent, so everything stays queued
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      Future<void> trySync() async {
        try {
          await sync();
        } catch (_) {}
      }

      await trySync();
      ready('purchase', _draft1);
      await trySync();
      ready('p2p', _draft2);
      await trySync();
      expect(purposes(), ['p2p']);
      final queued =
          outboxIds()
              .where(
                (id) =>
                    id.startsWith('event:') ||
                    id.startsWith('ledger:') ||
                    id.startsWith('source:'),
              )
              .map((id) => id.split(':').first)
              .toList()
            ..sort();
      expect(
        queued,
        ['event', 'ledger', 'source'],
        reason:
            'one event, one ledger row, one source: nothing of revision 1 is still queued',
      );
    },
  );

  test('F-10 the count of messages read again is the count the pipeline read', () async {
    await runtime.capture([
      _msg('RAHUL KUMAR', 450, 1),
      // Another layout nothing reads: stays unknown.
      QueuedSms(
        sender: 'AX-HDFCBK-S',
        body:
            'Paid Rs.99.00 from HDFC Bank A/c XX1234 for order 77 on 20-11-26.',
        receivedAt: DateTime.utc(2026, 11, 20, 8),
      ),
      QueuedSms(
        sender: 'AX-HDFCBK-S',
        body:
            'Paid Rs.98.00 from HDFC Bank A/c XX1234 for order 78 on 20-11-26.',
        receivedAt: DateTime.utc(2026, 11, 20, 9),
      ),
    ]);
    await sync();
    ready('purchase', _draft1);
    await sync();
    expect(
      spendMinor(),
      45000,
      reason: 'one message read by the draft, two unknown',
    );
    final state = SyncStateStore(database.db, namespace: _namespace);

    // The rules in force did not change since the last read: nothing to read.
    database.db.execute(
      "DELETE FROM v2_sync_state WHERE namespace=? AND key='pipeline:revision'",
      [_namespace],
    );
    final same = await runtime.refreshRulesAndReanalyze();
    expect(
      same.rereadMessages,
      0,
      reason:
          'the two unknown messages were read under these rules already, the third is read',
    );

    // The two unknown ones were last read under older rules: they are read again.
    database.db.execute(
      "UPDATE sms_source_decisions SET parser_version='old' WHERE namespace=? AND decision='unknown'",
      [_namespace],
    );
    database.db.execute(
      "DELETE FROM v2_sync_state WHERE namespace=? AND key='pipeline:revision'",
      [_namespace],
    );
    expect(state.get('pipeline:revision'), isNull);
    final again = await runtime.refreshRulesAndReanalyze();
    expect(again.rereadMessages, 2);
  });

  test(
    'F-2 a signed rule for the layout beats the AI draft whatever its priority',
    () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync(); // uploaded: the phone now holds the layout's origin
      ready('p2p', _draft2); // the draft would read it as p2p
      // A signed rule for the same layout, at a low priority, reads it as a purchase.
      final signed = ruleFor(uploaded.first, purpose: 'purchase');
      signed
        ..['id'] = 'SIGNED-HDFC-DEBIT'
        ..['status'] = 'active'
        ..['priority'] = 10
        ..['match'] = (Map.of(signed['match'] as Map)..remove('templateHash'));
      servedBundle = jsonEncode({
        ...baseline,
        'bundleVersion': 2,
        'createdAt': clockNow.toIso8601String(),
        'expiresAt': clockNow.add(const Duration(days: 7)).toIso8601String(),
        'signature': fullBundle['signature'],
        'rules': [signed],
      });
      state.put('rules:latest', '2');
      await sync();
      expect(purposes(), [
        'purchase',
      ], reason: 'the signed rule read it, not the draft');
      final trace =
          jsonDecode(
                database.db.select(
                      "SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%'",
                      [_namespace],
                    ).single['value']
                    as String,
              )
              as Map;
      expect(trace['ruleId'], 'SIGNED-HDFC-DEBIT');
    },
  );

  // F-7 / F-8: how much work the withdrawal side does on a phone with a long
  // history. N messages read by one draft (A4A_SCALE, default small), plus
  // unrelated traces and rejected layouts, as a long-lived phone has. Timings
  // are printed ("A4A_BENCH ..."); what is asserted is that the new code gives
  // the same answers as the replica of the old queries kept here.
  test('F-7/F-8 withdrawal work does not grow with the history', () async {
    const scale = int.fromEnvironment('A4A_SCALE', defaultValue: 300);
    const otherTraces = scale * 3;
    const rejectedLayouts = 20;
    final messages = [
      for (var i = 0; i < scale; i++)
        QueuedSms(
          sender: 'AX-HDFCBK-S',
          body:
              'Sent Rs.${100 + i}.00 from HDFC Bank A/c XX1234 to RAHUL KUMAR on 20-11-26. Ref 9${100000 + i}.',
          receivedAt: DateTime.utc(
            2026,
            11,
            20,
            0,
            0,
          ).add(Duration(minutes: i)),
        ),
    ];
    await runtime.capture(messages);
    await sync();
    ready('purchase', _draft1);
    await sync();
    expect(spendMinor(), greaterThan(0));
    final db = database.db;
    final aiSources = [
      for (final row in db.select(
        "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%'",
        [_namespace],
      ))
        (row['key'] as String).substring('trace:'.length),
    ];
    expect(aiSources, hasLength(scale));
    final hash = uploaded.first;

    // A long-lived phone: many traces of other rules, and layouts rejected long ago.
    final sample =
        db.select(
              "SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%' LIMIT 1",
              [_namespace],
            ).single['value']
            as String;
    final stmt = db.prepare(
      'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?)',
    );
    for (var i = 0; i < otherTraces; i++) {
      stmt.execute([
        _namespace,
        'trace:other-$i',
        sample.replaceAll('"AI-$hash:local:', '"HDFC-DEBIT-$i:x:'),
      ]);
    }
    for (var i = 0; i < rejectedLayouts; i++) {
      stmt.execute([
        _namespace,
        'ai:old-layout-$i',
        jsonEncode({'templateHash': 'old-layout-$i', 'status': 'rejected'}),
      ]);
    }
    stmt.dispose();

    final withdrawal = AiWithdrawal(
      financial: financial,
      namespace: _namespace,
      bundle: await runtime.activeBundle(),
    );
    final clock = Stopwatch();
    int micros(void Function() body) {
      clock
        ..reset()
        ..start();
      body();
      return clock.elapsedMicroseconds;
    }

    // --- F-8: what every sync did to find AI readings to take back ------------
    List<String> oldSourcesRead(String remoteHash) => [
      for (final row in db.select(
        "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%'",
        [_namespace],
      ))
        if (() {
          try {
            final id = (jsonDecode(row['value'] as String) as Map)['ruleId'];
            return id is String && id.startsWith('AI-$remoteHash:local:');
          } catch (_) {
            return false;
          }
        }())
          (row['key'] as String).substring('trace:'.length),
    ];
    // Every sync, before: one full trace scan per rejected layout, forever.
    final rejected = withdrawal.rejectedTemplates();
    expect(rejected, hasLength(rejectedLayouts));
    late List<String> oldFound;
    final oldPerSync = micros(() {
      oldFound = [for (final h in rejected) ...oldSourcesRead(h)];
    });
    // After: the layouts are marked as done; a sync reads a few state rows.
    final shared = await runtime.activeBundle();
    final first = withdrawal.takeBackPlan(shared);
    expect(first.hashes, hasLength(rejectedLayouts));
    first.commit();
    late ({Set<String> hashes, void Function() commit}) steady;
    final newPerSync = micros(() {
      steady = withdrawal.takeBackPlan(shared);
    });
    expect(steady.hashes, isEmpty, reason: 'nothing left to look for');
    expect(oldFound, isEmpty);
    // The one scan, when there is something to take back, finds the same sources.
    late List<String> oldSet;
    final oldScan = micros(() => oldSet = oldSourcesRead(hash));
    late Map<String, List<String>> newSet;
    final newScan = micros(() => newSet = withdrawal.sourcesReadBy({hash}));
    expect(newSet[hash]!.toSet(), oldSet.toSet());
    expect(oldSet, hasLength(scale));

    // --- F-7: the person's-word check of a recheck loop -----------------------
    final facts = FactStore(db, namespace: _namespace);
    final events = EventStore(db, namespace: _namespace);
    bool oldTouched(String source) {
      final sourceFacts = facts.forSource(source);
      if (sourceFacts.any((f) => f.provenance.engine == Engine.user))
        return true;
      return events
          .findByFactIds(sourceFacts.map((f) => f.factId))
          .any((e) => e.status == EventStatus.userConfirmed);
    }

    final probe = aiSources.take(200).toList();
    late List<bool> oldAnswers;
    final oldTouchedMicros = micros(() {
      oldAnswers = [for (final s in probe) oldTouched(s)];
    });
    late List<bool> newAnswers;
    final newTouchedMicros = micros(() {
      newAnswers = [for (final s in probe) withdrawal.touchedByPerson(s)];
    });
    expect(newAnswers, oldAnswers);

    // --- F-7: the reads one withdrawal does for a handful of sources ----------
    final few = aiSources.take(20).toList();
    final oldReads = micros(() {
      facts.since(DateTime.utc(1900));
      facts.instrumentIdsSince(DateTime.utc(1900));
      facts.instrumentIdsSince(DateTime.utc(1900));
    });
    late List<String> taken;
    final newWithdraw = micros(() => taken = withdrawal.withdraw(few));
    expect(taken.toSet(), few.toSet());
    // ignore: avoid_print
    print(
      'A4A_BENCH scale=$scale otherTraces=$otherTraces rejected=$rejectedLayouts '
      'perSync_us old=$oldPerSync new=$newPerSync | '
      'traceScan_us old=$oldScan new=$newScan | '
      'touched200_us old=$oldTouchedMicros new=$newTouchedMicros | '
      'withdraw20: oldWholeHistoryReads_us=$oldReads newWithdrawTotal_us=$newWithdraw',
    );
  });
}
