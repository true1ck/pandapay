import '../../../data/spend_reports_repository.dart'
    show SpendReport, SpendReportQuery;
import '../../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import '../../sms_v2/ledger/reports.dart' show LedgerReadModel;

/// What the spend answers read. In the app it is the on-phone ledger, the
/// same one the Spending screen reads; in tests it is a fixture.
abstract class SpendDataSource {
  /// The ledger is built and can be trusted.
  bool get ready;
  DateTime get now;

  /// The first active transaction on the phone, or null if there is none.
  DateTime? get earliest;

  /// The report for the inclusive local days [from] to [to].
  SpendReport report(DateTime from, DateTime to);

  /// Individual transactions, for questions with several filters.
  Iterable<TransactionEntry> get transactions;
}

class LedgerSpendSource implements SpendDataSource {
  LedgerSpendSource(this.model, this.now);

  final LedgerReadModel model;

  @override
  final DateTime now;
  DateTime? _earliest;
  bool _earliestKnown = false;

  @override
  bool get ready => model.v2Ready;

  @override
  DateTime? get earliest {
    if (_earliestKnown) return _earliest;
    _earliestKnown = true;
    DateTime? first;
    for (final t in model.transactions) {
      if (t.status != 'active') continue;
      if (t.entryKind == TxnEntryKind.unknown) continue;
      final at = t.occurredAt.toLocal();
      if (first == null || at.isBefore(first)) first = at;
    }
    return _earliest = first == null
        ? null
        : DateTime(first.year, first.month, first.day);
  }

  @override
  SpendReport report(DateTime from, DateTime to) => model.spendReport(
    SpendReportQuery.custom(from: from, to: to),
    now,
  );

  @override
  Iterable<TransactionEntry> get transactions => model.transactions;
}
