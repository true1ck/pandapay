import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/features/voice/understanding/understanding.dart';
import '../../../../lib/features/voice/understanding/utterance_reader.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);
const reader = UtteranceReader();

Understanding read(String text) => reader.read(text, now);

List<double?> amounts(String text) => [
  for (final e in read(text).entries) e.amount?.value,
];

void main() {
  group('one amount, found by evidence not by pattern', () {
    const cases = <String, double>{
      'spent 250 on groceries': 250,
      'spent ₹1,250 at Reliance Fresh': 1250,
      'paid 2,50,000 rupees for rent': 250000,
      'spent 1.5k on groceries': 1500,
      'spent 2k on fuel': 2000,
      'spent 10k on a phone': 10000,
      'spent two fifty on lunch': 250,
      'spent two hundred and fifty rupees on lunch': 250,
      'spent fifteen hundred on petrol': 1500,
      'spent one thousand two hundred on dinner': 1200,
      'spent two lakh on a laptop': 200000,
      'spent 2.5 lakh on a car down payment': 250000,
      'bought coffee for 180': 180,
      'chai 20 rupees': 20,
      'Uber 340': 340,
      '250 for lunch': 250,
      'lunch was 250': 250,
      'spent 99.50 on coffee': 99.5,
      'paid Rs. 250 for parking': 250,
      'paid 250 bucks for parking': 250,
      'spent fifty rupees on parking': 50,
      'spent fifteen rupees on parking': 15,
      'spent on 2 coffees 300': 300,
      'two coffees for 300': 300,
      'on the 3rd I spent 500 on fuel': 500,
      'spent 500 on 3 coffees': 500,
      'paid 2500 for 10 kg rice': 2500,
      'spent 600 on lunch for 4 people': 600,
      'party of 5 cost 3000': 3000,
      'spent 250 at 5 star hotel': 250,
      'spent 250 on groceries at 11 pm': 250,
      'paid 500 to account 123456789012': 500,
      'add spending of 500': 500,
      'i used my tata neu card to book a new uber for ₹1,250': 1250,
    };
    cases.forEach((text, value) {
      test('"$text"', () {
        final u = read(text);
        expect(u.type, UtteranceType.entries);
        expect(u.entries, hasLength(1), reason: u.entries.toString());
        expect(u.entries.single.amount?.value, closeTo(value, 0.001));
      });
    });
  });

  group('several entries in one breath', () {
    test('two spends joined by "and"', () {
      expect(amounts('spent 600 on lunch and 400 on a taxi'), [600, 400]);
    });

    test('a list with commas and "and"', () {
      expect(amounts('250 for lunch, 300 for fuel and 150 for chai'), [
        250,
        300,
        150,
      ]);
    });

    test('a second verb starts a new entry', () {
      expect(
        amounts(
          'I spent ₹100 on chocolates and then paid 250 rupees for groceries',
        ),
        [100, 250],
      );
    });

    test('spoken numbers in a list', () {
      expect(
        amounts('spent two hundred on lunch and three hundred on a taxi'),
        [200, 300],
      );
    });

    test('names first, then amounts', () {
      expect(amounts('lunch 250 fuel 300'), [250, 300]);
    });

    test('amounts first, then names', () {
      expect(amounts('250 lunch 300 fuel'), [250, 300]);
    });

    test('words stay with their own amount', () {
      final e = read(
        'spent 100 on chocolates and then paid 250 rupees for groceries',
      ).entries;
      expect(e[0].cleanText, contains('chocolates'));
      expect(e[0].cleanText, isNot(contains('groceries')));
      expect(e[1].cleanText, contains('groceries'));
    });
  });

  group('spoken self-correction', () {
    test('"no sorry" replaces the amount just said', () {
      final e = read('spent 200 no sorry 250 on lunch').entries;
      expect(e, hasLength(1));
      expect(e.single.amount!.value, 250);
      expect(e.single.amount!.correctedFrom, 200);
      expect(e.single.cleanText, contains('lunch'));
    });

    test('correction inside a list changes only the last item', () {
      final e = read(
        'spent 600 on lunch and 400 on a taxi no sorry 450',
      ).entries;
      expect(e.map((x) => x.amount!.value), [600, 450]);
    });

    test('"make that" works', () {
      final e = read('paid 300 for fuel make that 350').entries;
      expect(e.single.amount!.value, 350);
    });

    test('"not X but Y" works', () {
      final e = read('spent not 200 but 250 on lunch').entries;
      expect(e.single.amount!.value, 250);
    });

    test('"actually" as a new item is not a correction', () {
      final e = read('spent 250 on lunch and actually 300 on fuel').entries;
      expect(e.map((x) => x.amount!.value), [250, 300]);
    });
  });

  group('quantities and other numbers are accounted for', () {
    test('a quantity is not an amount and is reported', () {
      final e = read('spent on 2 coffees 300').entries.single;
      expect(e.amount!.value, 300);
      expect(e.quantities, ['2 coffees']);
    });

    test('a reference number is reported as a leftover', () {
      final e = read('paid 500 to account 123456789012').entries.single;
      expect(e.amount!.value, 500);
      expect(e.leftovers.single.value, 123456789012);
    });

    test('card digits are not amounts', () {
      final e = read('spent 500 on my card ending 4567').entries.single;
      expect(e.amount!.value, 500);
      expect(e.cardDigits, '4567');
    });

    test('card digits can be spoken one by one', () {
      final e = read(
        'spent 500 on my card ending four five six seven',
      ).entries.single;
      expect(e.amount!.value, 500);
      expect(e.cardDigits, '4567');
    });

    test('points are not rupees', () {
      final e = read('redeemed 5000 points on my amex').entries.single;
      expect(e.kind, EntryKind.pointsRedemption);
      expect(e.points, 5000);
      expect(e.amount, isNull);
    });

    test('a spend and a points redemption in one breath', () {
      final e = read('paid 500 for lunch and used 300 points').entries;
      expect(e, hasLength(2));
      expect(e[0].amount!.value, 500);
      expect(e[1].points, 300);
    });

    test('a lone small number is a weak guess, flagged', () {
      final e = read('bought a coffee 5').entries.single;
      expect(e.amount?.value, 5);
    });

    test('two readings of "two fifty" are both kept', () {
      final a = read('spent two fifty on lunch').entries.single.amount!;
      expect(a.value, 250);
      expect(a.alternative, 2.5);
      expect(a.source, 'two fifty');
    });
  });

  group('dates', () {
    test('a date is found and removed from the words', () {
      final e = read('spent 250 on lunch yesterday').entries.single;
      expect(e.date!.from, DateTime(2026, 11, 10));
      expect(e.dateSource, 'yesterday');
      expect(e.cleanText, isNot(contains('yesterday')));
    });

    test('a date said first covers every entry', () {
      final e = read(
        'yesterday i spent 250 on lunch and 300 on fuel',
      ).entries;
      expect(e.map((x) => x.date?.from), [
        DateTime(2026, 11, 10),
        DateTime(2026, 11, 10),
      ]);
    });

    test('a date said last covers every entry', () {
      final e = read('250 for lunch and 300 for fuel yesterday').entries;
      expect(e.map((x) => x.date?.from), [
        DateTime(2026, 11, 10),
        DateTime(2026, 11, 10),
      ]);
    });

    test('a date in the middle belongs to its own entry', () {
      final e = read(
        'spent 250 on lunch yesterday and 300 on fuel',
      ).entries;
      expect(e[0].date?.from, DateTime(2026, 11, 10));
      expect(e[1].date, isNull);
    });

    test('a stretch of days is flagged as vague', () {
      final e = read('spent 500 on fuel last week').entries.single;
      expect(e.dateVague, isTrue);
    });

    test('a date still ahead is flagged as future', () {
      final e = read('spent 500 on fuel on 25 november').entries.single;
      expect(e.dateFuture, isTrue);
    });

    test('an ordinal in "3rd class" is not a date', () {
      final e = read('paid 250 for a 3rd class ticket').entries.single;
      expect(e.date, isNull);
    });
  });

  group('what kind of entry', () {
    EntryKind kindOf(String text) => read(text).entries.first.kind;

    test('spends', () {
      expect(kindOf('spent 250 on lunch'), EntryKind.spend);
      expect(kindOf('lunch 250'), EntryKind.spend);
    });

    test('money in', () {
      expect(kindOf('received 5000 from Rahul'), EntryKind.moneyIn);
      expect(kindOf('salary credited 50000'), EntryKind.moneyIn);
      expect(kindOf('Rahul paid me 800'), EntryKind.moneyIn);
    });

    test('refunds', () {
      expect(kindOf('got a refund of 500 from Amazon'), EntryKind.refund);
      expect(kindOf('refund 500 from flipkart'), EntryKind.refund);
    });

    test('"got 500 from amazon" is ambiguous, not guessed', () {
      final e = read('got 500 from amazon').entries.single;
      expect(e.kind, EntryKind.moneyIn);
      expect(e.kindAlternative, EntryKind.refund);
    });

    test('transfers and card bills are recognized, not logged', () {
      expect(
        kindOf('transferred 5000 to my savings account'),
        EntryKind.transfer,
      );
      expect(kindOf('paid my credit card bill of 12000'), EntryKind.billPayment);
      expect(kindOf('paid the HDFC card statement 8000'), EntryKind.billPayment);
    });

    test('a utility bill is a normal spend', () {
      expect(kindOf('paid electricity bill 1200'), EntryKind.spend);
    });

    test('a later entry inherits the kind of the earlier one', () {
      final e = read('received 5000 from Rahul and 300 from Priya').entries;
      expect(e.map((x) => x.kind), [EntryKind.moneyIn, EntryKind.moneyIn]);
    });

    test('foreign money keeps its currency', () {
      final a = read('spent 50 dollars in Dubai').entries.single.amount!;
      expect(a.value, 50);
      expect(a.currencyCode, 'USD');
      final b = read('paid 30 euros for a museum ticket').entries.single.amount!;
      expect(b.currencyCode, 'EUR');
      final c = read(r'spent $12 on coffee').entries.single.amount!;
      expect(c.currencyCode, 'USD');
    });

    test('rupees are not foreign', () {
      expect(
        read('spent ₹250 on lunch').entries.single.amount!.currencyCode,
        isNull,
      );
    });
  });

  group('not an entry', () {
    test('questions', () {
      for (final q in [
        'how much did I spend on dining this month',
        'when is my HDFC bill due',
        'which card should I use for 4500 at Croma',
        'what did I spend on swiggy last month',
        'show me my spending this week',
      ]) {
        expect(read(q).type, UtteranceType.question, reason: q);
      }
    });

    test('adding a card', () {
      for (final q in [
        'add a new credit card',
        'Add my new debit card to the wallet',
        'link my hdfc card',
        'apply for a credit card',
      ]) {
        expect(read(q).type, UtteranceType.addCard, reason: q);
      }
    });

    test('logging on a card is not adding a card', () {
      expect(
        read('add spending of 500 on my credit card').type,
        UtteranceType.entries,
      );
      expect(
        read('add 250 for lunch on my hdfc card').type,
        UtteranceType.entries,
      );
    });

    test('nothing at all', () {
      expect(read('').type, UtteranceType.empty);
      expect(read('   ').type, UtteranceType.empty);
    });

    test('noise has no signal', () {
      final u = read('the weather is lovely');
      expect(u.hasSignal, isFalse);
      expect(u.entries.single.amount, isNull);
    });
  });

  group('word order and filler do not matter', () {
    const same = [
      'spent 250 on groceries yesterday',
      'yesterday spent 250 on groceries',
      'um yesterday i uh spent like 250 rupees on groceries',
      'groceries yesterday 250 spent',
    ];
    for (final text in same) {
      test('"$text"', () {
        final e = read(text).entries.single;
        expect(e.amount!.value, 250);
        expect(e.date!.from, DateTime(2026, 11, 10));
        expect(e.cleanText.toLowerCase(), contains('groceries'));
      });
    }
  });
}
