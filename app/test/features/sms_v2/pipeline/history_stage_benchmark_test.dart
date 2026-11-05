// Lane P benchmark: a synthetic multi-template history through the real phone
// pipeline. Skipped by default. Run on demand:
//
//   cd app && flutter test --no-pub --concurrency=1 \
//     --dart-define=SMS_V2_BENCHMARK=true [--dart-define=SMS_V2_BENCHMARK_COUNT=20000] \
//     test/features/sms_v2/pipeline/history_stage_benchmark_test.dart
//
// The live-latency test below always runs (it uses a small history).
@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';
import 'package:pandapay/features/sms_v2/pipeline/intake_gate.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';
import '../support/synthetic_corpus.dart';

const _benchmark = bool.fromEnvironment('SMS_V2_BENCHMARK');
const _count = int.fromEnvironment(
  'SMS_V2_BENCHMARK_COUNT',
  defaultValue: 20000,
);
const _namespace = 'user:lane-p';
const _chunk = 200;

SmsV2Runtime _runtime(
  FinancialStore financial,
  RuleBundle bundle,
  DateTime Function() clock,
) {
  final encoded = jsonEncode(bundle.toJson());
  return SmsV2Runtime(
    financial: financial,
    namespace: _namespace,
    client: MockClient((_) async => throw StateError('Offline benchmark')),
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'bench',
    appVersion: '2',
    headers: () async => {},
    verify: (value) async => value == encoded ? bundle : null,
    loadShippedBundle: () async => encoded,
    accountIsCurrent: () => true,
    clock: clock,
  );
}

int _percentile(List<int> sorted, double p) =>
    sorted[((sorted.length - 1) * p).round()];

String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

void main() {
  final bundle = testRuleBundle();

  test(
    'history import: $_count synthetic messages, stage by stage',
    () async {
      final corpus = SyntheticCorpus.generate(bundle, count: _count);
      final messages = corpus.messages;
      expect(messages.map((m) => '${m.sender}|${m.body}').toSet().length,
          messages.length,
          reason: 'every synthetic body is distinct');
      final report = StringBuffer()
        ..writeln('SMS v2 history benchmark (Lane P)')
        ..writeln('messages: ${messages.length} ${corpus.byOrigin}');

      // ---- Full real runtime (file-backed SQLite, as on a phone) ----
      final dir = Directory.systemTemp.createTempSync('sms_v2_bench');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = '${dir.path}/bench.sqlite';
      final database = AppDatabase.openFile(file);
      final financial = FinancialStore(database);
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      final runtime = _runtime(financial, bundle, () => DateTime.utc(2026, 11, 30));
      await runtime.capture(const [], backfill: true); // load the bundle
      final rssBefore = ProcessInfo.currentRss;
      var rssPeak = rssBefore;
      final chunkMs = <int>[];
      final total = Stopwatch()..start();
      for (var start = 0; start < messages.length; start += _chunk) {
        final slice = messages.sublist(
          start,
          (start + _chunk).clamp(0, messages.length),
        );
        final watch = Stopwatch()..start();
        await runtime.capture(slice, backfill: true);
        chunkMs.add(watch.elapsedMilliseconds);
        final rss = ProcessInfo.currentRss;
        if (rss > rssPeak) rssPeak = rss;
      }
      total.stop();
      final sorted = [...chunkMs]..sort();
      final head = chunkMs.take(10).reduce((a, b) => a + b) / 10;
      final tail = chunkMs.skip(chunkMs.length - 10).reduce((a, b) => a + b) / 10;
      report
        ..writeln('FULL RUNTIME (capture -> interpret -> instruments -> link -> ledger -> SQLite)')
        ..writeln('  total wall: ${total.elapsedMilliseconds} ms')
        ..writeln('  chunks: ${chunkMs.length} x $_chunk messages '
            '(pipeline processBatch limit 500)')
        ..writeln('  chunk ms min/median/p95/max: ${sorted.first}/'
            '${_percentile(sorted, .5)}/${_percentile(sorted, .95)}/${sorted.last}')
        ..writeln('  first-10 chunk avg ${head.toStringAsFixed(0)} ms, '
            'last-10 chunk avg ${tail.toStringAsFixed(0)} ms '
            '(ratio ${(tail / head).toStringAsFixed(2)}; ~1 means linear)')
        ..writeln('  RSS before ${_mb(rssBefore)} MB, sampled peak '
            '${_mb(rssPeak)} MB (delta ${_mb(rssPeak - rssBefore)} MB), '
            'process maxRss ${_mb(ProcessInfo.maxRss)} MB');
      database.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      var size = 0;
      for (final f in dir.listSync().whereType<File>()) {
        size += f.lengthSync();
      }
      report.writeln('  database size: ${_mb(size)} MB');
      try {
        final rows = database.db.select(
          'SELECT name, SUM(pgsize) AS bytes, COUNT(*) AS pages FROM dbstat '
          'GROUP BY name ORDER BY bytes DESC LIMIT 8',
        );
        report.writeln(
          '  largest tables/indexes: '
          '${rows.map((r) => '${r['name']}=${_mb(r['bytes'] as int)}MB').join(', ')}',
        );
      } on SqliteException {
        report.writeln('  (dbstat unavailable)');
      }
      int count(String table) => database.db
          .select('SELECT COUNT(*) AS n FROM $table WHERE namespace=?', [_namespace])
          .single['n'] as int;
      report.writeln(
        '  rows: facts ${count('v2_facts')}, events ${count('v2_events')}, '
        'ledger ${count('v2_ledger')}, outbox ${count('v2_outbox')}, '
        'review ${count('v2_review_items')}, instruments ${count('v2_instruments')}',
      );
      final decisions = database.db.select(
        "SELECT decision, COUNT(*) AS n FROM sms_source_decisions WHERE namespace=? GROUP BY decision",
        [_namespace],
      );
      report.writeln(
        '  source decisions: '
        '${decisions.map((r) => '${r['decision']}=${r['n']}').join(', ')}',
      );

      // ---- Live latency against the full history ----
      final live = await _liveLatency(financial, runtime);
      report.writeln('LIVE MESSAGE on the $_count-message store: '
          '$live ms from capture to visible in totals');

      // ---- Isolated stages (in memory, pure Dart, same chunking) ----
      final stages = _isolatedStages(bundle, messages);
      report.writeln('ISOLATED STAGES (same corpus, in-memory, no SQLite)');
      stages.forEach((name, ms) => report.writeln('  $name: $ms ms'));
      final accounted = stages.values.fold<int>(0, (a, b) => a + b);
      report.writeln(
        '  SQLite writes + context reads + glue (residual of full run): '
        '${total.elapsedMilliseconds - accounted} ms',
      );
      // ignore: avoid_print
      print(report);
      File('${Directory.systemTemp.path}/sms_v2_lane_p_benchmark.txt')
          .writeAsStringSync(report.toString());
      expect(total.elapsed, lessThan(const Duration(minutes: 2)));
      expect(live, lessThan(1000));
    },
    skip: !_benchmark,
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test('a live message is visible in totals within one second', () async {
    final database = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(database);
    addTearDown(() {
      financial.dispose();
      database.db.dispose();
    });
    final runtime = _runtime(financial, bundle, () => DateTime.utc(2026, 11, 30));
    final corpus = SyntheticCorpus.generate(bundle, count: 1500, seed: 3);
    await runtime.capture(corpus.messages, backfill: true);
    // The first live message after a restart, then a second one.
    expect(await _liveLatency(financial, runtime), lessThan(1000));
    expect(await _liveLatency(financial, runtime, amount: 4321), lessThan(1000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// One new card purchase arrives now; time until the ledger totals include it.
Future<int> _liveLatency(FinancialStore financial, SmsV2Runtime runtime, {int amount = 1234}) async {
  final db = financial.database.db;
  final ledger = LedgerStore(db, namespace: _namespace);
  final events = EventStore(db, namespace: _namespace);
  final from = DateTime.utc(2026, 11, 1);
  final to = DateTime.utc(2026, 12, 1);
  Totals totals() => LedgerSnapshot(
    entries: ledger.list(from: from, to: to),
    events: events.listSince(from),
    categoryByEvent: ledger.categoryDecisions(),
  ).totals(from, to);
  // The legacy one-time repair runs on the first entities() read, which the
  // app performs at startup. Do it here so only the new message is timed.
  financial.entities(_namespace, 'cards');
  final before = totals();
  final totalsWatch = Stopwatch()..start();
  totals();
  final totalsMs = totalsWatch.elapsedMilliseconds;
  final watch = Stopwatch()..start();
  await runtime.capture([
    QueuedSms(
      sender: 'VM-HDFCBK-S',
      body:
          'Rs.$amount.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-29:12:30:11. Avl Lmt: Rs.45,000.00',
      receivedAt: DateTime.utc(2026, 11, 29, 12, 31),
    ),
  ], backfill: false);
  final captureMs = watch.elapsedMilliseconds;
  final after = totals();
  watch.stop();
  // ignore: avoid_print
  print('live message: capture $captureMs ms, totals read $totalsMs ms');
  expect(after.spendMinor - before.spendMinor, amount * 100);
  return watch.elapsedMilliseconds;
}

Map<String, int> _isolatedStages(RuleBundle bundle, List<QueuedSms> messages) {
  final out = <String, int>{};
  // Intake: safety gate, triage and source key (the cheap part of capture).
  var watch = Stopwatch()..start();
  final candidates = <SmsMessage>[];
  for (final message in messages) {
    final triage = classifySmsV2Intake(message.sender, message.body);
    if (triage.kind == SmsTriageKind.sensitive ||
        triage.kind == SmsTriageKind.unrelated ||
        triage.kind == SmsTriageKind.promotion) {
      continue;
    }
    candidates.add(
      SmsMessage(
        sender: message.sender,
        body: message.body,
        observedAt: message.receivedAt.toUtc(),
        sourceKey: smsSourceKey(_namespace, message.sender, message.body),
        iosFilter: normalizeSenderBrand(message.sender).iosFilter,
      ),
    );
  }
  out['capture triage + source keys (${candidates.length} candidates)'] =
      watch.elapsedMilliseconds;

  watch = Stopwatch()..start();
  final engine = RuleEngine();
  final matchedByChunk = <List<Fact>>[];
  for (var start = 0; start < candidates.length; start += _chunk) {
    final facts = <Fact>[];
    for (final message in candidates.sublist(
      start,
      (start + _chunk).clamp(0, candidates.length),
    )) {
      final result = engine
          .interpretDetailed(message, bundle, appVersion: '2')
          .result;
      if (result.outcome == InterpretOutcome.matched) facts.addAll(result.facts);
    }
    matchedByChunk.add(facts);
  }
  out['interpret (rule engine)'] = watch.elapsedMilliseconds;

  watch = Stopwatch()..start();
  final resolver = DefaultInstrumentResolver.fromBundle(bundle);
  final instruments = <String, Instrument>{};
  final instrumentIds = <String, String>{};
  for (final facts in matchedByChunk) {
    for (final fact in facts) {
      final mention = fact.instrument;
      if (mention == null) continue;
      final outcome = resolver.resolveDetailed(
        mention,
        instruments.values,
        profileId: 'lane-p',
        observedAt: fact.observedAt,
      );
      if (outcome is InstrumentResolved) {
        final base = outcome.resolution.instrument;
        final update = applyFact(base, fact);
        instruments[base.instrumentId] = update.instrument;
        instrumentIds[fact.factId] = base.instrumentId;
      }
    }
  }
  out['instrument resolution'] = watch.elapsedMilliseconds;

  watch = Stopwatch()..start();
  final allFacts = <Fact>[];
  final events = <String, Event>{};
  var linkMs = 0, ledgerMs = 0;
  for (final incoming in matchedByChunk) {
    if (incoming.isEmpty) continue;
    final linkWatch = Stopwatch()..start();
    final from = incoming.first.observedAt.subtract(const Duration(days: 120));
    final recent = allFacts.where((f) => !f.observedAt.isBefore(from)).toList();
    final recentIds = {for (final f in recent) f.factId};
    final known = events.values
        .where((e) => e.legs.any((l) => recentIds.contains(l.factId)))
        .toList();
    allFacts.addAll(incoming);
    final result = RuleDrivenLinker.fromBundle(
      bundle,
      clock: () => incoming.last.observedAt,
    ).link(
      incoming: incoming,
      context: RuleLinkContext(
        recentFacts: recent,
        openEvents: known.where((e) => e.status == EventStatus.awaitingLeg).toList(),
        knownEvents: known,
        instrumentsById: instruments,
        instrumentIdByFactId: instrumentIds,
      ),
      rules: bundle.linkRules,
    );
    final affected = [...result.created, ...result.updated];
    for (final event in affected) {
      events[event.eventId] = event;
    }
    linkMs += linkWatch.elapsedMilliseconds;
    final ledgerWatch = Stopwatch()..start();
    LedgerSnapshot.project(
      events: affected,
      factsById: {for (final f in allFacts) f.factId: f},
      instrumentsById: instruments,
      bundle: bundle,
      instrumentIdByFactId: instrumentIds,
    );
    ledgerMs += ledgerWatch.elapsedMilliseconds;
  }
  watch.stop();
  out['linker (with in-memory context assembly)'] = linkMs;
  out['ledger + category projection'] = ledgerMs;
  return out;
}
