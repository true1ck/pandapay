import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart' show Instrument;
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../../app/providers.dart' as app;
import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../../shared_expenses/runtime/shared_providers.dart'
    show splitOverlayProvider;
import '../../shared_expenses/runtime/split_share_entries.dart'
    show SplitOverlay, applySplitOverlay;
import '../storage/schema.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/row_decode_cache.dart';
import 'json_fingerprint.dart';
import 'reports.dart';
import 'suspected_refunds.dart';

/// Reads the account's whole ledger state into one [LedgerReadModel].
///
/// This runs on the UI isolate whenever a revision bumps, so it only parses
/// rows that are new or changed since the previous read (see
/// [RowDecodeCache]; facts are cached by [FactStore.all]). Unchanged rows come
/// back as the same instances, which is what lets [LedgerModelSource] tell
/// that nothing changed without a deep comparison.
LedgerReadModel loadLedgerReadModel({
  required Database db,
  required FinancialStore financialStore,
  required String namespace,
  SplitOverlay? splitOverlay,
  Map<String, (TransactionEntry, TransactionEntry)>? splitMemo,
}) {
  final applied = applySplitOverlay(
    _readTransactions(db, financialStore, namespace),
    splitOverlay,
    memo: splitMemo,
  );
  SmsV2Schema.ensure(db);
  final (entries, categoryByEvent) = LedgerStore(
    db,
    namespace: namespace,
  ).readAllCached();
  return LedgerReadModel(
    v2Ready:
        db.select('SELECT 1 FROM v2_facts WHERE namespace=? LIMIT 1', [
          namespace,
        ]).isNotEmpty ||
        db.select('SELECT 1 FROM v2_events WHERE namespace=? LIMIT 1', [
          namespace,
        ]).isNotEmpty,
    ledger: LedgerSnapshot(
      entries: entries,
      events: EventStore(
        db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900)),
      categoryByEvent: categoryByEvent,
    ),
    facts: FactStore(db, namespace: namespace).all(),
    instruments: InstrumentStore(db, namespace: namespace).list(),
    // What Splits changes in spending: shares of splits somebody else paid are
    // local-only rows that count like a manual entry, and a payment the person
    // split is left out in favour of their share (see split_share_entries.dart).
    transactions: [...applied.payments, ...applied.shares],
  );
}

/// `entities(...)` already returns each transaction as decoded JSON (with
/// pending local edits applied). Building a [TransactionEntry] from it parses
/// dates and nested lists, so reuse the entry of every row whose JSON is
/// unchanged (matched by [jsonFingerprint]).
List<TransactionEntry> _readTransactions(
  Database db,
  FinancialStore financialStore,
  String namespace,
) {
  final pass = RowDecodeCache.of<_DecodedTransaction>(
    db,
    'financial_transactions',
  ).begin(namespace);
  final out = <TransactionEntry>[
    for (final json in financialStore.entities(namespace, 'transactions'))
      pass
          .resolve(
            json['id'] as String,
            jsonFingerprint(json),
            (_) => _DecodedTransaction(TransactionEntry.fromJson(json)),
          )
          .entry,
  ];
  pass.finish();
  return out;
}

class _DecodedTransaction {
  const _DecodedTransaction(this.entry);
  final TransactionEntry entry;
}

/// Holds the latest [LedgerReadModel] and tells listeners only when its
/// content actually changed.
///
/// Revisions bump often (startup, every sync batch) and most bumps change
/// nothing in the ledger tables; rebuilding the model and every provider
/// derived from it on each bump is what kept the UI thread busy. Here a bump
/// marks the model stale, the re-read is coalesced to one per event-loop turn
/// no matter how many revisions bumped together, and listeners (the Riverpod
/// provider) are told only if the re-read produced different content;
/// otherwise the previous model instance, with all its memoised reports, is
/// kept.
class LedgerModelSource {
  LedgerModelSource(this._load);

  final LedgerReadModel Function() _load;
  LedgerReadModel? _current;
  bool _stale = true;
  bool _scheduled = false;
  bool _disposed = false;
  bool _notified = false;
  final _listeners = <void Function()>[];

  /// How many times the model was re-read (for tests and diagnostics).
  int reads = 0;

  /// The up-to-date model. Reads synchronously when stale, or when [force]d
  /// (the content check still keeps the previous instance if nothing changed).
  LedgerReadModel read({bool force = false}) {
    if (force || _stale || _current == null) _refresh();
    return _current!;
  }

  /// True once after listeners were told about a change: the caller that
  /// rebuilds in response needs no second read.
  bool takeNotified() {
    final value = _notified;
    _notified = false;
    return value;
  }

  /// Something that feeds the model changed.
  void markStale() {
    _stale = true;
    if (_scheduled || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(_flush);
  }

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }

  void _flush() {
    _scheduled = false;
    if (_disposed || !_stale) return;
    var changed = true;
    try {
      changed = _refresh();
    } catch (_) {
      // Let the provider rebuild and surface the failure itself.
      _stale = true;
    }
    if (changed) {
      _notified = true;
      for (final listener in List.of(_listeners)) {
        listener();
      }
    }
  }

  /// Returns true when the content differs from the previous model.
  bool _refresh() {
    reads++;
    final next = _load();
    _stale = false;
    final previous = _current;
    if (previous != null && previous.sameContentAs(next)) return false;
    _current = next;
    return true;
  }
}

final _ledgerModelSourceProvider = FutureProvider<LedgerModelSource>((
  ref,
) async {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  final splitMemo = <String, (TransactionEntry, TransactionEntry)>{};
  final source = LedgerModelSource(
    () => loadLedgerReadModel(
      db: db,
      financialStore: cache.financialStore,
      namespace: namespace,
      splitOverlay: ref.read(splitOverlayProvider).valueOrNull,
      splitMemo: splitMemo,
    ),
  );
  // A changed share re-reads the model once; unchanged shares keep their
  // instances, so the model compares equal and nothing downstream rebuilds.
  ref.listen(splitOverlayProvider, (_, _) => source.markStale());
  ref.onDispose(source.dispose);
  // The same three revisions the provider used to watch directly. Several
  // bumping in the same turn cost one re-read (see LedgerModelSource.markStale).
  for (final entity in const ['transactions', 'observations', 'cards']) {
    ref.listen(app.financialStoreRevisionProvider(entity), (_, _) {
      source.markStale();
    });
  }
  return source;
});

/// Shows a just-saved instrument choice everywhere (Home accounts, the found
/// list) at once, without re-reading the ledger.
/// Bumped after the user's confirm/reject/rename is saved on the phone.
final instrumentChoiceRevisionProvider = StateProvider<int>((ref) => 0);

/// The instruments straight from the local table (a handful of rows), so a
/// confirm shows up at once. It deliberately does NOT go through the ledger
/// model: swapping the model rebuilt every report (spend, insights, activity,
/// ~40 consumers) for a change that alters none of them, which was the lag.
final liveInstrumentsProvider = FutureProvider<List<Instrument>>((ref) async {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  ref.watch(instrumentChoiceRevisionProvider);
  // Also follow the full model, so server sync and new SMS still refresh this.
  ref.watch(smsV2LedgerReadModelProvider);
  return InstrumentStore(
    cache.financialStore.database.db,
    namespace: namespace,
  ).list();
});

/// One immutable account snapshot for every ledger-backed reporting surface.
/// WP-14's stores notify the existing financial revision stream after batches.
///
/// The provider's value changes (and the ~12 providers and screens derived
/// from it rebuild) only when the ledger content changes, not on every
/// revision bump. `ref.invalidate` still forces a fresh read.
final smsV2LedgerReadModelProvider = FutureProvider<LedgerReadModel>((
  ref,
) async {
  final source = await ref.watch(_ledgerModelSourceProvider.future);
  void changed() => ref.invalidateSelf();
  source.addListener(changed);
  ref.onDispose(() => source.removeListener(changed));
  // A rebuild we asked for already holds the fresh model; any other rebuild
  // (first build, ref.invalidate from a retry button) re-reads.
  return source.read(force: !source.takeNotified());
});

/// During the upgrade there may be retained v1 history but no v2 data yet.
/// Keep its established read path until the first processed v2 facts/events.
/// This gate affects reports only; capture routing still uses the build flag.
final smsV2ReportingEnabledProvider = Provider<bool>((ref) {
  return ref.watch(smsV2LedgerReadModelProvider).valueOrNull?.v2Ready == true;
});

/// Card spends the card's available limit says were probably refunded without
/// a message, keyed by the spend's event id. Empty until the ledger has loaded.
final suspectedRefundsProvider = Provider<Map<String, SuspectedRefundInfo>>((
  ref,
) {
  final model = ref.watch(smsV2LedgerReadModelProvider).valueOrNull;
  if (model == null) return const {};
  return suspectedRefundsFromModel(model);
});
