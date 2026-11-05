import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/financial_store.dart';
import 'history_category_recheck.dart';
import 'legacy_replay.dart';

class HistoryUpdateReport {
  const HistoryUpdateReport({
    required this.migration,
    required this.categories,
  });
  final ReplayReport migration;
  final HistoryCategoryReport categories;
}

class HistoryUpdatePaused implements Exception {}

/// Explicit local history maintenance, shared by preview and apply.
class HistoryUpdate {
  HistoryUpdate({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.appVersion,
    required this.from,
    required this.to,
    required this.accountIsCurrent,
    this.categoryIdBySlug = const {},
    this.catalogue = const [],
    RuleEngine? engine,
  }) : engine = engine ?? RuleEngine();

  final FinancialStore financial;
  final String namespace, appVersion;
  final RuleBundle bundle;
  final DateTime from, to;
  final bool Function() accountIsCurrent;
  final Map<String, String> categoryIdBySlug;
  final List<CardProduct> catalogue;
  final RuleEngine engine;
  static final _active = Expando<Map<String, Future<HistoryUpdateReport>>>();

  Future<HistoryUpdateReport> preview() async {
    final clone = sqlite3.openInMemory();
    FinancialStore? copy;
    try {
      await financial.database.db.backup(clone, nPage: 64).drain<void>();
      copy = FinancialStore(AppDatabase.forTesting(clone));
      return await HistoryUpdate(
        financial: copy,
        namespace: namespace,
        bundle: bundle,
        appVersion: appVersion,
        from: from,
        to: to,
        accountIsCurrent: accountIsCurrent,
        categoryIdBySlug: categoryIdBySlug,
        catalogue: catalogue,
        engine: engine,
      ).apply();
    } finally {
      copy?.dispose();
      clone.dispose();
    }
  }

  Future<HistoryUpdateReport> apply({
    bool Function()? shouldContinue,
    void Function(HistoryCategoryReport)? onProgress,
  }) {
    final jobs = _active[financial.database.db] ??= {};
    final previous = jobs[namespace];
    late final Future<HistoryUpdateReport> current;
    current =
        (() async {
          if (previous != null) {
            try {
              await previous;
            } catch (_) {
              // A failed earlier request keeps its checkpoint for its own retry.
            }
          }
          void check() {
            if (!accountIsCurrent()) {
              throw StateError('History account changed');
            }
            if (shouldContinue?.call() == false) throw HistoryUpdatePaused();
          }

          check();
          final migration =
              await LegacyReplay(
                financial: financial,
                namespace: namespace,
                bundle: bundle,
                appVersion: appVersion,
                catalogue: catalogue,
                categoryIdBySlug: categoryIdBySlug,
                accountIsCurrent: accountIsCurrent,
                engine: engine,
              ).run(
                includeNewSources: true,
                from: from,
                to: to,
                chunkSize: 25,
                onChunk: (_) => check(),
              );
          check();
          final categories = await HistoryCategoryRecheck(
            financial: financial,
            namespace: namespace,
            bundle: bundle,
            from: from,
            to: to,
            accountIsCurrent: accountIsCurrent,
            categoryIdBySlug: categoryIdBySlug,
          ).run(shouldContinue: shouldContinue, onProgress: onProgress);
          return HistoryUpdateReport(
            migration: migration,
            categories: categories,
          );
        })().whenComplete(() {
          if (identical(jobs[namespace], current)) jobs.remove(namespace);
        });
    jobs[namespace] = current;
    return current;
  }
}
