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
List<TransactionEntry> _withoutOldPipelineCopies(List<TransactionEntry> rows) {
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

/// The message a key was made from: a second event anchored on the same message
/// is saved as `<message key>#<event prefix>` (see the server's sms_v2 storage).
String _baseKey(String key) {
  final at = key.indexOf('#');
  return at < 0 ? key : key.substring(0, at);
}

/// Hides the earlier read of a message that was read again.
///
/// Reading a message again can give it a new event id (the rules changed); the
/// server then holds both events, the first on the bare message key and the
/// later one on `<key>#<prefix>`, and the old event's row stays active. One
/// message is one payment, so when an active row and an active later-read row
/// share the message, the kind and the amount, the earlier read is hidden.
/// Never when the person tagged, noted, re-categorised or excluded it, and
/// never for different amounts or kinds (a purchase and its refund stay).
List<TransactionEntry> _withoutSupersededReads(List<TransactionEntry> rows) {
  final later = <String>{};
  for (final row in rows) {
    final key = row.sourceKey;
    if (row.status != 'active' || key == null || !key.contains('#')) continue;
    later.add('${_baseKey(key)}|${row.entryKind.wireValue}|${row.amount.paise}');
  }
  if (later.isEmpty) return rows;
  final kept = <TransactionEntry>[
    for (final row in rows)
      if (!(row.status == 'active' &&
          row.sourceKey != null &&
          !row.sourceKey!.contains('#') &&
          !_carriesPersonsWork(row) &&
          later.contains(
            '${row.sourceKey}|${row.entryKind.wireValue}|${row.amount.paise}',
          )))
        row,
  ];
  return kept.length == rows.length ? rows : kept;
}

/// Hides what is not a second payment: the old-pipeline copy of a message the
/// phone has read itself, and the earlier read of a message read again.
List<TransactionEntry> withoutLegacyTwins(List<TransactionEntry> rows) =>
    _withoutSupersededReads(_withoutOldPipelineCopies(rows));
