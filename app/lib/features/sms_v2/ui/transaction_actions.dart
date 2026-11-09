import 'dart:convert';
import '../storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../pipeline/trace.dart';
import '../storage/event_store.dart';
import '../providers/data_providers.dart';
import 'review_controller.dart';

/// Existing edit/delete surfaces use the same fact/event correction service.
class SmsTransactionActions {
  const SmsTransactionActions({required this.controller});
  final ReviewController controller;
  FinancialStore get financial => controller.financial;
  LocalReviewItem _item(TransactionEntry original) {
    if (original.pipelineVersion != 2 ||
        original.sourceKey == null ||
        original.eventId == null)
      throw ArgumentError('A stored SMS entry is required');
    return LocalReviewItem(
      id: 'transaction:${original.id}',
      kind: 'event',
      payload: {'sourceKey': original.sourceKey, 'eventId': original.eventId},
    );
  }

  void edit(
    TransactionEntry original, {
    required int amountMinor,
    required String merchant,
    required DateTime occurredAt,
    String? category,
    String? instrumentId,
    required EventType eventType,
    Rail? rail,
  }) {
    final db = financial.database.db;
    final item = _item(original);
    financial.batch(() {
      db.execute('SAVEPOINT sms_transaction_edit');
      try {
        void apply(CorrectionKind kind, Map<String, Object?> patch) =>
            controller.apply(items: [item], kind: kind, corrected: patch);
        if (amountMinor != original.amount.paise)
          apply(CorrectionKind.wrongAmount, {'amountMinor': amountMinor});
        if (merchant != (original.merchantName ?? ''))
          apply(CorrectionKind.wrongMerchant, {'merchantName': merchant});
        if (occurredAt.toUtc() != original.occurredAt.toUtc())
          apply(CorrectionKind.wrongDate, {
            'occurredAt': occurredAt.toUtc().toIso8601String(),
          });
        if (category != null)
          apply(CorrectionKind.wrongCategory, {'category': category});
        if (instrumentId != null)
          apply(CorrectionKind.wrongInstrument, {'instrumentId': instrumentId});
        // A card bill and a transfer between the person's accounts both show as
        // "Transfer", so for those the stored type decides whether anything
        // changed; for the rest the kind is compared, so a subscription stays a
        // subscription when the person only saves the same kind.
        final stored = EventStore(
          db,
          namespace: controller.namespace,
        ).get(original.eventId!)?.type;
        final transferFamily =
            eventType == EventType.ownTransfer ||
            eventType == EventType.cardBillPayment;
        final kindChanged = transferFamily && stored != null
            ? stored != eventType
            : eventType.wire != _eventType(original).wire;
        if (kindChanged || rail != null)
          apply(CorrectionKind.wrongKind, {
            'eventType': (kindChanged ? eventType : (stored ?? eventType)).wire,
            if (rail != null) 'rail': rail.wire,
          });
        db.execute('RELEASE sms_transaction_edit');
      } catch (_) {
        db.execute('ROLLBACK TO sms_transaction_edit');
        db.execute('RELEASE sms_transaction_edit');
        rethrow;
      }
    });
  }

  /// Sets one category on several stored SMS transactions in one local write.
  /// This is what bulk "Set category" uses: the server has no `v2:` ids.
  void setCategory(Iterable<TransactionEntry> entries, String category) =>
      controller.apply(
        items: [for (final e in entries) _item(e)],
        kind: CorrectionKind.wrongCategory,
        corrected: {'category': category},
      );

  /// The event type the ledger holds for [original], which tells a card bill
  /// from a transfer between the person's accounts (both display as "Transfer").
  EventType? storedType(TransactionEntry original) => original.eventId == null
      ? null
      : EventStore(
          financial.database.db,
          namespace: controller.namespace,
        ).get(original.eventId!)?.type;

  /// One-tap "this was a transfer between my accounts" or "this was a credit
  /// card bill": changes only the type, which takes it out of spending.
  void markAs(TransactionEntry original, EventType type) => controller.apply(
    items: [_item(original)],
    kind: CorrectionKind.wrongKind,
    corrected: {'eventType': type.wire},
  );

  void hide(TransactionEntry original) {
    final event = EventStore(
      financial.database.db,
      namespace: controller.namespace,
    ).get(original.eventId!);
    if (event == null) throw ArgumentError('The SMS event is unavailable');
    SyncStateStore(
      financial.database.db,
      namespace: controller.namespace,
    ).put('hidden-event:${event.eventId}', jsonEncode(event.toJson()));
    controller.apply(
      items: [_item(original)],
      kind: CorrectionKind.duplicate,
      confirm: true,
    );
  }

  void restore(TransactionEntry original) {
    final raw = SyncStateStore(
      financial.database.db,
      namespace: controller.namespace,
    ).get('hidden-event:${original.eventId}');
    if (raw == null)
      throw ArgumentError('This entry has no saved SMS reading to restore');
    final previous = Event.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
    controller.apply(
      items: [_item(original)],
      kind: CorrectionKind.wrongKind,
      corrected: {'eventType': previous.type.wire},
      confirm: true,
    );
  }

  static EventType _eventType(TransactionEntry row) => switch (row.entryKind) {
    TxnEntryKind.spend => EventType.purchase,
    TxnEntryKind.income => EventType.income,
    TxnEntryKind.investment => EventType.investment,
    TxnEntryKind.refund => EventType.refund,
    TxnEntryKind.transfer => EventType.ownTransfer,
    _ => EventType.unknown,
  };
}
