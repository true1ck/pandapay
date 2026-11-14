import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_expense_summary.dart';

Map<String, Object?> _snap(Map<String, int> paid, Map<String, int> share) => {
  'contributions': [
    for (final e in paid.entries)
      {'memberId': e.key, 'amountMinor': '${e.value}'},
  ],
  'shares': [
    for (final e in share.entries)
      {'memberId': e.key, 'amountMinor': '${e.value}'},
  ],
};

const _names = {'me': 'You', 'ravi': 'Ravi', 'sam': 'Sam'};

void main() {
  test('a friend paid: you owe them your share, by name', () {
    final s = SharedExpenseSummary.from(
      _snap({'ravi': 100000}, {'me': 50000, 'ravi': 50000}),
      _names,
      'me',
    )!;
    expect(s.paidSentence, 'Ravi paid ₹1,000.00');
    expect(s.splitWords, 'split equally');
    expect(s.position, SharedYourPosition.owes);
    expect(s.yourAmountMinor, 50000);
    expect(s.yourSentence, 'You owe Ravi ₹500.00');
    expect(s.people.first.isYou, isTrue, reason: 'you come first');
    expect(s.people.map((p) => p.name), ['You', 'Ravi']);
  });

  test('you paid and one friend owes you: named; several: just the amount', () {
    final one = SharedExpenseSummary.from(
      _snap({'me': 120000}, {'me': 60000, 'ravi': 60000}),
      _names,
      'me',
    )!;
    expect(one.paidSentence, 'You paid ₹1,200.00');
    expect(one.yourSentence, 'Ravi owes you ₹600.00');
    final many = SharedExpenseSummary.from(
      _snap({'me': 90000}, {'me': 30000, 'ravi': 30000, 'sam': 30000}),
      _names,
      'me',
    )!;
    expect(many.position, SharedYourPosition.owed);
    expect(many.yourSentence, 'You get back ₹600.00');
  });

  test('two payers and an unequal split are said plainly', () {
    final s = SharedExpenseSummary.from(
      _snap({'me': 40000, 'ravi': 60000}, {'me': 70000, 'ravi': 30000}),
      _names,
      'me',
    )!;
    expect(s.paidSentence, '2 people paid ₹1,000.00');
    expect(s.splitWords, 'split unequally');
    expect(s.yourSentence, 'You owe Ravi ₹300.00');
  });

  test('a split into thirds that differs by a paisa is still equal', () {
    final s = SharedExpenseSummary.from(
      _snap({'ravi': 100000}, {'me': 33333, 'ravi': 33333, 'sam': 33334}),
      _names,
      'me',
    )!;
    expect(s.splitEqually, isTrue);
  });

  test(
    'paying exactly your share, and not being in it, have their own words',
    () {
      final even = SharedExpenseSummary.from(
        _snap({'me': 50000, 'ravi': 50000}, {'me': 50000, 'ravi': 50000}),
        _names,
        'me',
      )!;
      expect(even.position, SharedYourPosition.even);
      expect(even.yourSentence, 'You paid your own share');
      final out = SharedExpenseSummary.from(
        _snap({'ravi': 50000}, {'ravi': 25000, 'sam': 25000}),
        _names,
        'me',
      )!;
      expect(out.position, SharedYourPosition.notIn);
      expect(out.yourSentence, "You're not part of this expense");
    },
  );

  test('a member nobody can name is a former member, never blank', () {
    final s = SharedExpenseSummary.from(
      _snap({'ghost': 100000}, {'me': 50000, 'ghost': 50000}),
      _names,
      'me',
    )!;
    expect(s.paidSentence, 'Former member paid ₹1,000.00');
  });

  test('no snapshot, no summary', () {
    expect(SharedExpenseSummary.from(null, _names, 'me'), isNull);
    expect(
      SharedExpenseSummary.from({'contributions': 1}, _names, 'me'),
      isNull,
    );
  });
}
