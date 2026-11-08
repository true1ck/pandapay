// A sync pull must cost what CHANGED, not the whole history (PERFORMANCE_RULEBOOK
// section 4, item 1). These tests pin the behaviour with work counts (rows
// written, statements-by-trigger), never wall-clock, and prove the incremental
// projection leaves exactly the rows a full rebuild would.
//
// The wall-clock comparison for a large synthetic ledger is skipped by default:
//
//   cd app && flutter test --no-pub --dart-define=SYNC_PULL_BENCHMARK=true \
//     --dart-define=SYNC_PULL_BENCHMARK_COUNT=4000 \
//     test/features/sms_v2/sync/sync_pull_incremental_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';
import '../support/synthetic_corpus.dart';

const _benchmark = bool.fromEnvironment('SYNC_PULL_BENCHMARK');
const _benchmarkCount = int.fromEnvironment(
  'SYNC_PULL_BENCHMARK_COUNT',
  defaultValue: 4000,
);
const _dumpPath = String.fromEnvironment('SYNC_PULL_DUMP');

/// What the server would return for the whole of [namespace]'s local store.
class _Export {
  _Export(this.facts, this.instruments, this.events, this.ledger);
  final Map<String, Map<String, Object?>> facts;
  final Map<String, Map<String, Object?>> instruments;
  final Map<String, Map<String, Object?>> events;
  final Map<String, Map<String, Object?>> ledger;
}

_Export _export(Database db, String namespace) => _Export(
  {
    for (final f in FactStore(db, namespace: namespace).all())
      f.factId: f.toJson(),
  },
  {
    for (final i in InstrumentStore(db, namespace: namespace).list())
      i.instrumentId: i.toJson(),
  },
  {
    for (final e in EventStore(db, namespace: namespace).listSince(DateTime.utc(1900)))
      e.eventId: e.toJson(),
  },
  {
    for (final e in LedgerStore(db, namespace: namespace).list())
      e.entryId: e.toJson(),
  },
);

/// The records of [now] that are new or different since [before].
Map<String, Object?> _body(
  _Export now, {
  _Export? before,
  required String cursor,
  String stamp = '2026-11-01T07:01:00Z',
}) {
  List<Map<String, Object?>> delta(
    Map<String, Map<String, Object?>> a,
    Map<String, Map<String, Object?>>? b,
  ) => [
    for (final entry in a.entries)
      if (b == null || jsonEncode(b[entry.key]) != jsonEncode(entry.value))
        entry.value,
  ];
  final facts = delta(now.facts, before?.facts);
  final instruments = delta(now.instruments, before?.instruments);
  final events = delta(now.events, before?.events);
  final ledger = delta(now.ledger, before?.ledger);
  return {
    'cursor': cursor,
    'facts': facts,
    'instruments': instruments,
    'events': events,
    'ledger': ledger,
    'aiResults': <Object?>[],
    'corrections': <Object?>[],
    'latestBundleVersion': 1,
    'updatedAt': {
      'events': {for (final e in events) e['eventId']: stamp},
      'instruments': {for (final i in instruments) i['instrumentId']: stamp},
      'ledger': {for (final l in ledger) l['entryId']: stamp},
    },
  };
}

Map<String, Object?> _empty(String cursor) => {
  'cursor': cursor,
  'facts': <Object?>[],
  'instruments': <Object?>[],
  'events': <Object?>[],
  'ledger': <Object?>[],
  'aiResults': <Object?>[],
  'corrections': <Object?>[],
  'latestBundleVersion': 1,
  'updatedAt': {'events': {}, 'instruments': {}, 'ledger': {}},
};

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  final bundle = testRuleBundle();

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  /// Runs [count] synthetic messages through the real phone pipeline into
  /// namespace `source`, [from, to) of the corpus.
  void ingest(List<SmsMessage> messages) {
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: 'source',
      bundle: bundle,
      appVersion: '2',
    );
    for (var i = 0; i < messages.length; i += 500) {
      pipeline.processBatch(
        messages.sublist(i, (i + 500).clamp(0, messages.length)),
        backfill: true,
      );
    }
  }

  List<SmsMessage> corpus(int count, {int seed = 11}) => [
    for (final (i, m)
        in SyntheticCorpus.generate(bundle, count: count, seed: seed).messages.indexed)
      SmsMessage(
        sender: m.sender,
        body: m.body,
        sourceKey: sha256.convert(utf8.encode('$seed-$i-${m.body}')).toString(),
        observedAt: m.receivedAt.toUtc(),
      ),
  ];

  /// Pulls [bodies] in order into `target` and returns the puller.
  Future<SyncPull> pullAll(
    List<Map<String, Object?>> bodies, {
    RuleBundle? useBundle,
    Map<String, String> categories = const {},
  }) async {
    var index = 0;
    final client = MockClient((_) async {
      final body = bodies[index++];
      return http.Response(
        jsonEncode(body),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'x-sms-sync-has-more': index < bodies.length ? '1' : '0',
        },
      );
    });
    final puller = SyncPull(
      financial: financial,
      namespace: 'target',
      client: client,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      bundle: useBundle ?? bundle,
      categoryIdBySlug: categories,
    );
    await puller.pull();
    return puller;
  }

  Future<void> pullOne(
    Map<String, Object?> body, {
    RuleBundle? useBundle,
    Map<String, String> categories = const {},
  }) => pullAll([body], useBundle: useBundle, categories: categories);

  /// Everything a pull writes that a user can see or that sync reads.
  List<String> state(String namespace) {
    final rows = <String>[];
    for (final r in database.db.select(
      "SELECT id,payload FROM financial_entities WHERE namespace=? AND entity='transactions' ORDER BY id",
      [namespace],
    )) {
      rows.add('tx ${r['id']} ${r['payload']}');
    }
    for (final r in database.db.select(
      'SELECT entry_id,event_id,dirty,payload FROM v2_ledger WHERE namespace=? ORDER BY entry_id',
      [namespace],
    )) {
      rows.add('ledger ${r['entry_id']} ${r['dirty']} ${r['payload']}');
    }
    for (final r in database.db.select(
      'SELECT event_id,dirty,payload FROM v2_events WHERE namespace=? ORDER BY event_id',
      [namespace],
    )) {
      rows.add('event ${r['event_id']} ${r['dirty']} ${r['payload']}');
    }
    for (final r in database.db.select(
      'SELECT id FROM v2_outbox WHERE namespace=? ORDER BY id',
      [namespace],
    )) {
      rows.add('outbox ${r['id']}');
    }
    return rows;
  }

  /// Counts every row written to the display and ledger tables from now on.
  void countWrites() {
    database.db.execute('CREATE TABLE IF NOT EXISTS write_count(t TEXT)');
    database.db.execute('DELETE FROM write_count');
    for (final table in ['financial_entities', 'v2_ledger']) {
      for (final op in ['INSERT', 'UPDATE']) {
        database.db.execute(
          'CREATE TRIGGER IF NOT EXISTS count_${table}_$op AFTER $op ON $table '
          "BEGIN INSERT INTO write_count VALUES('$table'); END",
        );
      }
    }
  }

  int writes(String table) => database.db
      .select('SELECT COUNT(*) AS n FROM write_count WHERE t=?', [table])
      .single['n'] as int;

  /// Page one and page two of a source history, and the whole of it.
  ({List<Map<String, Object?>> pages, Map<String, Object?> whole, _Export all})
  history(int count) {
    final messages = corpus(count);
    final cut = messages.length * 3 ~/ 4;
    ingest(messages.sublist(0, cut));
    final first = _export(database.db, 'source');
    ingest(messages.sublist(cut));
    final all = _export(database.db, 'source');
    return (
      pages: [
        _body(first, cursor: 'page-1'),
        _body(all, before: first, cursor: 'page-2', stamp: '2026-11-02T07:01:00Z'),
      ],
      whole: _body(all, cursor: 'whole'),
      all: all,
    );
  }

  test(
    'incremental pulls leave exactly the rows a forced full rebuild leaves',
    () async {
      final h = history(500);
      expect((h.pages[1]['events'] as List), isNotEmpty);
      await pullAll(h.pages);
      final incremental = state('target');
      expect(incremental.where((r) => r.startsWith('tx ')), isNotEmpty);

      // Force a full rebuild by forgetting what the last projection was built
      // from, then pull a page with no changes at all.
      database.db.execute(
        "DELETE FROM v2_sync_state WHERE namespace='target' AND key='projection:context'",
      );
      await pullOne(_empty('page-3'));
      expect(state('target'), incremental);

      // A second device that receives everything in one page agrees too.
      database.db.execute("DELETE FROM v2_sync_state WHERE namespace='target' AND key LIKE 'clock:%'");
      database.db.execute("DELETE FROM v2_ledger WHERE namespace='target'");
      database.db.execute("DELETE FROM v2_events WHERE namespace='target'");
      database.db.execute("DELETE FROM v2_facts WHERE namespace='target'");
      database.db.execute("DELETE FROM v2_instruments WHERE namespace='target'");
      database.db.execute("DELETE FROM financial_entities WHERE namespace='target'");
      database.db.execute("DELETE FROM v2_sync_state WHERE namespace='target'");
      await pullOne(h.whole);
      expect(state('target'), incremental);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a pull that touches one event of many rewrites only that event',
    () async {
      final h = history(500);
      await pullOne(h.whole);
      final ledger = LedgerStore(database.db, namespace: 'target');
      final entries = ledger.list();
      expect(entries.length, greaterThan(100));
      final txBefore = state('target');

      // Nothing new at all: nothing written.
      countWrites();
      await pullOne(_empty('idle'));
      expect(writes('financial_entities'), 0);
      expect(writes('v2_ledger'), 0);
      expect(state('target'), txBefore);

      // A category-only update of one entry (another device recategorised).
      final pick = entries.firstWhere((e) => e.isSpend && e.category != null);
      final body = _empty('one-category');
      body['ledger'] = [
        {
          ...pick.toJson(),
          'category': pick.category == 'groceries' ? 'dining' : 'groceries',
          'categorySource': 'shared',
        },
      ];
      (body['updatedAt'] as Map)['ledger'] = {
        pick.entryId: '2026-11-09T00:00:00Z',
      };
      countWrites();
      await pullOne(body);
      // ignore: avoid_print
      print('one-entry pull wrote ${writes('financial_entities')} display and ${writes('v2_ledger')} ledger rows of ${entries.length}');
      expect(writes('financial_entities'), lessThanOrEqualTo(2));
      expect(writes('v2_ledger'), lessThanOrEqualTo(6));
      final after = state('target');
      final changed = [
        for (var i = 0; i < after.length; i++)
          if (!txBefore.contains(after[i])) after[i],
      ];
      expect(changed.length, lessThanOrEqualTo(4));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an instrument whose projection inputs did not change does not force a rebuild; one that did does',
    () async {
      final h = history(300);
      await pullOne(h.whole);
      final instruments = InstrumentStore(database.db, namespace: 'target').list();
      expect(instruments, isNotEmpty);
      final victim = instruments.first;

      // lastSeen / evidence move on every new message of a known card.
      final touch = _empty('instrument-seen');
      touch['instruments'] = [
        {
          ...victim.toJson(),
          'evidenceCount': victim.evidenceCount + 7,
          'lastSeenAt': DateTime.utc(2026, 12, 1).toIso8601String(),
        },
      ];
      (touch['updatedAt'] as Map)['instruments'] = {
        victim.instrumentId: '2026-11-10T00:00:00Z',
      };
      countWrites();
      await pullOne(touch);
      expect(writes('financial_entities'), 0);
      expect(writes('v2_ledger'), 0);

      // A rename changes how every transaction of that card is shown.
      final rename = _empty('instrument-renamed');
      rename['instruments'] = [
        {...victim.toJson(), 'displayName': 'Renamed by another device'},
      ];
      (rename['updatedAt'] as Map)['instruments'] = {
        victim.instrumentId: '2026-11-11T00:00:00Z',
      };
      await pullOne(rename);
      final names = database.db
          .select(
            "SELECT DISTINCT json_extract(payload,'\$.card_name') AS n FROM financial_entities WHERE namespace='target' AND entity='transactions'",
          )
          .map((r) => r['n']);
      expect(names, contains('Renamed by another device'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a changed rule bundle or category catalogue refreshes every row once',
    () async {
      final h = history(200);
      await pullOne(h.whole);
      final context = SyncStateStore(database.db, namespace: 'target')
          .get('projection:context');
      expect(context, isNotNull);
      await pullOne(_empty('same-context'));
      expect(
        SyncStateStore(database.db, namespace: 'target').get('projection:context'),
        context,
      );
      await pullOne(
        _empty('catalogue'),
        categories: {'dining': '00000000-0000-4000-8000-0000000000aa'},
      );
      expect(
        SyncStateStore(database.db, namespace: 'target').get('projection:context'),
        isNot(context),
      );
      expect(
        database.db
            .select(
              "SELECT COUNT(*) AS n FROM financial_entities WHERE namespace='target' AND entity='transactions' AND json_extract(payload,'\$.category_id')='00000000-0000-4000-8000-0000000000aa'",
            )
            .single['n'],
        greaterThan(0),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'SyncPull benchmark: $_benchmarkCount events, one-event pull',
    () async {
      final stage = Stopwatch()..start();
      final h = history(_benchmarkCount);
      final built = stage.elapsedMilliseconds;
      final events = h.all.events.length;
      final report = StringBuffer()
        ..writeln('messages $_benchmarkCount -> facts ${h.all.facts.length}, events $events, ledger ${h.all.ledger.length} (source built in $built ms)');
      countWrites();
      stage
        ..reset()
        ..start();
      await pullAll(h.pages);
      report
        ..writeln('initial two-page pull: ${stage.elapsedMilliseconds} ms, display rows written ${writes('financial_entities')}, ledger rows written ${writes('v2_ledger')}');

      final ledger = LedgerStore(database.db, namespace: 'target');
      final entries = ledger.list();
      final pick = entries.firstWhere((e) => e.isSpend && e.category != null);
      Map<String, Object?> oneCategory(String cursor) {
        final body = _empty(cursor);
        body['ledger'] = [
          {
            ...pick.toJson(),
            'category': cursor.hashCode.isEven ? 'dining' : 'groceries',
            'categorySource': 'shared',
          },
        ];
        (body['updatedAt'] as Map)['ledger'] = {
          pick.entryId: '2026-11-1${cursor.length % 9}T00:00:00Z',
        };
        return body;
      }

      for (final (label, body) in [
        ('idle pull (nothing changed)', _empty('idle')),
        ('one-entry category pull', oneCategory('cat-one')),
        ('one-entry category pull again', oneCategory('cat-two-')),
      ]) {
        countWrites();
        stage
          ..reset()
          ..start();
        await pullOne(body);
        report.writeln(
          '$label: ${stage.elapsedMilliseconds} ms, display rows written ${writes('financial_entities')}, ledger rows written ${writes('v2_ledger')}',
        );
      }
      // ignore: avoid_print
      print(report);
      File('${Directory.systemTemp.path}/sync_pull_benchmark.txt')
          .writeAsStringSync(report.toString(), mode: FileMode.append);
      if (_dumpPath.isNotEmpty) {
        // Instrument ids are random per run; number them by first appearance
        // so two runs (old and new code) can be compared byte for byte.
        final seen = <String, int>{};
        File(_dumpPath).writeAsStringSync(
          state('target').join('\n').replaceAllMapped(
            RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
            (m) => 'uuid${seen.putIfAbsent(m[0]!, () => seen.length)}',
          ),
        );
      }
    },
    skip: !_benchmark,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
