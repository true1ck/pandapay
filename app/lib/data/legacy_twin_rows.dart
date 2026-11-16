import 'user_cards_repository.dart' show TransactionEntry;

/// The key of the message a saved row was made from, whichever pipeline made it.
String? _messageKey(TransactionEntry row) {
  final own = row.sourceKey;
  if (own != null && own.isNotEmpty) return own;
  for (final seen in row.observations) {
    final key = seen.sourceKey;
    if (key != null && key.isNotEmpty) return key;
  }
  return null;
}

bool _carriesPersonsWork(TransactionEntry row) =>
    row.tags.isNotEmpty ||
    (row.note?.trim().isNotEmpty ?? false) ||
    row.userCategoryId != null ||
    row.excludeFromSpend;

/// Hides the old-pipeline copy of a message the phone has since read itself.
///
/// Before 5 Nov the server read each SMS and the phone pulled its transactions
/// (pipeline version 1). The phone now reads messages itself (version 2). A
/// phone that kept both ends up with two active rows for one message: one
/// named, one "Unknown merchant" with no received time, and every list and
/// total adds both. Nothing else merges them, because a version-1 row has no
/// reading on the phone to re-read.
///
/// A version-1 row is hidden only when ALL of these hold, so nothing a person
/// made and no money is ever dropped:
///  * it is active and came from an SMS;
///  * an active version-2 row exists for the same message and the same amount;
///  * the person has not tagged, noted, re-categorised or excluded it.
///
/// Rows are returned in their order, as the same instances.
List<TransactionEntry> withoutLegacyTwins(List<TransactionEntry> rows) {
  var anyLegacy = false;
  final modern = <String, Set<int>>{};
  for (final row in rows) {
    if (row.status != 'active') continue;
    if (row.pipelineVersion == 2) {
      final key = _messageKey(row);
      if (key != null) (modern[key] ??= <int>{}).add(row.amount.paise);
    } else {
      anyLegacy = true;
    }
  }
  if (!anyLegacy || modern.isEmpty) return rows;
  final kept = <TransactionEntry>[];
  for (final row in rows) {
    final isOldSmsCopy =
        row.pipelineVersion != 2 &&
        row.status == 'active' &&
        (row.source == 'sms' || row.source == 'sms_bulk');
    if (isOldSmsCopy && !_carriesPersonsWork(row)) {
      final key = _messageKey(row);
      if (key != null && (modern[key]?.contains(row.amount.paise) ?? false)) {
        continue;
      }
    }
    kept.add(row);
  }
  return kept.length == rows.length ? rows : kept;
}
