import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../../activity/transaction_action_flow.dart';
import '../ledger/providers.dart';
import '../storage/dismissal_store.dart';
import '../storage/event_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../providers/data_providers.dart';
import 'review_history_views.dart';

/// Where a recovered message went.
enum RecoveredTo { autoResolved, needsReview }

/// "Dismiss" on a transaction card of AI auto-resolved: this is not a real
/// transaction. The record is saved first and then [hide] takes the transaction
/// out of the totals; if hiding fails the record is taken back, so History never
/// lists something that is still counted. In the app [hide] is the existing
/// "Report wrong transaction" action ([ignoreEntry] with `wrong_transaction`),
/// which can be restored.
Future<void> dismissTransaction({
  required DismissalStore store,
  required TransactionEntry entry,
  required DateTime at,
  required Future<void> Function() hide,
}) async {
  final source = entry.sourceKey;
  if (source == null) {
    throw ArgumentError('This transaction has no message to dismiss');
  }
  final before = store.get(source);
  store.put(
    AutoDismissal(
      sourceKey: source,
      kind: AutoDismissal.kindTransaction,
      dismissedAt: at,
      entryId: entry.id,
      eventId: entry.eventId,
    ),
  );
  try {
    await hide();
  } catch (_) {
    if (before == null) {
      store.remove(source);
    } else {
      store.put(before);
    }
    rethrow;
  }
}

/// "Dismiss" on a message the AI read that made no transaction: it leaves AI
/// auto-resolved and is listed in History. Nothing in the totals changes.
void dismissRead({
  required DismissalStore store,
  required String sourceKey,
  required DateTime at,
}) => store.put(
  AutoDismissal(
    sourceKey: sourceKey,
    kind: AutoDismissal.kindRead,
    dismissedAt: at,
  ),
);

/// "Recover" on a History row that was dismissed from AI auto-resolved. The
/// message goes back where it came from and is applied again:
///  * a transaction is restored from the hide ([restore], the existing restore
///    of "Report wrong transaction"), and the time its event was stamped is kept
///    so it counts as AI auto-resolved again, not as edited by the person;
///  * a message with no transaction just loses its dismissal.
/// When the AI rule no longer reads the message ([aiStillReads] false: it was
/// rejected, withdrawn or replaced) or the restore cannot be done, the message
/// goes to Needs review instead ([sendToReview]) and the record is dropped.
Future<RecoveredTo> recoverDismissed({
  required DismissalStore store,
  required AutoDismissal record,
  required bool aiStillReads,
  required Future<void> Function() restore,
  required String? Function() decidedAt,
  required Future<void> Function() sendToReview,
}) async {
  Future<RecoveredTo> toReview() async {
    await sendToReview();
    store.remove(record.sourceKey);
    return RecoveredTo.needsReview;
  }

  if (!aiStillReads) return toReview();
  if (record.isTransaction) {
    try {
      await restore();
    } catch (_) {
      return toReview();
    }
    final decided = decidedAt();
    if (decided == null) {
      store.remove(record.sourceKey);
    } else {
      store.put(record.asRestored(decided));
    }
    return RecoveredTo.autoResolved;
  }
  store.remove(record.sourceKey);
  return RecoveredTo.autoResolved;
}

Future<DismissalStore> _store(WidgetRef ref) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  return DismissalStore(SyncStateStore(db, namespace: namespace));
}

Future<void> _refresh(WidgetRef ref) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  cache.financialStore.notifyExternalChanges(namespace, const ['needs_review']);
  ref.invalidate(settledListsProvider);
  ref.invalidate(reviewItemsProvider);
  refreshTransactionViews(ref);
}

/// The Dismiss button of a transaction card.
Future<void> dismissTransactionFromCard(
  WidgetRef ref,
  TransactionEntry entry,
) async {
  await dismissTransaction(
    store: await _store(ref),
    entry: entry,
    at: DateTime.now(),
    hide: () => ignoreEntry(ref, entry, 'wrong_transaction'),
  );
  await _refresh(ref);
}

/// The Dismiss button of a message card.
Future<void> dismissReadFromCard(WidgetRef ref, String sourceKey) async {
  dismissRead(
    store: await _store(ref),
    sourceKey: sourceKey,
    at: DateTime.now(),
  );
  await _refresh(ref);
}

/// The Recover button of a History row dismissed from AI auto-resolved.
Future<RecoveredTo> recoverFromHistory(
  WidgetRef ref,
  DismissedAutoItem item,
) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  final model = await ref.read(smsV2LedgerReadModelProvider.future);
  final aiStillReads = (model.factsBySource[item.sourceKey] ?? const <Fact>[])
      .any(
        (f) =>
            f.provenance.engine != Engine.user &&
            f.provenance.ruleId.startsWith('AI-'),
      );
  final entry = item.entry;
  final to = await recoverDismissed(
    store: await _store(ref),
    record: item.record,
    aiStillReads: aiStillReads,
    restore: () async {
      if (entry == null) throw StateError('The transaction is gone');
      await restoreEntry(ref, entry);
    },
    decidedAt: () {
      final eventId = item.record.eventId;
      if (eventId == null) return null;
      return EventStore(
        db,
        namespace: namespace,
      ).get(eventId)?.decidedAt?.toUtc().toIso8601String();
    },
    sendToReview: () => reopenReadForReview(ref, item.sourceKey),
  );
  await _refresh(ref);
  return to;
}
