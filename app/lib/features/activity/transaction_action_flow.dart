import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart' as v2;

import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';
import '../sms_v2/ui/owner_identity_actions.dart';
import '../sms_v2/ui/review_controller.dart';
import '../sms_v2/ui/transaction_actions.dart';
import 'spend_exclusion.dart';
import 'transaction_action_history.dart';
import 'transaction_badge.dart';

/// Everything "Choose an action" can do to a payment except Delete (which has
/// its own confirmation and lives in Deleted transactions).
enum TxnAction {
  selfTransfer('Transfer between my accounts'),
  familyTransfer('Transfer to family'),
  cardBill('Credit card bill payment'),
  excludeSpend("Don't count in spending"),
  refund('Refund'),
  reversal('Reversal'),
  wrongTransaction('Report wrong transaction');

  const TxnAction(this.label);
  final String label;

  bool get isTransfer => this == selfTransfer || this == familyTransfer;

  /// The note reason the ignore path stores.
  String? get ignoreReason => switch (this) {
    refund => 'refund',
    reversal => 'reversal',
    wrongTransaction => 'wrong_transaction',
    _ => null,
  };
}

/// How far the person said an action should reach.
class ActionScope {
  const ActionScope({this.always = false, this.others = const []});

  /// Transfers only: the payee for good, earlier payments and future ones.
  final bool always;

  /// Other payments the person ticked on the scope page.
  final List<TransactionEntry> others;

  String get words => always
      ? 'This payee, past and future'
      : others.isEmpty
      ? 'Only this payment'
      : '${others.length + 1} payments';
}

String _merchantKey(String? name) {
  final n = (name ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  return n == 'UNKNOWN' ? '' : n;
}

/// Other payments to the same payee that [action] could also change. Nothing for
/// a transfer: that reaches the payee through its remembered identity instead.
List<TransactionEntry> actionCandidates(
  TransactionEntry source,
  TxnAction action,
  Iterable<TransactionEntry> all,
) {
  if (action.isTransfer) return const [];
  final key = _merchantKey(source.merchantName);
  if (key.isEmpty) return const [];
  bool fits(TransactionEntry e) => switch (action) {
    TxnAction.excludeSpend => canExcludeFromSpend(e) && !e.excludeFromSpend,
    TxnAction.cardBill =>
      e.pipelineVersion == 2 &&
          e.status == 'active' &&
          txnBadgeKind(e) != TxnBadgeKind.cardBill,
    _ => e.status == 'active' && txnBadgeKind(e) == null,
  };
  return [
    for (final e in all)
      if (e.id != source.id &&
          _merchantKey(e.merchantName) == key &&
          fits(e))
        e,
  ];
}

void _refresh(WidgetRef ref) {
  ref.invalidate(transactionsProvider);
  ref.invalidate(utilizationTransactionsProvider);
  ref.invalidate(homeSummaryProvider);
  ref.invalidate(spendReportProvider);
  ref.invalidate(categorySpendProvider);
  ref.invalidate(transactionActionHistoryProvider);
}

/// Hides [entry] as a refund / reversal / wrong transaction. The detail screen
/// stays open: nothing here navigates.
Future<void> ignoreEntry(
  WidgetRef ref,
  TransactionEntry entry,
  String reason,
) async {
  final namespace = ref.read(cacheNamespaceProvider);
  if (entry.pipelineVersion == 2) {
    final controller = await smsReviewController(ref);
    if (namespace != ref.read(cacheNamespaceProvider)) return;
    SmsTransactionActions(controller: controller).hide(entry);
    controller.financial.markInactive(namespace, entry.id, reason: reason);
    return;
  }
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) throw StateError('Account is unavailable.');
  final cache = await ref.read(responseCacheProvider.future);
  const localPrefix = 'local-outbox:';
  if (entry.id.startsWith(localPrefix)) {
    final outbox = await ref.read(outboxRepositoryProvider.future);
    outbox.cancel(entry.id.substring(localPrefix.length));
  } else {
    final commands = await ref.read(commandOutboxProvider.future);
    commands.enqueue(
      kind: OutboxCommand.ignoreTransaction,
      target: entry.id,
      payload: {'id': entry.id, 'reason': reason},
      cancels: const [OutboxCommand.restoreTransaction],
    );
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.invalidate(pendingOutboxCountProvider);
  }
  cache.financialStore.markInactive(namespace, entry.id, reason: reason);
}

/// The reverse of [ignoreEntry].
Future<void> restoreEntry(WidgetRef ref, TransactionEntry entry) async {
  final namespace = ref.read(cacheNamespaceProvider);
  if (entry.pipelineVersion == 2) {
    final controller = await smsReviewController(ref);
    if (namespace != ref.read(cacheNamespaceProvider)) return;
    SmsTransactionActions(controller: controller).restore(entry);
    controller.financial.markActive(namespace, entry.id);
    return;
  }
  final commands = await ref.read(commandOutboxProvider.future);
  commands.enqueue(
    kind: OutboxCommand.restoreTransaction,
    target: entry.id,
    payload: {'id': entry.id},
    cancels: const [OutboxCommand.ignoreTransaction],
  );
  ref.read(outboxFlushRequestProvider.notifier).state++;
  ref.invalidate(pendingOutboxCountProvider);
  final cache = await ref.read(responseCacheProvider.future);
  cache.financialStore.markActive(namespace, entry.id);
}

Map<String, Object?> _snap(TransactionEntry e) => e.toJson();

TransactionEntry _fromSnap(WidgetRef ref, Object? raw) {
  final saved = TransactionEntry.fromJson(
    (raw as Map).cast<String, dynamic>(),
  );
  // Prefer the row as it reads now (a re-read can change its event).
  final live = ref.read(transactionsProvider).valueOrNull ?? const [];
  for (final e in live) {
    if (e.id == saved.id) return e;
  }
  return saved;
}

/// Does [action] on [entry] and records it. Throws a [StateError] with words for
/// the person when it cannot be done. Returns the history record.
Future<TxnActionRecord> applyTxnAction(
  WidgetRef ref,
  TransactionEntry entry,
  TxnAction action,
  ActionScope scope,
) async {
  final targets = [entry, ...scope.others];
  final undo = <String, Object?>{};
  int changed = 0;

  switch (action) {
    case TxnAction.selfTransfer || TxnAction.familyTransfer:
      final mark = action == TxnAction.familyTransfer
          ? TransferMark.family
          : TransferMark.self;
      final before = txnBadgeKind(entry);
      final actions = OwnerIdentityActions(ref);
      final plan = await actions.plan(entry);
      if (plan.isShop) {
        throw StateError(
          'This looks like a shop, not a person or one of your accounts.',
        );
      }
      final s = scope.always ? MarkScope.always : MarkScope.once;
      if (s == MarkScope.once ? !plan.canMarkOnce : !plan.canRemember) {
        throw StateError(
          'This message does not show a name, UPI ID or account, so it '
          'cannot be marked this way. Use Edit and change the type to '
          'Transfer for this one.',
        );
      }
      final r = await actions.mark(entry, mark, s);
      if (r.outcome == MarkOutcome.nothingToRecognise) {
        throw StateError('This message does not show a name, UPI ID or account.');
      }
      changed = r.changed;
      undo.addAll({
        'kind': 'identity',
        'mark': mark.name,
        'scope': s.name,
        'prev': before == TxnBadgeKind.selfTransfer
            ? 'self'
            : before == TxnBadgeKind.familyTransfer
            ? 'family'
            : null,
        'entries': [_snap(entry)],
      });
    case TxnAction.cardBill:
      final controller = await smsReviewController(ref);
      final sms = SmsTransactionActions(controller: controller);
      final prev = <Map<String, Object?>>[];
      for (final t in targets.where((t) => t.pipelineVersion == 2)) {
        prev.add({'entry': _snap(t), 'type': sms.storedType(t)?.wire});
        sms.markAs(t, v2.EventType.cardBillPayment);
        changed++;
      }
      undo.addAll({'kind': 'type', 'prev': prev});
    case TxnAction.excludeSpend:
      changed = await setSpendExclusion(ref, targets, excluded: true);
      undo.addAll({
        'kind': 'exclude',
        'entries': [for (final t in targets) _snap(t)],
      });
    case TxnAction.refund ||
        TxnAction.reversal ||
        TxnAction.wrongTransaction:
      for (final t in targets) {
        await ignoreEntry(ref, t, action.ignoreReason!);
        changed++;
      }
      undo.addAll({
        'kind': 'ignore',
        'entries': [for (final t in targets) _snap(t)],
      });
  }
  _refresh(ref);

  final record = TxnActionRecord(
    id: TransactionActionHistory.newId(),
    at: DateTime.now(),
    action: action.name,
    title: (entry.merchantName ?? '').trim().isEmpty
        ? 'Payment'
        : entry.merchantName!.trim(),
    amountPaise: entry.amount.paise,
    scope: changed > 1 && !scope.always ? '$changed payments' : scope.words,
    targets: [for (final t in targets) t.id],
    undo: undo,
  );
  await _save(ref, record);
  return record;
}

Future<void> _save(WidgetRef ref, TxnActionRecord r) async {
  final cache = await ref.read(responseCacheProvider.future);
  TransactionActionHistory(
    cache.financialStore.database.db,
    namespace: ref.read(cacheNamespaceProvider),
  ).save(r);
}

/// Takes back everything [record] did, in one step, and marks it undone.
Future<void> undoTxnAction(WidgetRef ref, TxnActionRecord record) async {
  if (record.isUndone) return;
  final u = record.undo;
  switch (u['kind']) {
    case 'identity':
      final mark = u['mark'] == 'family'
          ? TransferMark.family
          : TransferMark.self;
      final scope = u['scope'] == 'always' ? MarkScope.always : MarkScope.once;
      final entry = _fromSnap(ref, (u['entries'] as List).first);
      final actions = OwnerIdentityActions(ref);
      await actions.undoMark(entry, mark, scope);
      final prev = u['prev'];
      if (prev != null) {
        await actions.mark(
          entry,
          prev == 'family' ? TransferMark.family : TransferMark.self,
          scope,
        );
      }
    case 'type':
      final controller = await smsReviewController(ref);
      final sms = SmsTransactionActions(controller: controller);
      for (final p in (u['prev'] as List).cast<Map>()) {
        final type = p['type'];
        if (type is! String) continue;
        sms.markAs(_fromSnap(ref, p['entry']), v2.EventType.fromWire(type));
      }
    case 'exclude':
      await setSpendExclusion(ref, [
        for (final e in u['entries'] as List) _fromSnap(ref, e),
      ], excluded: false);
    case 'ignore':
      // The saved snapshot, not the live row: a hidden row is not in the list.
      for (final e in u['entries'] as List) {
        await restoreEntry(
          ref,
          TransactionEntry.fromJson((e as Map).cast<String, dynamic>()),
        );
      }
  }
  _refresh(ref);
  await _save(ref, record.markUndone(DateTime.now()));
  _refresh(ref);
}
