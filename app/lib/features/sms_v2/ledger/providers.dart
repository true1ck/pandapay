import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../storage/schema.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import 'reports.dart';

/// One immutable account snapshot for every ledger-backed reporting surface.
/// WP-14's stores notify the existing financial revision stream after batches.
final smsV2LedgerReadModelProvider = FutureProvider<LedgerReadModel>((
  ref,
) async {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  ref.watch(app.financialStoreRevisionProvider('transactions'));
  ref.watch(app.financialStoreRevisionProvider('observations'));
  ref.watch(app.financialStoreRevisionProvider('cards'));
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final ledger = LedgerStore(db, namespace: namespace);
  return LedgerReadModel(
    v2Ready:
        db.select('SELECT 1 FROM v2_facts WHERE namespace=? LIMIT 1', [
          namespace,
        ]).isNotEmpty ||
        db.select('SELECT 1 FROM v2_events WHERE namespace=? LIMIT 1', [
          namespace,
        ]).isNotEmpty,
    ledger: LedgerSnapshot(
      entries: ledger.list(),
      events: EventStore(
        db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900)),
      categoryByEvent: ledger.categoryDecisions(),
    ),
    facts: FactStore(db, namespace: namespace).all(),
    instruments: InstrumentStore(db, namespace: namespace).list(),
    transactions: cache.financialStore
        .entities(namespace, 'transactions')
        .map(TransactionEntry.fromJson)
        .toList(),
  );
});

/// During the upgrade there may be retained v1 history but no v2 data yet.
/// Keep its established read path until the first processed v2 facts/events.
/// This gate affects reports only; capture routing still uses the build flag.
final smsV2ReportingEnabledProvider = Provider<bool>((ref) {
  return ref.watch(smsV2LedgerReadModelProvider).valueOrNull?.v2Ready == true;
});
