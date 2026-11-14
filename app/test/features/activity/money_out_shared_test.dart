import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2_ledger.dart';

TransactionEntry _t(String id, TxnEntryKind k, int paise, {bool left = false}) =>
    TransactionEntry(
      id: id,
      entryKind: k,
      amount: Money.fromPaise(paise),
      occurredAt: DateTime(2026, 11, 5),
      merchantName: 'SYNTHETIC SHOP',
      source: 'manual',
      status: 'active',
      excludeFromSpend: left,
      excludeReason: left ? 'family' : null,
    );

void main() {
  test('Activity money out and the ledger totals Home reads agree', () {
    final rows = [
      _t('a', TxnEntryKind.spend, 10000),
      _t('b', TxnEntryKind.spend, 5000, left: true),
      _t('c', TxnEntryKind.investment, 3000),
      _t('d', TxnEntryKind.transfer, 2000),
      _t('e', TxnEntryKind.income, 7000),
    ];
    final totals = LedgerReadModel(
      ledger: LedgerSnapshot(entries: [], events: []),
      transactions: rows,
    ).totalsForTransactions(rows);
    final activity = rows
        .where((r) => r.countsAsMoneyOut)
        .fold<int>(0, (s, r) => s + r.amount.paise);
    expect(totals.moneyOutMinor, activity);
    expect(TransactionEntry.fromJson(rows[1].toJson()).excludeReason, 'family');
  });
}
