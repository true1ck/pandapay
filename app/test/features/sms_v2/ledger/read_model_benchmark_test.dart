// Measures one ledger read-model rebuild at the rulebook's reference size
// (5,000 transactions / 20,000 facts). Prints the numbers; asserts only what
// is deterministic (decode counts), because wall time depends on the machine.
//
//   flutter test test/features/sms_v2/ledger/read_model_benchmark_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/row_decode_cache.dart';

import '../support/ledger_dataset.dart';

LedgerReadModel cachedRead(Dataset d) => loadLedgerReadModel(
  db: d.database.db,
  financialStore: d.store,
  namespace: ns,
);

int _micros(void Function() work, {int runs = 5}) {
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    work();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  test('rebuild at 5,000 transactions / 20,000 facts', () {
    final d = Dataset(5000, extraFacts: 15000)..open();
    addTearDown(d.close);
    d.seed();

    // Before: every revision bump read everything from scratch (facts were
    // already reused through FactStore.all()).
    plainRead(d, cachedFacts: true); // warm the fact cache like production
    final before = _micros(() => plainRead(d, cachedFacts: true));

    // After: first read fills the cache, later reads parse nothing.
    RowDecodeCache.decodeCount = 0;
    final first = _micros(() => cachedRead(d), runs: 1);
    final firstDecodes = RowDecodeCache.decodeCount;
    RowDecodeCache.decodeCount = 0;
    final warm = _micros(() => cachedRead(d));
    final warmDecodes = RowDecodeCache.decodeCount;

    // The downstream gate: comparing a rebuilt model with the previous one.
    final previous = cachedRead(d);
    final next = cachedRead(d);
    final compare = _micros(() => previous.sameContentAs(next));

    // One edited transaction costs one decode.
    d.store.saveTransactions(ns, [d.transactionFor(42, note: 'edited')]);
    RowDecodeCache.decodeCount = 0;
    final oneEdit = _micros(() => cachedRead(d), runs: 1);
    final oneEditDecodes = RowDecodeCache.decodeCount;

    // What a rebuilt model used to make its consumers recompute (the memoised
    // snapshot, reports and review candidates start empty on a new instance).
    final loaded = cachedRead(d);
    final now = DateTime.utc(2026, 11, 7);
    final derived = _micros(() {
      final fresh = LedgerReadModel(
        ledger: loaded.ledger,
        transactions: loaded.transactions,
        facts: loaded.facts,
        instruments: loaded.instruments,
      );
      fresh.spendReport(const SpendReportQuery.preset(SpendPeriod.month), now);
      fresh.categorySpend(now);
      fresh.homeSummary(now);
      reviewCandidates(fresh, minimumOccurrences: 2, largeAmount: 200000);
    }, runs: 3);

    final db = d.database.db;
    final parts = <String, int>{
      'facts.all()': _micros(() => FactStore(db, namespace: ns).all()),
      'ledger.readAllCached()': _micros(
        () => LedgerStore(db, namespace: ns).readAllCached(),
      ),
      'events.listSince()': _micros(
        () => EventStore(db, namespace: ns).listSince(DateTime.utc(1900)),
      ),
      'instruments.list()': _micros(
        () => InstrumentStore(db, namespace: ns).list(),
      ),
      'financialStore.entities(transactions)': _micros(
        () => d.store.entities(ns, 'transactions'),
      ),
    };
    // ignore: avoid_print
    print(
      parts.entries
          .map((e) => '    ${e.key}: ${e.value / 1000} ms')
          .join(String.fromCharCode(10)),
    );
    // ignore: avoid_print
    print(
      'read model rebuild, ${d.n} transactions / ${d.n + d.extraFacts} facts '
      '/ ${d.n} events / ${d.n} ledger rows:\n'
      '  before (full read, facts cached): ${before ~/ 1000} ms, '
      'rows parsed per rebuild: ${d.n * 3 + 2} (+ ${d.n} facts cached)\n'
      '  after, first read:   ${first ~/ 1000} ms, rows parsed: $firstDecodes\n'
      '  after, unchanged:    ${warm ~/ 1000} ms, rows parsed: $warmDecodes\n'
      '  after, 1 tx edited:  ${oneEdit ~/ 1000} ms, rows parsed: $oneEditDecodes\n'
      '  unchanged-content check: ${compare / 1000} ms\n'
      '  derived work skipped per unchanged bump (month report, 12-month '
      'categories, home summary, review candidates): ${derived ~/ 1000} ms',
    );
    expect(firstDecodes, d.n * 3); // ledger + events + transactions (instruments were warmed by plainRead)
    expect(warmDecodes, 0);
    expect(oneEditDecodes, 1);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
