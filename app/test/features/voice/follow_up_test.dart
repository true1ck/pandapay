import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../lib/data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import '../../../lib/features/voice/follow_up/follow_up.dart';
import '../../../lib/features/voice/follow_up/refund_candidates.dart';
import '../../../lib/features/voice/voice_action_parser.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

TransactionEntry spend(
  String id,
  double rupees,
  DateTime at, {
  String? merchant,
  TxnEntryKind kind = TxnEntryKind.spend,
  String status = 'active',
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: at,
  merchantName: merchant,
  categoryId: 'cat-$id',
  userCardId: 'card-$id',
  entryKind: kind,
  source: 'manual',
  status: status,
);

void main() {
  group('planner', () {
    test('a foreign amount asks for rupees first, then the card', () {
      var s = const FollowUpState(
        type: VoiceActionType.expense,
        foreignCurrency: 'USD',
        foreignAmount: 50,
        cardNeeded: true,
        cards: [FollowUpChoice('a', 'Axis Atlas')],
      );
      final q1 = FollowUpPlanner.next(s)!;
      expect(q1.slot, FollowUpSlot.rupeeAmount);
      expect(q1.numeric, isTrue);
      expect(q1.hint, contains('USD 50'));
      s = FollowUpState(
        type: s.type,
        amount: 4200,
        foreignCurrency: 'USD',
        foreignAmount: 50,
        cardNeeded: true,
        cards: s.cards,
        asked: {FollowUpSlot.rupeeAmount},
      );
      expect(FollowUpPlanner.next(s)!.slot, FollowUpSlot.card);
    });

    test('a missing amount is asked for', () {
      final q = FollowUpPlanner.next(
        const FollowUpState(type: VoiceActionType.expense),
      )!;
      expect(q.slot, FollowUpSlot.amount);
    });

    test('an unclear kind comes before everything else', () {
      final q = FollowUpPlanner.next(
        const FollowUpState(
          type: VoiceActionType.moneyIn,
          amount: 500,
          kindAlternative: VoiceActionType.refund,
        ),
      )!;
      expect(q.slot, FollowUpSlot.kind);
      expect(q.choices.map((c) => c.label), ['Money in', 'Refund']);
    });

    test('a refund asks which purchase, with a way out', () {
      final q = FollowUpPlanner.next(
        const FollowUpState(
          type: VoiceActionType.refund,
          amount: 500,
          refundCandidates: [FollowUpChoice('t1', 'Amazon · ₹2,499')],
        ),
      )!;
      expect(q.slot, FollowUpSlot.refundPurchase);
      expect(q.choices.last.id, 'none');
    });

    test('a refund with no matching purchase asks nothing about it', () {
      expect(
        FollowUpPlanner.next(
          const FollowUpState(type: VoiceActionType.refund, amount: 500),
        ),
        isNull,
      );
    });

    test('money in asks what it was, then how it arrived', () {
      var s = const FollowUpState(type: VoiceActionType.moneyIn, amount: 5000);
      expect(FollowUpPlanner.next(s)!.slot, FollowUpSlot.moneyInType);
      s = const FollowUpState(
        type: VoiceActionType.moneyIn,
        amount: 5000,
        moneyInTypeChosen: true,
        asked: {FollowUpSlot.moneyInType},
      );
      expect(FollowUpPlanner.next(s)!.slot, FollowUpSlot.moneyInHow);
    });

    test('at most two questions per entry', () {
      expect(
        FollowUpPlanner.next(
          const FollowUpState(
            type: VoiceActionType.moneyIn,
            amount: 5000,
            asked: {FollowUpSlot.moneyInType, FollowUpSlot.moneyInHow},
          ),
        ),
        isNull,
      );
    });

    test('a spend with everything known asks nothing', () {
      expect(
        FollowUpPlanner.next(
          const FollowUpState(
            type: VoiceActionType.expense,
            amount: 250,
            cardNeeded: true,
            hasCard: true,
          ),
        ),
        isNull,
      );
    });

    test('a spend that needs a card offers the wallet cards', () {
      final q = FollowUpPlanner.next(
        const FollowUpState(
          type: VoiceActionType.expense,
          amount: 250,
          cardNeeded: true,
          cards: [
            FollowUpChoice('a', 'Axis Atlas'),
            FollowUpChoice('b', 'HDFC Swiggy'),
          ],
        ),
      )!;
      expect(q.slot, FollowUpSlot.card);
      expect(q.choices, hasLength(2));
    });
  });

  group('reading answers', () {
    test('numbers, however they are said', () {
      expect(FollowUpAnswers.number('4200'), 4200);
      expect(FollowUpAnswers.number('about 4,200 rupees'), 4200);
      expect(FollowUpAnswers.number('forty two hundred'), 4200);
      expect(FollowUpAnswers.number('4.2k'), 4200);
      expect(FollowUpAnswers.number('no idea'), isNull);
    });

    const choices = [
      FollowUpChoice('t1', 'Amazon · ₹2,499 · Fri 6 Nov'),
      FollowUpChoice('t2', 'Flipkart · ₹999 · Mon 2 Nov'),
      FollowUpChoice('none', 'None of these'),
    ];

    test('by a word of the label', () {
      expect(FollowUpAnswers.choice('the amazon one', choices)?.id, 't1');
      expect(FollowUpAnswers.choice('flipkart', choices)?.id, 't2');
    });

    test('by position', () {
      expect(FollowUpAnswers.choice('the second one', choices)?.id, 't2');
      expect(FollowUpAnswers.choice('first', choices)?.id, 't1');
      expect(FollowUpAnswers.choice('the last one', choices)?.id, 'none');
    });

    test('by saying none', () {
      expect(FollowUpAnswers.choice('none', choices)?.id, 'none');
      expect(FollowUpAnswers.choice('neither of them', choices)?.id, 'none');
    });

    test('an unclear answer is not guessed', () {
      expect(FollowUpAnswers.choice('hmm not sure', choices), isNull);
      const twins = [
        FollowUpChoice('a', 'Axis Bank Atlas'),
        FollowUpChoice('b', 'Axis Bank Magnus'),
      ];
      expect(FollowUpAnswers.choice('axis', twins), isNull);
      expect(FollowUpAnswers.choice('magnus', twins)?.id, 'b');
    });
  });

  group('refund candidates', () {
    final history = [
      spend('a', 2499, DateTime(2026, 11, 6), merchant: 'Amazon'),
      spend('b', 999, DateTime(2026, 11, 2), merchant: 'Flipkart'),
      spend('c', 500, DateTime(2026, 10, 20), merchant: 'Amazon Pay'),
      spend('d', 300, DateTime(2026, 10, 25), merchant: 'Amazon'),
      spend('e', 2499, DateTime(2026, 5, 1), merchant: 'Amazon'),
      spend('f', 800, DateTime(2026, 11, 8), merchant: 'Amazon', status: 'deleted'),
      spend('g', 800, DateTime(2026, 11, 8), merchant: 'Amazon', kind: TxnEntryKind.income),
    ];

    test('same shop, at least the refunded amount, recent, active', () {
      final c = RefundCandidates.find(
        history,
        now: now,
        merchant: 'Amazon',
        amount: 500,
      );
      expect(c.map((x) => x.transactionId), ['c', 'a']);
    });

    test('an exact amount ranks first', () {
      final c = RefundCandidates.find(
        history,
        now: now,
        merchant: 'Amazon',
        amount: 2499,
      );
      expect(c.first.transactionId, 'a');
    });

    test('a different shop is not offered', () {
      expect(
        RefundCandidates.find(history, now: now, merchant: 'Myntra', amount: 100),
        isEmpty,
      );
    });

    test('with no shop named, recent purchases that cover the amount', () {
      final c = RefundCandidates.find(history, now: now, amount: 2000);
      expect(c.single.transactionId, 'a');
    });

    test('the label reads naturally', () {
      final c = RefundCandidates.find(
        history,
        now: now,
        merchant: 'Amazon',
        amount: 2499,
      ).first;
      expect(c.label(now), 'Amazon · ₹2,499 · Fri 6 Nov');
    });

    test('keeps the purchase details a refund should inherit', () {
      final c = RefundCandidates.find(
        history,
        now: now,
        merchant: 'Flipkart',
        amount: 999,
      ).single;
      expect(c.categoryId, 'cat-b');
      expect(c.userCardId, 'card-b');
    });
  });
}
