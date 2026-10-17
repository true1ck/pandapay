import 'package:flutter_test/flutter_test.dart';

import '../../../lib/data/catalogue_repository.dart' show SpendCategory;
import '../../../lib/data/user_cards_repository.dart' show UserCard;
import '../../../lib/features/voice/voice_action_parser.dart';

void main() {
  const categories = [
    SpendCategory(id: 'travel-id', slug: 'travel', name: 'Travel'),
    SpendCategory(id: 'online-id', slug: 'online', name: 'Online'),
  ];

  UserCard card(String id, {String? last4}) => UserCard(
    id: id,
    cardProductId: 'product-$id',
    cardName: 'Tata Neu Plus HDFC Bank Credit Card',
    last4: last4,
    isDefault: false,
  );

  test('parses an expense and resolves the existing wallet card', () {
    final draft = VoiceActionParser.parse(
      'I used my Tata Neu card to book a new Uber from Delhi to Rishikesh for ₹1,250',
      cards: [card('card-1', last4: '9080')],
      categories: categories,
    );

    expect(draft.type, VoiceActionType.expense);
    expect(draft.amount, 1250);
    expect(draft.userCardId, 'card-1');
    expect(draft.merchant, 'Uber');
    expect(draft.categoryId, 'travel-id');
    expect(draft.issues, isEmpty);
  });

  test('prefills an amount from a natural spending phrase', () {
    final draft = VoiceActionParser.parse(
      'add spending of 500',
      cards: [card('card-1')],
      categories: categories,
    );

    expect(draft.type, VoiceActionType.expense);
    expect(draft.amount, 500);
  });

  test('does not guess when duplicate wallet cards match', () {
    final draft = VoiceActionParser.parse(
      'I spent ₹500 on my Tata Neu card',
      cards: [card('card-1'), card('card-2')],
      categories: categories,
    );

    expect(draft.userCardId, isNull);
    expect(
      draft.issues,
      contains('Choose the exact wallet card; more than one card matched.'),
    );
  });

  test('parses a points redemption without creating a spend', () {
    final draft = VoiceActionParser.parse(
      'I used 300 points to buy a bottle on my Tata Neu card',
      cards: [card('card-1')],
      categories: categories,
    );

    expect(draft.type, VoiceActionType.pointsRedemption);
    expect(draft.points, 300);
    expect(draft.userCardId, 'card-1');
  });

  test(
    'recognizes Google Pay and UPI as a bank payment, not a credit card',
    () {
      final draft = VoiceActionParser.parse(
        'I spent 100 rupees on Google Pay using my UPI to buy some chocolates',
        cards: const [],
        categories: categories,
      );

      expect(draft.amount, 100);
      expect(draft.instrument.wireValue, 'upi_bank');
      expect(draft.merchant, 'Chocolates');
      expect(draft.issues, isEmpty);
    },
  );

  test('splits a long dictation into independently editable spends', () {
    final drafts = VoiceActionParser.parseMany(
      'I spent ₹100 on chocolates and then paid 250 rupees for groceries',
      cards: const [],
      categories: categories,
    );

    expect(drafts, hasLength(2));
    expect(drafts[0].amount, 100);
    expect(drafts[1].amount, 250);
    expect(drafts[0].transcript, contains('chocolates'));
    expect(drafts[1].transcript, contains('groceries'));
  });

  test('refuses card creation or linking by voice', () {
    final draft = VoiceActionParser.parse(
      'Add my new debit card to the wallet',
      cards: const [],
      categories: categories,
    );

    expect(draft.type, VoiceActionType.unsupported);
    expect(draft.canSave, isFalse);
  });
}
