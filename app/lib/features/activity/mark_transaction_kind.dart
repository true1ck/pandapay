import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart' as v2;

import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';
import '../sms_v2/similar/similar_changes.dart';
import '../sms_v2/similar/similar_offer_sheet.dart';
import '../sms_v2/similar/similar_runner.dart';
import '../sms_v2/ui/review_controller.dart';
import '../sms_v2/ui/transaction_actions.dart';

/// The words for a type the person can mark a payment as.
String markedKindWords(v2.EventType type) => switch (type) {
  v2.EventType.cardBillPayment => 'a credit card bill payment',
  v2.EventType.ownTransfer => 'a transfer between your accounts',
  _ => 'another type',
};

/// Marks one transaction as a transfer between the person's accounts or a
/// credit card bill, which takes it out of spending, then asks which of the
/// other payments to the same payee should change too. Returns true when the
/// transaction was changed.
///
/// The question is a checklist that starts with nothing ticked (a type change
/// moves totals), and what is ticked runs in the background.
Future<bool> markTransactionKind({
  required BuildContext context,
  required ReviewController controller,
  required TransactionEntry entry,
  required v2.EventType type,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context);
  void refresh() {
    container.invalidate(transactionsProvider);
    container.invalidate(utilizationTransactionsProvider);
    container.invalidate(homeSummaryProvider);
    container.invalidate(spendReportProvider);
    container.invalidate(categorySpendProvider);
  }

  final similar = SimilarChanges.forController(controller);
  final before = similar.snapshot(entry);
  SmsTransactionActions(controller: controller).markAs(entry, type);
  refresh();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Marked as ${markedKindWords(type)}. Saved on this phone.'),
      ),
    );

  List<SimilarOffer> offers = const [];
  try {
    offers = before == null ? const [] : similar.offers(before, eventType: type);
  } catch (_) {
    // The change is saved; looking for others never puts it at risk.
  }
  for (final offer in offers) {
    if (!context.mounted) break;
    final ids = await showSimilarOfferSheet(
      context: context,
      offer: offer,
      changes: similar,
      shop: before?.printedName ?? entry.merchantName ?? 'this payee',
      target: markedKindWords(type),
    );
    if (ids == null || ids.isEmpty) continue;
    await applySimilarInBackground(
      messenger: messenger,
      changes: similar,
      offer: offer,
      eventIds: ids,
      onChanged: refresh,
    );
  }
  return true;
}
