import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/financial_store.dart';
import '../../data/local/transaction_outbox_repository.dart';
import '../../data/user_cards_repository.dart' show TxnEntryKind, TxnInstrument;

/// Stable id of the manual "I paid this card bill" transaction.
String cardBillPaymentTxnId(String cardId, DateTime due) =>
    'payment-$cardId-${due.year}-${due.month.toString().padLeft(2, '0')}';

/// Stable client mutation id (a uuid, so the server accepts it) for [txnId]:
/// saving "paid" twice replays the same mutation instead of double-counting.
String cardBillPaymentMutationId(String txnId) =>
    const Uuid().v5(Namespace.url.value, 'pandapay:card-bill-payment:$txnId');

/// WP-C7 (V5): the payment goes through the transaction outbox like Quick Add,
/// so it is a provisional (pending) row that the complete-query prune keeps and
/// that reaches the server. Re-saving while queued is a no-op.
Future<void> enqueueCardBillPayment(
  TransactionOutboxRepository outbox, {
  required String txnId,
  required Money amount,
  required String cardId,
  required String cardName,
  String? last4,
}) async {
  final mutationId = cardBillPaymentMutationId(txnId);
  // Already queued (saved twice before it synced): keep the one queued copy.
  if ((await outbox.all()).any((e) => e.clientMutationId == mutationId)) return;
  await outbox.enqueue(
    userCardId: cardId,
    amount: amount,
    merchantName: 'Credit Card Bill Payment',
    note: 'Card payment for $cardName •••• ${last4 ?? ""}',
    entryKind: TxnEntryKind.transfer,
    instrument: TxnInstrument.creditCard,
    clientMutationId: mutationId,
  );
}

/// Undo of [enqueueCardBillPayment]: drops the queued copy, or the delivered
/// row (and any legacy local row) when it already synced.
void undoCardBillPayment(
  TransactionOutboxRepository outbox,
  FinancialStore store,
  String namespace,
  String txnId,
) {
  final mutationId = cardBillPaymentMutationId(txnId);
  if (!outbox.cancel(mutationId)) {
    final synced = outbox.syncedTransactionId(mutationId);
    if (synced != null) store.deleteTransaction(namespace, synced);
  }
  store.deleteTransaction(namespace, txnId);
}
