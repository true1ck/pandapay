import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/features/voice/answers/card_answers.dart';
import '../../../../lib/features/voice/answers/voice_answer.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

void main() {
  group('bills', () {
    test('one unpaid bill, said plainly', () {
      final a = const BillsAnswerer().answer(
        [
          BillLine(
            cardName: 'HDFC Swiggy',
            dueDate: DateTime(2026, 11, 15),
            amountDue: 12340,
            outstanding: 12340,
            minimumDue: 620,
          ),
        ],
        now,
        cardsNamed: true,
      );
      expect(a.headline, '₹12,340');
      expect(a.title, 'Bills · HDFC Swiggy');
      expect(
        a.spoken,
        'Your HDFC Swiggy bill is ₹12,340, due Sun 15 Nov, in 4 days.',
      );
      expect(a.rows.single.detail, 'due Sun 15 Nov (in 4 days) · minimum ₹620');
    });

    test('several bills: total, and the next one due', () {
      final a = const BillsAnswerer().answer([
        BillLine(
          cardName: 'Amex',
          dueDate: DateTime(2026, 11, 20),
          outstanding: 5000,
        ),
        BillLine(
          cardName: 'HDFC Swiggy',
          dueDate: DateTime(2026, 11, 14),
          outstanding: 12340,
        ),
        BillLine(
          cardName: 'Axis Atlas',
          isPaid: true,
          dueDate: DateTime(2026, 11, 9),
        ),
      ], now);
      expect(a.headline, '₹17,340');
      expect(a.comparison, 'Next due: HDFC Swiggy on Sat 14 Nov');
      expect(a.rows.map((r) => r.label), ['HDFC Swiggy', 'Amex', 'Axis Atlas']);
      expect(a.rows.last.value, 'Paid');
    });

    test('an overdue bill says so', () {
      final a = const BillsAnswerer().answer([
        BillLine(
          cardName: 'Amex',
          dueDate: DateTime(2026, 11, 8),
          outstanding: 5000,
        ),
      ], now);
      expect(a.rows.single.detail, contains('3 days overdue'));
    });

    test('a bill paid in full', () {
      final a = const BillsAnswerer().answer([
        BillLine(
          cardName: 'Amex',
          isPaid: true,
          dueDate: DateTime(2026, 11, 8),
          amountDue: 5000,
          outstanding: 0,
        ),
      ], now);
      expect(a.headline, 'All paid');
      expect(a.spoken, 'Your Amex bill is already paid.');
    });

    test('a card with no bill yet is named, not skipped', () {
      final a = const BillsAnswerer().answer([
        BillLine(
          cardName: 'Amex',
          dueDate: DateTime(2026, 11, 20),
          outstanding: 5000,
        ),
        const BillLine(cardName: 'Axis Atlas', hasBill: false),
      ], now);
      expect(a.coverageNote, 'No bill found yet for Axis Atlas.');
    });

    test('no bill for anything', () {
      final a = const BillsAnswerer().answer(
        [const BillLine(cardName: 'Axis Atlas', hasBill: false)],
        now,
        cardsNamed: true,
      );
      expect(a.status, AnswerStatus.noData);
      expect(a.evidence, contains('haven’t found a bill'));
    });

    test('no cards', () {
      expect(
        const BillsAnswerer().answer(const [], now).status,
        AnswerStatus.noData,
      );
    });

    test('autopay is shown', () {
      final a = const BillsAnswerer().answer([
        BillLine(
          cardName: 'Amex',
          dueDate: DateTime(2026, 11, 20),
          outstanding: 5000,
          isAutopay: true,
        ),
      ], now);
      expect(a.rows.single.detail, contains('autopay on'));
    });
  });

  group('caps', () {
    const lines = [
      CapLine(
        cardName: 'Swiggy',
        label: 'Online',
        remaining: '₹1,200 left',
        used: '₹1,800 / ₹3,000 spent',
        reset: 'resets 1 Dec',
        ratio: 0.6,
      ),
      CapLine(
        cardName: 'Swiggy',
        label: 'Dining',
        remaining: '₹100 left',
        used: '₹1,900 / ₹2,000 spent',
        reset: 'resets 1 Dec',
        ratio: 0.95,
      ),
    ];

    test('the fullest cap comes first', () {
      final a = const CapsAnswerer().answer(lines, cardsNamed: true);
      expect(a.headline, '₹100 left');
      expect(a.title, 'Caps · Swiggy');
      expect(a.rows.map((r) => r.label), ['Dining', 'Online']);
      expect(
        a.spoken,
        'On your Swiggy, the Dining cap has ₹100 left and resets 1 Dec.',
      );
    });

    test('a reached cap says what it means', () {
      final a = const CapsAnswerer().answer(const [
        CapLine(
          cardName: 'Swiggy',
          label: 'Dining',
          remaining: '₹0 left',
          used: '₹2,000 / ₹2,000 spent',
          reset: 'resets 1 Dec',
          ratio: 1,
          reached: true,
          consequence: 'extra spend here earns only 1%',
        ),
      ]);
      expect(a.headline, 'Cap reached');
      expect(
        a.spoken,
        'You’ve used all of the Dining cap on your Swiggy, and extra spend here earns only 1%.',
      );
    });

    test('cards with no caps', () {
      expect(const CapsAnswerer().answer(const []).status, AnswerStatus.noData);
    });

    test('buttons lead to Caps and Milestones', () {
      final a = const CapsAnswerer().answer(lines);
      expect(a.actions.map((x) => x.kind), [
        AnswerActionKind.caps,
        AnswerActionKind.milestones,
      ]);
    });
  });

  group('points', () {
    test('one card, with value and expiry', () {
      final a = const PointsAnswerer().answer([
        PointsLine(
          cardName: 'Amex',
          points: 14200,
          valueRupees: 4260,
          nearestExpiry: DateTime(2026, 12, 31),
        ),
      ], now);
      expect(a.headline, '14,200 points');
      expect(a.title, 'Points · Amex');
      expect(
        a.spoken,
        'You have about 14,200 points on your Amex, worth roughly ₹4,260.',
      );
      expect(a.rows.single.detail, '≈ ₹4,260 · next expiry Thu 31 Dec');
      expect(a.evidence, contains('estimate'));
    });

    test('several cards add up, and a card with no balance is named', () {
      final a = const PointsAnswerer().answer(const [
        PointsLine(cardName: 'Amex', points: 14200),
        PointsLine(cardName: 'Axis Atlas', points: 8800),
        PointsLine(cardName: 'HDFC Swiggy'),
      ], now);
      expect(a.headline, '23,000 points');
      expect(a.coverageNote, 'No points balance saved for HDFC Swiggy.');
    });

    test('no balance saved at all', () {
      final a = const PointsAnswerer().answer(const [
        PointsLine(cardName: 'Amex'),
      ], now);
      expect(a.status, AnswerStatus.noData);
    });
  });

  group('best card', () {
    const ranked = [
      RecoLine(
        cardName: 'Axis Atlas',
        expectedValue: 135,
        reason: '3% on this category, no cap used yet',
      ),
      RecoLine(cardName: 'HDFC Regalia', expectedValue: 90),
      RecoLine(cardName: 'Amex', expectedValue: 0, excluded: true),
    ];

    test('top card, what it earns, and a backup', () {
      final a = const BestCardAnswerer().answer(
        ranked,
        amount: 4500,
        merchant: 'Croma',
      );
      expect(a.headline, 'Axis Atlas');
      expect(a.title, 'Best card · Croma · ₹4,500');
      expect(a.comparison, 'Earns about ₹135');
      expect(a.evidence, '3% on this category, no cap used yet');
      expect(
        a.spoken,
        'Use your Axis Atlas for ₹4,500 at Croma. You’d earn about ₹135. Backup: HDFC Regalia.',
      );
      expect(a.rows.map((r) => r.label), ['Axis Atlas', 'HDFC Regalia']);
      expect(a.coverageNote, isNull);
    });

    test('no amount said: a default, shown', () {
      final a = const BestCardAnswerer().answer(
        ranked,
        categoryName: 'Groceries',
      );
      expect(a.coverageNote, contains('₹1,000'));
      expect(a.title, 'Best card · Groceries · ₹1,000');
    });

    test('no cards', () {
      final a = const BestCardAnswerer().answer(const []);
      expect(a.status, AnswerStatus.noData);
    });
  });
}
