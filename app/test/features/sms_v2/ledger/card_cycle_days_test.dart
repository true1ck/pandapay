import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/card_cycle_days.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:sqlite3/sqlite3.dart';

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

  group('learnedDaysByCard', () {
    test('each card gets what its own bills agree on', () {
      final r = learnedDaysByCard({
        'a': ledger([bill(11, 18, 5), bill(10, 18, 5)]),
        'b': ledger([bill(11, 3, 21), bill(10, 3, 21)]),
      });
      expect(r['a']!.statementDay, 18);
      expect(r['b']!.dueDay, 21);
    });

    test('a bill read as evidence for two cards teaches neither', () {
      CardBill shared(int m) => CardBill(
        statementDate: DateTime(2026, m, 6),
        statementDateExplicit: true,
        statementDateVerified: true,
        dueDate: DateTime(2026, m, 8),
        amountDue: Money.fromPaise(100000),
        minimumDue: null,
        paidToward: const Money.zero(),
        lastPaymentAt: null,
        confidence: 0.9,
        sourceIds: ['sms:aggregator-$m'],
      );
      final r = learnedDaysByCard({
        'moneyback': ledger([shared(11), shared(10)]),
        'tataneu': ledger([shared(11), shared(10)]),
      });
      expect(r, isEmpty);
    });

    test('a card that shares only some of its bills keeps the rest', () {
      CardBill own(int m, String src) => CardBill(
        statementDate: DateTime(2026, m, 18),
        statementDateExplicit: true,
        statementDateVerified: true,
        dueDate: DateTime(2026, m, 5),
        amountDue: Money.fromPaise(100000),
        minimumDue: null,
        paidToward: const Money.zero(),
        lastPaymentAt: null,
        confidence: 0.9,
        sourceIds: [src],
      );
      final r = learnedDaysByCard({
        'a': ledger([own(11, 'x'), own(10, 'y')]),
        'b': ledger([own(11, 'x')]), // the same message as a's November bill
      });
      expect(r['a']!.statementDay, 18); // October alone still teaches it
      expect(r.containsKey('b'), isFalse);
    });
  });

  group('cardsWithTrustedDays', () {
    UserCard c(
      String id, {
      int? stmt,
      int? due,
      String? stmtSrc = 'sms',
      String? dueSrc = 'sms',
      bool archived = false,
    }) => UserCard(
      id: id,
      cardProductId: 'p',
      cardName: id,
      isDefault: false,
      statementDay: stmt,
      statementDaySource: stmt == null ? null : stmtSrc,
      dueDay: due,
      dueDaySource: due == null ? null : dueSrc,
      isArchived: archived,
    );
    const none = <String, LearnedCardDays>{};

    test('two cards holding the same days read from SMS show none', () {
      // The old build taught every card of one bank the same cycle.
      final r = cardsWithTrustedDays(
        [c('moneyback', stmt: 6, due: 8), c('tataneu', stmt: 6, due: 8)],
        none,
      );
      expect(r.map((x) => x.statementDay), [null, null]);
      expect(r.map((x) => x.dueDay), [null, null]);
    });

    test('a day typed by the person stays, and the copy of it goes', () {
      final r = cardsWithTrustedDays(
        [
          c('a', stmt: 6, due: 8, stmtSrc: 'user', dueSrc: 'user'),
          c('b', stmt: 6, due: 8),
        ],
        none,
      );
      expect(r[0].dueDay, 8);
      expect(r[1].dueDay, isNull);
    });

    test('days that differ stay', () {
      final r = cardsWithTrustedDays(
        [c('a', stmt: 6, due: 8), c('b', stmt: 12, due: 28)],
        none,
      );
      expect(r.map((x) => x.dueDay), [8, 28]);
    });

    test('three cards: the pair that matches goes, the other stays', () {
      final r = cardsWithTrustedDays(
        [c('a', stmt: 6, due: 8), c('b', stmt: 6, due: 8), c('c', stmt: 1, due: 20)],
        none,
      );
      expect(r.map((x) => x.dueDay), [null, null, 20]);
    });

    test('a day a card learned from its own bills beats a stored one', () {
      final r = cardsWithTrustedDays(
        [c('a', stmt: 6, due: 8), c('b', stmt: 6, due: 8)],
        {'a': const LearnedCardDays(statementDay: 18, dueDay: 5)},
      );
      expect(r[0].statementDay, 18);
      expect(r[0].dueDay, 5);
      expect(r[1].dueDay, isNull); // b has no evidence of its own
    });

    test('learned days survive a refresh that brings the server row back', () {
      final learned = {'a': const LearnedCardDays(statementDay: 18, dueDay: 5)};
      // The server row carries no days (or the old suspect ones): same result.
      for (final server in [
        [c('a'), c('b')],
        [c('a', stmt: 6, due: 8), c('b', stmt: 6, due: 8)],
      ]) {
        final r = cardsWithTrustedDays(server, learned);
        expect(r[0].dueDay, 5);
      }
    });

    test('a person\'s own day beats what was learned', () {
      final r = cardsWithTrustedDays(
        [c('a', stmt: 20, due: 10, stmtSrc: 'user', dueSrc: 'user')],
        {'a': const LearnedCardDays(statementDay: 18, dueDay: 5)},
      );
      expect(r.single.statementDay, 20);
      expect(r.single.dueDay, 10);
    });

    test('two cards that each learned the same days from their own bills keep them', () {
      final r = cardsWithTrustedDays(
        [c('a'), c('b')],
        {
          'a': const LearnedCardDays(statementDay: 6, dueDay: 8),
          'b': const LearnedCardDays(statementDay: 6, dueDay: 8),
        },
      );
      expect(r.map((x) => x.dueDay), [8, 8]);
    });

    test('a lone card keeps its stored days; an archived twin does not count', () {
      final r = cardsWithTrustedDays(
        [c('a', stmt: 6, due: 8), c('old', stmt: 6, due: 8, archived: true)],
        none,
      );
      expect(r[0].dueDay, 8);
      expect(r[1].dueDay, 8); // an archived card is left as it is
    });

    test('cards without days, or with nothing to change, come back as they were', () {
      final cards = [c('a'), c('b', stmt: 12, due: 28)];
      final r = cardsWithTrustedDays(cards, none);
      expect(identical(r[0], cards[0]), isTrue);
      expect(identical(r[1], cards[1]), isTrue);
    });

    test('only one of the two days suspect: each day is judged with its pair', () {
      // Same billing day, different due days: not the same cycle, both stay.
      final r = cardsWithTrustedDays(
        [c('a', stmt: 6, due: 8), c('b', stmt: 6, due: 21)],
        none,
      );
      expect(r.map((x) => x.dueDay), [8, 21]);
    });
  });

  group('LearnedCardDaysStore', () {
    Database db() {
      final d = sqlite3.openInMemory();
      d.execute(
        'CREATE TABLE v2_sync_state(namespace TEXT, key TEXT, value TEXT, PRIMARY KEY(namespace,key))',
      );
      return d;
    }

    test('saves, reads back, and reports a change only when there is one', () {
      final store = LearnedCardDaysStore(db(), namespace: 'u1');
      expect(store.all(), isEmpty);
      expect(store.replace({'a': const LearnedCardDays(statementDay: 18, dueDay: 5)}), isTrue);
      expect(store.all()['a']!.dueDay, 5);
      expect(store.replace({'a': const LearnedCardDays(statementDay: 18, dueDay: 5)}), isFalse);
      expect(store.replace({'a': const LearnedCardDays(statementDay: 18, dueDay: 6)}), isTrue);
    });

    test('a card that stops teaching anything is forgotten', () {
      final store = LearnedCardDaysStore(db(), namespace: 'u1');
      store.replace({'a': const LearnedCardDays(dueDay: 5), 'b': const LearnedCardDays(dueDay: 9)});
      expect(store.replace({'a': const LearnedCardDays(dueDay: 5)}), isTrue);
      expect(store.all().keys, ['a']);
    });

    test('accounts stay apart', () {
      final d = db();
      LearnedCardDaysStore(d, namespace: 'u1').replace({'a': const LearnedCardDays(dueDay: 5)});
      expect(LearnedCardDaysStore(d, namespace: 'u2').all(), isEmpty);
    });

    test('before the table exists it reads as empty, never throws', () {
      expect(LearnedCardDaysStore(sqlite3.openInMemory(), namespace: 'u1').all(), isEmpty);
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
