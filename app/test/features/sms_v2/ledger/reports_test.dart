import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2_ledger.dart';

TransactionEntry txn(String id, TxnEntryKind kind, int minor, {DateTime? at}) =>
    TransactionEntry(
      id: id,
      entryKind: kind,
      amount: Money.fromPaise(minor),
      occurredAt: at ?? DateTime(2026, 11, 5),
      merchantName: 'SWIGGY',
      categoryName: 'Dining',
      categoryId: 'cat-dining',
      source: 'manual',
      status: 'active',
    );
void main() {
  test(
    'spending keeps distinct masked bank accounts available for drilldown',
    () {
      final rows = [
        for (final (suffix, amount) in [('1234', 10000), ('5678', 20000)])
          TransactionEntry(
            id: suffix,
            accountLast4: suffix,
            instrument: TxnInstrument.upiBank,
            amount: Money.fromPaise(amount),
            occurredAt: DateTime(2026, 11, 5),
            merchantName: 'Swiggy',
            source: 'sms',
            status: 'active',
          ),
      ];
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: rows,
      );
      final report = model.spendReport(
        const SpendReportQuery.preset(SpendPeriod.month),
        DateTime(2026, 11, 15),
      );
      expect(
        {for (final row in report.byCard) row.cardName: row.total.paise},
        {'Bank account ••1234': 10000, 'Bank account ••5678': 20000},
      );
      expect(
        model.merchantKeyForTransaction(rows.first),
        report.byMerchant.single.label,
      );
    },
  );

  test('monthly comparison uses one point per month in a custom range', () {
    final model = LedgerReadModel(
      ledger: LedgerSnapshot(entries: [], events: []),
      transactions: [
        txn('sep', TxnEntryKind.spend, 10000, at: DateTime(2026, 9, 1)),
        txn('oct', TxnEntryKind.spend, 20000, at: DateTime(2026, 10, 31)),
      ],
    );
    final report = model.spendReport(
      SpendReportQuery.custom(
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 10, 31),
      ),
      DateTime(2026, 11, 1),
      monthlySeries: true,
    );
    expect(report.series.map((p) => p.periodStart.month), [9, 10]);
    expect(report.series.map((p) => p.spend.paise), [10000, 20000]);
  });

  for (final (period, now, previousStart, currentStart) in [
    (
      SpendPeriod.month,
      DateTime(2026, 11, 15),
      DateTime(2026, 10),
      DateTime(2026, 11),
    ),
    (
      SpendPeriod.month,
      DateTime(2026, 3, 15),
      DateTime(2026, 2),
      DateTime(2026, 3),
    ),
    (
      SpendPeriod.quarter,
      DateTime(2026, 2, 15),
      DateTime(2025, 10),
      DateTime(2026),
    ),
    (SpendPeriod.year, DateTime(2025, 7, 15), DateTime(2024), DateTime(2025)),
  ]) {
    test('previous ${period.name} uses calendar boundaries at $now', () {
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: [
          txn('first', TxnEntryKind.spend, 10000, at: previousStart),
          txn(
            'last',
            TxnEntryKind.refund,
            4000,
            at: currentStart.subtract(const Duration(milliseconds: 1)),
          ),
          txn(
            'before',
            TxnEntryKind.spend,
            2000,
            at: previousStart.subtract(const Duration(milliseconds: 1)),
          ),
          txn('current', TxnEntryKind.spend, 3000, at: currentStart),
        ],
      );
      final report = model.spendReport(SpendReportQuery.preset(period), now);
      expect(report.previousSpend.total.paise, 6000);
      expect(report.previousSpend.txnCount, 2);
    });
  }
  test(
    'all report breakdowns net refunds and exclude transfers and investments from spending',
    () {
      final rows = [
        txn('a', TxnEntryKind.spend, 10000),
        txn('b', TxnEntryKind.refund, 4000),
        txn('c', TxnEntryKind.investment, 50000),
        txn('d', TxnEntryKind.transfer, 100000),
      ];
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: rows,
      );
      final report = model.spendReport(
        const SpendReportQuery.preset(SpendPeriod.month),
        DateTime(2026, 11, 15),
      );
      expect(report.spend.total.paise, 6000);
      expect(report.investment.total.paise, 50000);
      expect(report.byCategory.single.total.paise, 6000);
      expect(report.byMerchant.single.total.paise, 6000);
      expect(report.byInstrument.single.total.paise, 6000);
      expect(report.byCard.single.total.paise, 6000);
      expect(model.totalsForTransactions(rows).transactionCount, 3);
      expect(model.totalsForTransactions(rows.take(1)).spendMinor, 10000);
    },
  );
}
