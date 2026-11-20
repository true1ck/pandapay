import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import '../../activity/edit_transaction_screen.dart' show kDraftTransactionPrefix;
import '../providers/data_providers.dart';
import 'review_clustering.dart';

/// The transaction a review question describes, as far as the question knows
/// it, for the Edit transaction screen to open on. Nothing here is saved:
/// the person checks it, changes what is wrong and saves, or backs out.
///
/// It uses only what the question already holds: the amount, shop and day of a
/// bill receipt; the suggested reading ("debit ₹250.0 AMAZON"); otherwise the
/// amount printed in the message and the day it arrived. What it does not know
/// (how it was paid, the category) stays empty for the person to choose.
TransactionEntry reviewDraftEntry(LocalReviewItem item, {DateTime? now}) {
  final reading = _reading.firstMatch('${item.payload['reading'] ?? ''}');
  final minor =
      reviewItemAmountMinor(item) ?? _readingAmountMinor(reading) ?? 0;
  final shop =
      (item.payload['app'] ?? item.payload['biller']) as String? ??
      reading?.group(3);
  final credit =
      reading?.group(1) == 'credit' ||
      (reading == null &&
          item.message != null &&
          reviewContentOf(item) == ReviewContent.credit);
  return TransactionEntry(
    id: '$kDraftTransactionPrefix${item.id}',
    amount: Money.fromPaise(minor),
    occurredAt: reviewItemDate(item)?.toLocal() ?? now ?? DateTime.now(),
    merchantName: shop == null || shop.trim().isEmpty ? null : shop.trim(),
    instrumentKnown: false,
    entryKind: credit ? TxnEntryKind.income : TxnEntryKind.spend,
    source: 'manual',
    status: 'active',
  );
}

final _reading = RegExp(r'^(\w+)\s+₹([\d.]+)\s*(.*)$');

int? _readingAmountMinor(RegExpMatch? match) {
  final rupees = double.tryParse(match?.group(2) ?? '');
  return rupees == null || rupees <= 0 ? null : Money.fromRupees(rupees).paise;
}
