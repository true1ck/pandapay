import 'package:flutter_test/flutter_test.dart';

import '../../../lib/data/catalogue_repository.dart' show SpendCategory;
import '../../../lib/data/user_cards_repository.dart'
    show TxnInstrument, UserCard;
import '../../../lib/features/voice/voice_action_parser.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

const categories = [
  SpendCategory(id: 'travel-id', slug: 'travel', name: 'Travel'),
  SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'groceries-id', slug: 'groceries', name: 'Groceries'),
  SpendCategory(id: 'fuel-id', slug: 'fuel', name: 'Fuel'),
  SpendCategory(id: 'online-id', slug: 'online', name: 'Online'),
  SpendCategory(id: 'bills-id', slug: 'bills', name: 'Bills'),
];

UserCard card(String id, String name, {String? last4}) => UserCard(
  id: id,
  cardProductId: 'product-$id',
  cardName: name,
  last4: last4,
  isDefault: false,
);

List<VoiceActionDraft> parse(String text, {List<UserCard> cards = const []}) =>
    VoiceActionParser.parseMany(
      text,
      cards: cards,
      categories: categories,
      now: now,
    );

void main() {
  group('dates become a saved day', () {
    test('yesterday is noon yesterday, and is shown as heard', () {
      final d = parse('spent 250 on groceries yesterday').single;
      expect(d.occurredAt, DateTime(2026, 11, 10, 12));
      expect(d.heard.map((h) => h.label), contains('Date'));
      expect(
        d.heard.firstWhere((h) => h.label == 'Date').shown,
        'Yesterday',
      );
    });

    test('today keeps "now" so the saved time is the real time', () {
      expect(parse('spent 250 on groceries today').single.occurredAt, isNull);
      expect(parse('spent 250 on groceries').single.occurredAt, isNull);
    });

    test('a date ahead blocks saving and says why', () {
      final d = parse('spent 500 on fuel on 25 november').single;
      expect(d.dateIsFuture, isTrue);
      expect(d.canSave, isFalse);
      expect(d.issues.join(' '), contains('future'));
    });

    test('a stretch of days asks for the day', () {
      final d = parse('spent 500 on fuel last week').single;
      expect(d.dateIsVague, isTrue);
      expect(d.issues.join(' '), contains('exact day'));
    });
  });

  group('what was heard is shown', () {
    test('the conversion of a spoken amount', () {
      final d = parse('spent two fifty on lunch').single;
      final amount = d.heard.firstWhere((h) => h.label == 'Amount');
      expect(amount.source, 'two fifty');
      expect(amount.shown, '₹250');
      expect(d.alternatives.single.label, '₹2.50?');
      expect(d.alternatives.single.amount, 2.5);
    });

    test('a spoken correction shows both values', () {
      final d = parse('spent 200 no sorry 250 on lunch').single;
      expect(d.amount, 250);
      expect(
        d.heard.firstWhere((h) => h.label == 'Corrected').shown,
        '₹200 → ₹250',
      );
    });

    test('a quantity is shown as not money', () {
      final d = parse('spent on 2 coffees 300').single;
      expect(d.amount, 300);
      expect(d.heard.any((h) => h.label == 'Not money'), isTrue);
    });

    test('Indian grouping in the shown amount', () {
      final d = parse('spent two lakh fifty thousand on a laptop').single;
      expect(d.heard.first.shown, '₹2,50,000');
    });

    test('a number that was not used is reported, not dropped', () {
      final d = parse('paid 500 to account 123456789012').single;
      expect(d.warnings.single, contains('123456789012'));
    });
  });

  group('merchant and category come from the words that are left', () {
    test('a known brand sets merchant and category', () {
      final d = parse('spent 340 on Swiggy').single;
      expect(d.merchant, 'Swiggy');
      expect(d.categoryId, 'dining-id');
    });

    test('a bare category word is the category, not a merchant', () {
      final d = parse('spent 250 on groceries').single;
      expect(d.merchant, isNull);
      expect(d.categoryId, 'groceries-id');
    });

    test('a date word does not leak into the merchant', () {
      final d = parse('spent 250 on lunch yesterday').single;
      expect(d.merchant, isNull);
      expect(d.categoryId, 'dining-id');
    });

    test('free text after "on" is kept as the merchant', () {
      final d = parse('spent 250 on chocolates').single;
      expect(d.merchant, 'Chocolates');
    });

    test('the user\'s own merchants are recognized', () {
      final d = VoiceActionParser.parseMany(
        'paid 90 at ramu tea stall',
        cards: const [],
        categories: categories,
        knownMerchants: const ['Ramu Tea Stall'],
        now: now,
      ).single;
      expect(d.merchant, 'Ramu Tea Stall');
    });

    test('card words are not a merchant', () {
      final d = parse('spent 250 on my hdfc card').single;
      expect(d.merchant, isNull);
    });
  });

  group('instrument', () {
    test('words, not substrings', () {
      expect(
        parse('spent 100 cash on tea').single.instrument,
        TxnInstrument.cash,
      );
      expect(
        parse('got cashback 100').single.instrument,
        isNot(TxnInstrument.cash),
      );
      expect(
        parse('paid 100 by upi for parking').single.instrument,
        TxnInstrument.upiBank,
      );
    });
  });

  group('card digits', () {
    test('spoken digits pick the card', () {
      final d = parse(
        'spent 500 on my card ending four five six seven',
        cards: [
          card('a', 'Axis Atlas Credit Card', last4: '4567'),
          card('b', 'HDFC Swiggy Credit Card', last4: '1111'),
        ],
      ).single;
      expect(d.userCardId, 'a');
      expect(d.issues, isEmpty);
    });
  });

  group('money in and refunds', () {
    test('money received from someone', () {
      final d = parse('received 5000 from Rahul').single;
      expect(d.type, VoiceActionType.moneyIn);
      expect(d.amount, 5000);
      expect(d.merchant, 'Rahul');
      expect(d.issues, isEmpty, reason: 'money in needs no wallet card');
      expect(d.instrument, TxnInstrument.other);
    });

    test('a refund names the shop', () {
      final d = parse(
        'got a refund of 500 from Amazon',
        cards: [card('a', 'Axis Atlas Credit Card')],
      ).single;
      expect(d.type, VoiceActionType.refund);
      expect(d.amount, 500);
      expect(d.merchant, 'Amazon');
      expect(d.categoryId, 'online-id');
    });

    test('an unclear kind keeps the other reading one tap away', () {
      final d = parse('got 500 from amazon').single;
      expect(d.type, VoiceActionType.moneyIn);
      expect(d.alternatives.any((a) => a.role == 'kind'), isTrue);
      expect(
        d.alternatives.firstWhere((a) => a.role == 'kind').type,
        VoiceActionType.refund,
      );
    });
  });

  group('foreign money', () {
    test('keeps the foreign amount and asks for rupees', () {
      final d = parse('spent 50 dollars in Dubai').single;
      expect(d.type, VoiceActionType.expense);
      expect(d.amount, isNull);
      expect(d.foreignCurrency, 'USD');
      expect(d.foreignAmount, 50);
      expect(d.issues.join(' '), contains('rupee amount'));
      expect(d.canSave, isFalse);
    });
  });

  group('recognized but not logged', () {
    test('a card bill payment', () {
      final d = parse('paid my credit card bill of 12000').single;
      expect(d.type, VoiceActionType.unsupported);
      expect(d.notice, VoiceNotice.cardBillPayment);
      expect(d.canSave, isFalse);
    });

    test('a transfer', () {
      final d = parse('transferred 5000 to my savings account').single;
      expect(d.notice, VoiceNotice.transfer);
    });

    test('a question', () {
      final d = parse('how much did I spend on dining this month').single;
      expect(d.type, VoiceActionType.question);
      expect(d.canSave, isFalse);
    });

    test('noise is not an entry', () {
      final d = parse('the weather is lovely').single;
      expect(d.notice, VoiceNotice.nothingFound);
    });

    test('silence', () {
      expect(parse('').single.notice, VoiceNotice.nothingHeard);
    });
  });

  group('several entries', () {
    test('each keeps its own merchant, category and kind', () {
      final d = parse('250 for lunch, 300 for fuel and 150 for chai');
      expect(d.map((x) => x.amount), [250, 300, 150]);
      expect(d.map((x) => x.categoryId), ['dining-id', 'fuel-id', 'dining-id']);
    });

    test('a date said once is on every entry', () {
      final d = parse('yesterday i spent 250 on lunch and 300 on fuel');
      expect(d.map((x) => x.occurredAt), [
        DateTime(2026, 11, 10, 12),
        DateTime(2026, 11, 10, 12),
      ]);
    });
  });
}
