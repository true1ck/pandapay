import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/spending_selection.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry expense(String id, {String? child}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(100),
  occurredAt: DateTime(2026, 10, 20),
  categoryId: child == null ? 'food' : 'custom:$child',
  userCategoryId: child,
  parentCategoryId: child == null ? null : 'food',
  categoryName: 'Food',
  subcategoryName: child == null ? null : 'Lunch',
  merchantName: ' AMAZON  India ',
  cardDisplayName: 'Travel card',
  instrument: TxnInstrument.creditCard,
  source: 'manual',
  status: 'active',
);

void main() {
  test('tag union counts each row once while combining other dimensions', () {
    const selection = SpendingSelection(
      categories: {'food'},
      tagIds: {'trip', 'office'},
      merchant: 'amazon india',
      card: 'Travel card',
      payment: TxnInstrument.creditCard,
    );
    final entries = [
      expense('both', child: 'lunch'),
      expense('trip'),
      expense('none'),
    ];
    final tags = {
      'both': ['trip', 'office'],
      'trip': ['trip'],
      'none': <String>[],
    };
    final matching = entries
        .where((e) => selection.matches(e, tags: tags[e.id]!))
        .toList();
    expect(matching.map((e) => e.id), ['both', 'trip']);
    expect(matching.fold<int>(0, (sum, e) => sum + e.amount.paise), 20000);
    expect(
      const SpendingSelection(
        categories: {'fuel'},
        tagIds: {'trip'},
      ).matches(entries.first, tags: ['trip', 'office']),
      isFalse,
    );
  });

  test(
    'parent includes children while a child selects only that subcategory',
    () {
      final child = expense('one', child: 'lunch');
      final sibling = expense('two', child: 'dinner');
      expect(
        const SpendingSelection(categories: {'food'}).matches(child),
        isTrue,
      );
      expect(
        const SpendingSelection(categories: {'custom:lunch'}).matches(child),
        isTrue,
      );
      expect(
        const SpendingSelection(categories: {'custom:lunch'}).matches(sibling),
        isFalse,
      );
    },
  );

  test('untagged includes categorized transactions with no tags', () {
    const selection = SpendingSelection(untagged: true);
    expect(selection.matches(expense('one'), tags: []), isTrue);
    expect(selection.matches(expense('two'), tags: ['office']), isFalse);
  });

  test('unknown instrument is not treated as a credit card', () {
    final legacy = TransactionEntry(
      id: 'legacy',
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, 20),
      instrument: TxnInstrument.creditCard,
      instrumentKnown: false,
      source: 'sms',
      status: 'active',
    );

    expect(
      const SpendingSelection(
        payment: TxnInstrument.creditCard,
      ).matches(legacy),
      isFalse,
    );
    expect(
      const SpendingSelection(payment: TxnInstrument.other).matches(legacy),
      isTrue,
    );
  });

  test('a masked source account is filterable as an account', () {
    final upi = TransactionEntry(
      id: 'upi',
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, 20),
      accountLast4: '1234',
      userCardId: null,
      cardDisplayName: null,
      instrument: TxnInstrument.upiBank,
      source: 'sms',
      status: 'active',
    );
    const selection = SpendingSelection(card: 'Bank account ••1234');

    expect(SpendingSelection.sourceName(upi), 'Bank account ••1234');
    expect(selection.matches(upi), isTrue);
  });

  test('a bank account and unlinked card with the same suffix stay separate', () {
    final card = TransactionEntry(
      id: 'card',
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, 20),
      cardLast4: '9080',
      instrument: TxnInstrument.creditCard,
      source: 'sms',
      status: 'active',
    );
    final account = TransactionEntry(
      id: 'account',
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, 20),
      accountLast4: '9080',
      instrument: TxnInstrument.upiBank,
      source: 'sms',
      status: 'active',
    );

    const cardName = 'Credit card ••9080 (unlinked)';
    expect(SpendingSelection.sourceName(card), cardName);
    const accountName = 'Bank account ••9080';
    expect(SpendingSelection.sourceName(account), accountName);
    final entries = [card, account];
    const cardSelection = SpendingSelection(card: cardName);
    const accountSelection = SpendingSelection(card: accountName);
    expect(
      entries.where(cardSelection.matches).map((entry) => entry.id),
      ['card'],
    );
    expect(
      entries.where(accountSelection.matches).map((entry) => entry.id),
      ['account'],
    );
    expect(
      const SpendingSelection(
        card: cardName,
        payment: TxnInstrument.creditCard,
      ).matches(account),
      isFalse,
    );
    expect(
      const SpendingSelection(
        card: accountName,
        payment: TxnInstrument.upiBank,
      ).matches(account),
      isTrue,
    );
  });
}
