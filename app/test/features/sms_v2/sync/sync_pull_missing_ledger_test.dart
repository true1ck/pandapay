import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// A phone that is installed again (or a second phone) builds its transactions
// from what the server sends. The server deletes an event's ledger rows when an
// account it touches is marked "Not mine", and nothing sends them back when the
// account is restored. An event with facts and an account but no ledger rows
// used to show nothing for ever. The pull now derives the missing rows, the way
// capture does, and queues them so the server learns them again.
void main() {
  const ns = 'target';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Map<String, Object?> body;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: 'source',
      bundle: bundle,
      appVersion: '2',
    ).process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: 'a' * 64,
        observedAt: DateTime.utc(2026, 11, 1, 7),
      ),
    );
    final rows = OutboxStore(
      database.db,
      namespace: 'source',
    ).due(DateTime.utc(2026, 12));
    List<Map<String, Object?>> kind(String kind) => [
      for (final row in rows)
        if (row.kind == kind) row.json,
    ];
    body = {
      'cursor': 'page-1',
      'facts': [for (final item in kind('source')) ...item['facts'] as List],
      'instruments': kind('instrument'),
      'events': kind('event'),
      'ledger': kind('ledger'),
      'aiResults': <Object?>[],
      'corrections': <Object?>[],
      'latestBundleVersion': 1,
      'updatedAt': {
        'events': {
          for (final event in kind('event'))
            event['eventId']: '2026-11-01T07:01:00Z',
        },
        'instruments': {
          for (final instrument in kind('instrument'))
            instrument['instrumentId']: '2026-11-01T07:01:00Z',
        },
        'ledger': {
          for (final entry in kind('ledger'))
            entry['entryId']: '2026-11-01T07:01:00Z',
        },
      },
    };
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  SyncPull puller(http.Client client) => SyncPull(
    financial: financial,
    namespace: ns,
    client: client,
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {},
    bundle: bundle,
  );

  Map<String, Object?> without(String key, [Object? value]) => {
    ...body,
    key: value ?? <Object?>[],
    if (key == 'ledger') 'updatedAt': {...(body['updatedAt'] as Map), 'ledger': {}},
  };

  http.Response reply(Map<String, Object?> page, {bool more = false}) =>
      http.Response(
        jsonEncode(page),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          if (more) 'x-sms-sync-has-more': '1',
        },
      );

  List<Map<String, Object?>> transactions() =>
      financial.entities(ns, 'transactions');
  int ledgerRows() => LedgerStore(database.db, namespace: ns).list().length;
  Map<String, int> queued() {
    final out = <String, int>{};
    for (final item in OutboxStore(
      database.db,
      namespace: ns,
    ).due(DateTime.utc(2030))) {
      out[item.kind] = (out[item.kind] ?? 0) + 1;
    }
    return out;
  }

  test('control: a server that still holds the ledger sends nothing back', () async {
    await puller(MockClient((_) async => reply(body))).pull();
    expect(transactions().single['status'], 'active');
    expect(ledgerRows(), 1);
    expect(queued()['ledger'], isNull);
  });

  test('an event whose ledger rows the server lost shows its transaction '
      'and the ledger is queued for the server', () async {
    await puller(MockClient((_) async => reply(without('ledger')))).pull();
    expect(transactions(), hasLength(1));
    expect(transactions().single['status'], 'active');
    expect(ledgerRows(), 1);
    expect(queued()['ledger'], 1);
  });

  test('the derived ledger is the one capture made', () async {
    final captured = LedgerStore(database.db, namespace: 'source').list().single;
    await puller(MockClient((_) async => reply(without('ledger')))).pull();
    final derived = LedgerStore(database.db, namespace: ns).list().single;
    expect(derived.entryId, captured.entryId);
    expect(derived.amountMinor, captured.amountMinor);
    expect(derived.eventId, captured.eventId);
  });

  test('an account marked Not mine stays hidden: nothing is derived', () async {
    final rejected = [
      for (final i in body['instruments'] as List)
        {...(i as Map).cast<String, Object?>(), 'status': 'rejected'},
    ];
    await puller(
      MockClient(
        (_) async => reply({...without('ledger'), 'instruments': rejected}),
      ),
    ).pull();
    expect(transactions().where((r) => r['status'] == 'active'), isEmpty);
    expect(ledgerRows(), 0);
    expect(queued()['ledger'], isNull);
  });

  Map<String, Object?> quiet({List<Object?> instruments = const []}) => {
    ...body,
    'cursor': 'page-2',
    'facts': <Object?>[],
    'instruments': instruments,
    'events': <Object?>[],
    'ledger': <Object?>[],
    'updatedAt': {
      'events': <String, Object?>{},
      'instruments': {
        for (final i in instruments)
          (i as Map)['instrumentId']: '2026-11-02T07:01:00Z',
      },
      'ledger': <String, Object?>{},
    },
  };

  test('an account marked Not mine and restored on another phone brings its '
      'transactions back', () async {
    final rejected = [
      for (final i in body['instruments'] as List)
        {...(i as Map).cast<String, Object?>(), 'status': 'rejected'},
    ];
    final restored = [
      for (final i in body['instruments'] as List)
        {...(i as Map).cast<String, Object?>(), 'status': 'detected'},
    ];
    await puller(
      MockClient(
        (_) async => reply({...without('ledger'), 'instruments': rejected}),
      ),
    ).pull();
    expect(transactions().where((r) => r['status'] == 'active'), isEmpty);
    // The account comes back: only its status changes on the server, the ledger
    // rows it deleted do not.
    await puller(
      MockClient((_) async => reply(quiet(instruments: restored))),
    ).pull();
    expect(transactions().where((r) => r['status'] == 'active'), hasLength(1));
    expect(ledgerRows(), 1);
    expect(queued()['ledger'], 1);
  });

  test('a second pull derives and queues nothing more', () async {
    await puller(MockClient((_) async => reply(without('ledger')))).pull();
    await puller(MockClient((_) async => reply(quiet()))).pull();
    expect(ledgerRows(), 1);
    expect(queued()['ledger'], 1);
    expect(transactions().single['status'], 'active');
  });

  test('a quiet pull does not look through the account again', () async {
    await puller(MockClient((_) async => reply(body))).pull();
    database.db.execute('DELETE FROM v2_ledger WHERE namespace=?', [ns]);
    // The marker says every event was looked at on this build, and this pull
    // names no event and changes no account, so nothing is scanned.
    await puller(MockClient((_) async => reply(quiet()))).pull();
    expect(ledgerRows(), 0);
  });

  test('the look-up for events without ledger rows uses the event index', () {
    final plan = database.db
        .select(
          'EXPLAIN QUERY PLAN SELECT e.event_id FROM v2_events e WHERE e.namespace=? '
          'AND NOT EXISTS (SELECT 1 FROM v2_ledger l WHERE l.namespace=e.namespace AND l.event_id=e.event_id) '
          "AND e.status<>'ambiguous' AND e.type<>'unknown'",
          [ns],
        )
        .map((row) => row['detail'] as String)
        .join('\n');
    expect(plan, contains('idx_v2_ledger_event'));
    expect(plan, isNot(contains('SCAN l')));
  });

  test('an ambiguous event gets no ledger', () async {
    final ambiguous = [
      for (final e in body['events'] as List)
        {...(e as Map).cast<String, Object?>(), 'status': 'ambiguous'},
    ];
    await puller(
      MockClient((_) async => reply({...without('ledger'), 'events': ambiguous})),
    ).pull();
    expect(ledgerRows(), 0);
    expect(transactions().where((r) => r['status'] == 'active'), isEmpty);
    expect(queued()['ledger'], isNull);
  });

  test('ledger rows that arrive on a later page are the server\'s, not derived',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return reply({...without('ledger'), 'cursor': 'page-1'}, more: true);
      }
      return reply({
        'cursor': 'page-2',
        'facts': <Object?>[],
        'instruments': <Object?>[],
        'events': <Object?>[],
        'ledger': body['ledger'],
        'aiResults': <Object?>[],
        'corrections': <Object?>[],
        'latestBundleVersion': 1,
        'updatedAt': {
          'events': <String, Object?>{},
          'instruments': <String, Object?>{},
          'ledger': (body['updatedAt'] as Map)['ledger'],
        },
      });
    });
    await puller(client).pull();
    expect(calls, 2);
    expect(ledgerRows(), 1);
    // Nothing was derived while the pull was unfinished, so nothing is re-sent.
    expect(queued()['ledger'], isNull);
    expect(transactions().single['status'], 'active');
  });

  test('an event kept without ledger by an earlier build is healed by the next '
      'pull', () async {
    await puller(MockClient((_) async => reply(body))).pull();
    expect(ledgerRows(), 1);
    // What an earlier build left: the event stays, its ledger rows are gone and
    // the saved row is retired; the heal marker of this build is not there yet.
    database.db.execute('DELETE FROM v2_ledger WHERE namespace=?', [ns]);
    database.db.execute(
      "UPDATE financial_entities SET payload=json_set(payload,'\$.status','ignored') "
      "WHERE namespace=? AND entity='transactions'",
      [ns],
    );
    database.db.execute(
      "DELETE FROM v2_sync_state WHERE namespace=? AND key LIKE 'ledger:heal:%'",
      [ns],
    );
    expect(transactions().single['status'], 'ignored');
    final empty = {
      ...body,
      'cursor': 'page-2',
      'facts': <Object?>[],
      'instruments': <Object?>[],
      'events': <Object?>[],
      'ledger': <Object?>[],
      'updatedAt': {
        'events': <String, Object?>{},
        'instruments': <String, Object?>{},
        'ledger': <String, Object?>{},
      },
    };
    await puller(MockClient((_) async => reply(empty))).pull();
    expect(ledgerRows(), 1);
    expect(transactions().single['status'], 'active');
    expect(queued()['ledger'], 1);
  });
}
