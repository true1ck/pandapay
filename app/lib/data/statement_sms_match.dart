import 'package:pandapay_domain/sms_v2.dart' as sms;
import 'package:pandapay_domain/sms_v2_ledger.dart' as stmt;

import 'import_models.dart';
import 'user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind, TxnInstrument;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _day(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// The digits that end an account label such as `SBI ••8648`.
String? _accountDigits(String? label) {
  if (label == null) return null;
  final m = RegExp(r'(\d{3,})\s*$').firstMatch(label);
  return m?.group(1);
}

sms.Direction? _direction(TxnEntryKind kind) => switch (kind) {
  TxnEntryKind.spend || TxnEntryKind.investment => sms.Direction.debit,
  TxnEntryKind.income || TxnEntryKind.refund => sms.Direction.credit,
  _ => null,
};

/// For each imported statement row that an SMS-derived transaction already
/// explains, why: the import review shows it as a probable duplicate and leaves
/// it out unless the person keeps both.
///
/// A statement row and an SMS about the same payment never agree on the merchant
/// text or the time (the bank prints a narration and a date, the SMS a merchant
/// and a minute), so the check the import used until now, exact merchant text
/// within ten minutes, could not see them and every such row would have been
/// added a second time. This matches by amount, direction, account and day
/// (`reconcileWithSms`): one saved transaction explains at most one row, the
/// closest days first. Only transactions that came from SMS count, and card,
/// wallet and cash transactions are left out because they are not on a bank
/// statement.
Map<int, String> rowsExplainedBySms(
  List<ParsedStatementLine> rows,
  List<TransactionEntry> saved,
) {
  final entries = <String, TransactionEntry>{};
  final candidates = <stmt.StatementCandidate>[];
  for (final entry in saved) {
    if (entry.source != 'sms' || entry.status != 'active') continue;
    if (entry.instrument == TxnInstrument.creditCard ||
        entry.instrument == TxnInstrument.wallet ||
        entry.instrument == TxnInstrument.cash ||
        entry.userCardId != null ||
        entry.cardLast4 != null) {
      continue;
    }
    if (entry.amount.paise <= 0) continue;
    entries[entry.id] = entry;
    candidates.add(
      stmt.StatementCandidate(
        id: entry.id,
        at: entry.occurredAt.toUtc(),
        amountsMinor: [entry.amount.paise],
        primaryAmountMinor: entry.amount.paise,
        direction: _direction(entry.entryKind),
        accountMask: entry.accountLast4,
      ),
    );
  }
  if (candidates.isEmpty || rows.isEmpty) return const {};

  final statementRows = [
    for (var i = 0; i < rows.length; i++)
      stmt.StatementRow(
        index: i,
        date: DateTime.utc(rows[i].date.year, rows[i].date.month, rows[i].date.day),
        amountMinor: rows[i].amount.paise,
        direction: rows[i].isCredit ? sms.Direction.credit : sms.Direction.debit,
        narration: rows[i].description,
        accountMask: _accountDigits(rows[i].sourceAccount),
        accountId: rows[i].sourceAccount ?? '',
      ),
  ];
  final result = stmt.reconcileWithSms(statementRows, candidates);
  final out = <int, String>{};
  for (final match in result.matches) {
    final candidate = match.candidate;
    if (candidate == null) continue;
    final entry = entries[candidate.id]!;
    final what = (entry.merchantName ?? '').trim().isEmpty
        ? 'a payment'
        : entry.merchantName!.trim();
    out[match.row.index] =
        'Probably already in your SMS history: $what on ${_day(entry.occurredAt.toLocal())}. '
        'Skip this row, or keep both if it is a different payment.';
  }
  return out;
}
