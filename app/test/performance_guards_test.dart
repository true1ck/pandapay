// Source-level guards for the rules in docs/PERFORMANCE_RULEBOOK.md.
//
// These exist because the same UI-thread problems came back after the
// 18 Oct and 1 Nov optimisation passes: a rewrite (SMS v2) re-introduced
// synchronous, quadratic work on the UI isolate and nothing failed. Each test
// here encodes one rule that was broken and measured on a physical phone.
//
// A line can opt out with a `perf-ok: <reason>` comment on the same line. The
// reason is the review conversation: write it for the next person.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart';

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _norm(String path) => path.replaceAll('\\', '/');

List<String> _offending(
  Iterable<File> files,
  bool Function(String line) matches,
) {
  final offenders = <String>[];
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//')) continue;
      if (line.contains('perf-ok:')) continue;
      if (matches(line)) offenders.add('${_norm(file.path)}:${i + 1}: $trimmed');
    }
  }
  return offenders;
}

void main() {
  group('rule 3: hot-path regular expressions are compiled once', () {
    // Per-message SMS code. `RegExp(` compiles on every call; the profile of a
    // cold start had regex compilation as its top self-time frame.
    final hotFiles = <File>[
      ..._dartFiles('lib/features/sms_v2/pipeline'),
      File('lib/features/sms_import/sms_text_hint.dart'),
      File('lib/features/sms_import/ios_shortcut_sms.dart'),
      File('lib/features/sms_v2/ui/review_clustering.dart'),
      File('lib/data/sms_gate_filter.dart'),
    ];

    test('use cachedRegExp(...) (lib/data/cached_regexp.dart), not RegExp(...)', () {
      final offenders = _offending(
        hotFiles,
        (line) => RegExp(r'(?<![\w.])RegExp\(').hasMatch(line),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'Per-message code must not compile a RegExp on every call. Use '
            'cachedRegExp(...) or a top-level/static final.\n'
            '${offenders.join('\n')}',
      );
    });
  });

  group('rule 2: a zero-duration yield is not a background thread', () {
    test('every Future.delayed(Duration.zero) in data/SMS code is justified', () {
      final files = [
        ..._dartFiles('lib/features/sms_v2'),
        ..._dartFiles('lib/data/local'),
        ..._dartFiles('lib/features/sms_import'),
      ];
      final offenders = _offending(
        files,
        (line) =>
            line.contains('Future<void>.delayed(Duration.zero)') ||
            line.contains('Future.delayed(Duration.zero)') ||
            line.contains('Future.delayed(\n') && line.contains('Duration.zero'),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'Future.delayed(Duration.zero) only lets other events run between '
            'chunks; the chunk itself still blocks the UI. Keep the chunk '
            'small and bounded, add `// perf-ok: <why bounded>`, or move the '
            'work to an isolate.\n${offenders.join('\n')}',
      );
    });
  });

  group('rule 4: no whole-history read inside per-row work', () {
    test('sync pull and history recheck read category decisions per event set', () {
      final offenders = _offending(
        [
          File('lib/features/sms_v2/sync/sync_pull.dart'),
          File('lib/features/sms_v2/migration/history_category_recheck.dart'),
        ],
        (line) => line.contains('categoryDecisions()'),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'categoryDecisions() with no eventIds decodes the whole ledger. '
            'Inside a loop it is quadratic (it pinned the UI thread at 100% '
            'for 30+ s). Pass eventIds, or hoist it and add `// perf-ok:`.\n'
            '${offenders.join('\n')}',
      );
    });
  });

  group('rule 5: id lookups are pinned to their index', () {
    // SQLite may choose an index that satisfies ORDER BY and scan the whole
    // table for an equality lookup. INDEXED BY makes that a hard error
    // instead of a silent full scan.
    const factSourceSql =
        'FROM v2_facts INDEXED BY idx_v2_facts_source WHERE namespace = ? '
        'AND source_key = ? ORDER BY observed_at, fact_id';
    const ledgerEventSql =
        'FROM v2_ledger INDEXED BY idx_v2_ledger_event WHERE namespace=? '
        'AND event_id=? ORDER BY entry_id';

    test('FactStore.forSource and LedgerStore.forEvent keep INDEXED BY', () {
      final facts = File(
        'lib/features/sms_v2/storage/fact_store.dart',
      ).readAsStringSync();
      final ledger = File(
        'lib/features/sms_v2/storage/ledger_store.dart',
      ).readAsStringSync();
      expect(facts, contains('INDEXED BY \$indexedBy'));
      expect(facts, contains("indexedBy: 'idx_v2_facts_source'"));
      expect(ledger, contains('INDEXED BY idx_v2_ledger_event'));
    });

    test('the pinned queries are index searches, not table scans', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      for (final sql in ['SELECT 1 $factSourceSql', 'SELECT 1 $ledgerEventSql']) {
        final plan = db
            .select(
              'EXPLAIN QUERY PLAN $sql',
              sql.contains('fact') ? ['n', 's'] : ['n', 'e'],
            )
            .map((r) => r['detail'] as String)
            .join(' | ');
        expect(plan, contains('SEARCH'), reason: plan);
        expect(plan, isNot(contains('SCAN')), reason: plan);
      }
    });
  });

  group('rule 1: nothing heavy on the UI thread without a budget', () {
    test('the SMS runtime keeps its stalled-intake guard', () {
      final runtime = File(
        'lib/features/sms_v2/pipeline/sms_v2_runtime.dart',
      ).readAsStringSync();
      expect(runtime, contains('previousBatch'));
    });
  });

  group('subscriptions are read from saved rows, never derived on the UI thread', () {
    // Deriving a subscription walks every fact and event (O(history)). It runs
    // where the ledger is written (SubscriptionProjection) and a screen reads the
    // few saved rows (subscriptionStatesProvider). A screen, tile or reminder
    // that calls the ledger derivation brings back the lag rule 1 and rule 4
    // were written for.
    test('no screen, provider or reminder calls the ledger derivation', () {
      final allowed = {
        'lib/features/sms_v2/ledger/adapters.dart',
        'lib/features/sms_v2/ledger/subscription_projection.dart',
      };
      final offenders = _offending(
        [..._dartFiles('lib')].where((f) => !allowed.contains(_norm(f.path))),
        (line) =>
            line.contains('subscriptionsFromLedger(') ||
            line.contains('subscriptionStatesFromLedger(') ||
            line.contains('subscriptionHistoryFromLedger(') ||
            line.contains('recurringReportFromLedger('),
      );
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('capture never derives subscriptions inside its transaction', () {
      // It only marks them dirty (cheap); a derivation there holds the write lock
      // for O(history) and a failure in it would roll the whole chunk back.
      final offenders = _offending(
        [..._dartFiles('lib/features/sms_v2/pipeline')],
        (line) => line.contains('SubscriptionProjection.rebuild('),
      );
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the screens that list subscriptions compile their patterns once', () {
      // They run for every series on every build; only top-level finals may
      // construct a RegExp.
      final offenders = _offending(
        [File('lib/features/insights/subscription_view.dart')],
        (line) =>
            RegExp(r'(?<![\w.])RegExp\(').hasMatch(line) &&
            !line.startsWith('final '),
      );
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the subscription history lookup is an index search, not a scan', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final plan = db
          .select(
            'EXPLAIN QUERY PLAN SELECT kind, at FROM v2_subscription_history '
            'INDEXED BY idx_v2_subscription_history_at '
            'WHERE namespace=? AND series_id=? ORDER BY at DESC, seq DESC',
            ['n', 's'],
          )
          .map((r) => r['detail'] as String)
          .join(' | ');
      expect(plan, contains('SEARCH'), reason: plan);
    });
  });
}
