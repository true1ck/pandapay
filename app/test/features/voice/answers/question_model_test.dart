import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/data/catalogue_repository.dart' show SpendCategory;
import '../../../../lib/data/user_cards_repository.dart'
    show TxnInstrument, UserCard;
import '../../../../lib/features/voice/answers/question_model.dart';
import '../../../../lib/features/voice/understanding/date_grammar.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

const categories = [
  SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'groceries-id', slug: 'groceries', name: 'Groceries'),
  SpendCategory(id: 'bills-id', slug: 'bills', name: 'Bills'),
  SpendCategory(id: 'fuel-id', slug: 'fuel', name: 'Fuel'),
  SpendCategory(
    id: 'entertainment-id',
    slug: 'entertainment',
    name: 'Entertainment',
  ),
];

UserCard card(String id, String name, {String? nick, String? last4}) =>
    UserCard(
      id: id,
      cardProductId: 'p-$id',
      cardName: name,
      nickname: nick,
      last4: last4,
      isDefault: false,
    );

final cards = [
  card(
    'amex',
    'American Express Platinum Travel Card',
    nick: 'Amex',
    last4: '1007',
  ),
  card('hs', 'HDFC Swiggy Credit Card', last4: '4521'),
  card('hr', 'HDFC Regalia Gold Credit Card', last4: '9090'),
  card('axis', 'Axis Atlas Credit Card', last4: '3344'),
];

VoiceQuestion ask(String text) => const QuestionReader().read(
  text,
  now: now,
  cards: cards,
  categories: categories,
  knownMerchants: const ['Croma', 'Ramu Tea Stall'],
);

DateTime d(int m, int day, [int y = 2026]) => DateTime(y, m, day);

void main() {
  group('what is being asked', () {
    const cases = <String, QuestionKind>{
      'how much did I spend this month': QuestionKind.spend,
      'how much did I spend on dining last month': QuestionKind.spend,
      'what did I spend on swiggy last month': QuestionKind.spend,
      'show me my spending this week': QuestionKind.spend,
      'total spending in october': QuestionKind.spend,
      'where did I spend the most this month': QuestionKind.topSpends,
      'what is my biggest expense this year': QuestionKind.topSpends,
      'how much came in this month': QuestionKind.moneyIn,
      'how much income last month': QuestionKind.moneyIn,
      'this month versus last month': QuestionKind.compare,
      'did I spend more than last month': QuestionKind.compare,
      'compare my dining spend to last month': QuestionKind.compare,
      'when is my hdfc bill due': QuestionKind.billsDue,
      'how much is due on my amex': QuestionKind.billsDue,
      'what is my bill': QuestionKind.billsDue,
      'how much cap is left on my swiggy card': QuestionKind.capsLeft,
      'how far am I from the milestone on atlas': QuestionKind.capsLeft,
      'how many points do I have on amex': QuestionKind.pointsBalance,
      'what is my points balance': QuestionKind.pointsBalance,
      'which card should I use for 4500 at croma': QuestionKind.bestCard,
      'best card for groceries': QuestionKind.bestCard,
      'what is the weather like': QuestionKind.unknown,
    };
    cases.forEach((text, kind) {
      test('"$text"', () => expect(ask(text).kind, kind));
    });
  });

  group('the period', () {
    test('a named period is used as said', () {
      final q = ask('how much did I spend last month');
      expect(q.period!.from, d(10, 1));
      expect(q.period!.to, d(10, 31));
      expect(q.periodDefaulted, isFalse);
    });

    test('no period means this month, and says so', () {
      final q = ask('how much did I spend on dining');
      expect(q.period!.from, d(11, 1));
      expect(q.period!.to, d(11, 30));
      expect(q.periodDefaulted, isTrue);
    });

    test('a single day is a period too', () {
      final q = ask('how much did I spend yesterday');
      expect(q.period!.isSingleDay, isTrue);
      expect(q.period!.from, d(11, 10));
    });

    test('two periods are compared', () {
      final q = ask('this month versus last month');
      expect(q.period!.kind, TimeSpanKind.month);
      expect(q.period!.from, d(11, 1));
      expect(q.comparePeriod!.from, d(10, 1));
    });

    test('"than last month" compares with this month', () {
      final q = ask('did I spend more than last month');
      expect(q.period!.from, d(11, 1));
      expect(q.comparePeriod!.from, d(10, 1));
    });

    test('questions without a period have none', () {
      expect(ask('when is my hdfc bill due').period, isNull);
      expect(ask('how many points do I have on amex').period, isNull);
    });

    test('a date ahead is ignored, not answered', () {
      final q = ask('how much will I spend on 25 november');
      expect(q.period!.from, d(11, 1));
    });
  });

  group('the filters come from the user\'s own data', () {
    test('a category', () {
      final q = ask('how much did I spend on dining this month');
      expect(q.category!.slug, 'dining');
      expect(q.merchant, isNull);
      expect(q.filterCount, 1);
    });

    test('a known brand is a merchant, not also a category', () {
      final q = ask('how much have I spent on netflix this year');
      expect(q.merchant, 'Netflix');
      expect(q.category, isNull);
      expect(q.filterCount, 1);
    });

    test('the user\'s own merchant', () {
      final q = ask('how much at ramu tea stall last week');
      expect(q.merchant, 'Ramu Tea Stall');
    });

    test('a card by nickname', () {
      final q = ask('how much did I spend on my amex last month');
      expect(q.cards.single.id, 'amex');
      expect(q.merchant, isNull);
    });

    test('an instrument', () {
      final q = ask('how much did I spend by upi this month');
      expect(q.instrument, TxnInstrument.upiBank);
      expect(q.filterCount, 1);
    });

    test('several filters combine', () {
      final q = ask('how much on dining with my amex last month');
      expect(q.category!.slug, 'dining');
      expect(q.cards.single.id, 'amex');
      expect(q.filterCount, 2);
    });

    test('one word can name several cards', () {
      final q = ask('when is my hdfc bill due');
      expect(q.cards.map((c) => c.id).toSet(), {'hs', 'hr'});
    });

    test('a full name picks one card', () {
      final q = ask('when is my hdfc swiggy bill due');
      expect(q.cards.map((c) => c.id), ['hs']);
    });

    test('last digits pick a card', () {
      final q = ask('how many points on the card ending 3344');
      expect(q.cards.single.id, 'axis');
    });

    test('no card named means all cards', () {
      expect(ask('how many points do I have').cards, isEmpty);
    });
  });

  group('which card for a purchase', () {
    test('amount, merchant and category', () {
      final q = ask('which card should I use for 4500 at croma');
      expect(q.kind, QuestionKind.bestCard);
      expect(q.amount, 4500);
      expect(q.merchant, 'Croma');
    });

    test('a category with no amount', () {
      final q = ask('best card for groceries');
      expect(q.category!.slug, 'groceries');
      expect(q.amount, isNull);
    });

    test('spoken amounts', () {
      final q = ask('which card for four thousand five hundred at croma');
      expect(q.amount, 4500);
    });
  });
}
