import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/card_cycle_days.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;

// Synthetic cycles only: the repository is public.
CardBill bill(int month, int stmtDay, int dueDay, {bool printed = false}) =>
    CardBill(
      statementDate: DateTime(2026, month, stmtDay),
      statementDateExplicit: printed,
      statementDateVerified: printed,
      dueDate: DateTime(2026, month, dueDay),
      amountDue: Money.fromPaise(100000),
      minimumDue: null,
      paidToward: const Money.zero(),
      lastPaymentAt: null,
      confidence: 0.9,
    );

UserCard card({int? stmt, int? due, String? stmtSrc, String? dueSrc}) =>
    UserCard(
      id: 'c1',
      cardProductId: 'p',
      cardName: 'Test Card',
      isDefault: false,
      statementDay: stmt,
      statementDaySource: stmtSrc,
      dueDay: due,
      dueDaySource: dueSrc,
    );

CardBillLedger ledger(List<CardBill> newestFirst) =>
    CardBillLedger(current: newestFirst.first, history: newestFirst);

void main() {
  group('learnCardDays', () {
    test('three months with the same story give both days', () {
      final l = learnCardDays([
        bill(11, 18, 5),
        bill(10, 18, 5),
        bill(9, 18, 5),
      ]);
      expect(l.statementDay, 18);
      expect(l.dueDay, 5);
    });

    test('a due date that slides a day still agrees', () {
      final l = learnCardDays([
        bill(11, 18, 6),
        bill(10, 18, 5),
        bill(9, 18, 5),
      ]);
      expect(l.dueDay, 5);
    });

    test('one unprinted cycle claims nothing', () {
      final l = learnCardDays([bill(11, 18, 5)]);
      expect(l.isEmpty, isTrue);
    });

    test('a printed statement date is enough on its own', () {
      final l = learnCardDays([bill(11, 18, 5, printed: true)]);
      expect(l.statementDay, 18);
      expect(l.dueDay, 5);
    });

    test('cycles that never agree give no due day', () {
      final l = learnCardDays([
        bill(11, 3, 9),
        bill(10, 12, 20),
        bill(9, 25, 28),
      ]);
      expect(l.isEmpty, isTrue);
    });
  });

  group('cardDayPatches', () {
    final days = ledger([bill(11, 18, 5), bill(10, 18, 5)]);

    test('fills an empty card and marks the source', () {
      final p = cardDayPatches([card()], {'c1': days});
      expect(p['c1'], {
        'statement_day': 18,
        'statement_day_source': 'sms',
        'due_day': 5,
        'due_day_source': 'sms',
      });
    });

    test('never overwrites a day the person typed', () {
      final p = cardDayPatches(
        [card(stmt: 20, stmtSrc: 'user', due: 7, dueSrc: 'user')],
        {'c1': days},
      );
      expect(p, isEmpty);
    });

    test(
      'follows newer evidence over an earlier SMS day, and is quiet when equal',
      () {
        expect(
          cardDayPatches(
            [card(stmt: 17, stmtSrc: 'sms', due: 5, dueSrc: 'sms')],
            {'c1': days},
          )['c1'],
          {'statement_day': 18, 'statement_day_source': 'sms'},
        );
        expect(
          cardDayPatches(
            [card(stmt: 18, stmtSrc: 'sms', due: 5, dueSrc: 'sms')],
            {'c1': days},
          ),
          isEmpty,
        );
      },
    );

    test('leaves a day of unknown origin alone', () {
      final p = cardDayPatches([card(stmt: 20, due: 7)], {'c1': days});
      expect(p, isEmpty);
    });
  });

  group('pastBillReceiptsFromBills', () {
    Commitment c(String id, DateTime due, CommitmentStatus s, {String? txn}) =>
        Commitment(
          id: id,
          title: 'HDFC Bank Credit Card',
          category: CommitmentCategory.other,
          amount: Money.fromPaise(250000),
          dueOn: due,
          identifier: '1234',
          cadence: CommitmentCadence.oneTime,
          status: s,
          linkedTransactionId: txn,
          confidence: 0.9,
        );

    test('lists only past v2 bills, newest first, with their state', () {
      final now = DateTime(2026, 11, 15);
      final rows = pastBillReceiptsFromBills([
        c('v2:a', DateTime(2026, 9, 5), CommitmentStatus.paid, txn: 't1'),
        c('v2:b', DateTime(2026, 10, 5), CommitmentStatus.paymentNotDetected),
        c('v2:c', DateTime(2026, 11, 20), CommitmentStatus.due),
        c('manual-1', DateTime(2026, 8, 5), CommitmentStatus.due),
        c('v2:d', DateTime(2026, 8, 5), CommitmentStatus.dismissed),
      ], now);
      expect(rows.map((r) => r.sourceKey), ['v2:b', 'v2:a']);
      expect(rows[0].status, PastBillReceiptStatus.historicalUnpaid);
      expect(rows[1].status, PastBillReceiptStatus.paidLinked);
      expect(rows[1].cardLast4, '1234');
    });
  });
}
