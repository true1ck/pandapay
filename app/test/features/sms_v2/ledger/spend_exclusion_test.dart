import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_projection.dart';
import 'package:pandapay/features/activity/spend_exclusion.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2_ledger.dart';

TransactionEntry row(
  String id,
  int paise, {
  TxnEntryKind kind = TxnEntryKind.spend,
  bool excluded = false,
  String status = 'active',
  Money? reward,
}) => TransactionEntry(
  id: id,
  entryKind: kind,
  amount: Money.fromPaise(paise),
  occurredAt: DateTime(2026, 11, 10, 12),
  merchantName: id,
  source: 'manual',
  status: status,
  excludeFromSpend: excluded,
  rewardValue: reward,
);

LedgerReadModel model(List<TransactionEntry> rows) => LedgerReadModel(
  ledger: LedgerSnapshot(entries: [], events: []),
  transactions: rows,
);

void main() {
  final now = DateTime(2026, 11, 20);

  group('TransactionEntry', () {
    test('only a spend row the person has not excluded counts as spending', () {
      expect(row('a', 100).countsAsSpend, isTrue);
      expect(row('a', 100, excluded: true).countsAsSpend, isFalse);
      expect(
        row('a', 100, kind: TxnEntryKind.investment).countsAsSpend,
        isFalse,
      );
    });

    test('the choice survives a JSON round trip and defaults to counted', () {
      final excluded = TransactionEntry.fromJson(
        row('a', 100, excluded: true).toJson(),
      );
      expect(excluded.excludeFromSpend, isTrue);
      final json = row('b', 100).toJson();
      expect(json.containsKey('exclude_from_spend'), isFalse);
      expect(TransactionEntry.fromJson(json).excludeFromSpend, isFalse);
    });

    test('copyWith changes only the choice', () {
      final changed = row('a', 100).copyWith(excludeFromSpend: true);
      expect(changed.excludeFromSpend, isTrue);
      expect(changed.status, 'active');
      expect(changed.entryKind, TxnEntryKind.spend);
    });

    test('only settled spending can be left out', () {
      expect(canExcludeFromSpend(row('a', 100)), isTrue);
      expect(canExcludeFromSpend(row('a', 100, status: 'ignored')), isFalse);
      expect(
        canExcludeFromSpend(row('a', 100, kind: TxnEntryKind.income)),
        isFalse,
      );
      expect(canExcludeFromSpend(row('local-outbox:1', 100)), isFalse);
    });
  });

  group('ledger read model', () {
    final rows = [
      row('counted', 10000, reward: Money.fromPaise(100)),
      row('left-out', 4000, excluded: true, reward: Money.fromPaise(40)),
      row('sip', 50000, kind: TxnEntryKind.investment),
    ];

    test('spending leaves the excluded row out; Money out does not', () {
      final m = model(rows);
      final t = m.totalsForTransactions(rows);
      expect(t.spendMinor, 10000);
      expect(t.excludedSpendMinor, 4000);
      expect(t.allSpendMinor, 14000);
      // Money out = what left the account: counted spend + excluded + SIP.
      expect(t.moneyOutMinor, 64000);
    });

    test('the spend report drops it from totals but keeps its rewards', () {
      final report = model(rows).spendReport(
        const SpendReportQuery.preset(SpendPeriod.month),
        now,
      );
      expect(report.spend.total.paise, 10000);
      expect(report.spend.txnCount, 1);
      expect(report.spend.rewards.paise, 140);
      expect(report.byMerchant.map((m) => m.label), isNot(contains('left-out')));
    });

    test('an unlinked legacy refund still comes off spending (no link to match)', () {
      final all = [
        ...rows,
        row('refund', 4000, kind: TxnEntryKind.refund),
      ];
      // Legacy rows carry no refund-to-purchase link, so nothing can be
      // matched here: the refund still comes off spending. This pins that
      // limit; linked SMS refunds are covered in the domain tests.
      final t = model(all).totalsForTransactions(all);
      expect(t.spendMinor, 6000);
    });

    test('flagging nothing changes nothing', () {
      final plain = [row('a', 10000), row('b', 4000)];
      final t = model(plain).totalsForTransactions(plain);
      expect(t.spendMinor, 14000);
      expect(t.excludedSpendMinor, 0);
      expect(t.moneyOutMinor, 14000);
    });
  });

  test('Activity Money out still includes spend left out of spending', () {
    final p = ActivityProjection.build([
      row('counted', 10000),
      row('left-out', 4000, excluded: true),
    ]);
    expect(p.totalOutgoing.paise, 14000);
  });
}
