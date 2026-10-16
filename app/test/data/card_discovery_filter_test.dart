import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_discovery_filter.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  const catalogue = [
    CardProduct(
      id: 'moneyback',
      name: 'MoneyBack+ Credit Card',
      issuerName: 'HDFC Bank',
      cardType: 'credit',
      network: CardNetwork.visa,
    ),
    CardProduct(
      id: 'hdfc-debit',
      name: 'HDFC Bank Debit Card',
      issuerName: 'HDFC Bank',
      cardType: 'debit',
      network: CardNetwork.visa,
    ),
  ];

  UserCard owned({String product = 'moneyback', String? last4 = '8708'}) =>
      UserCard(
        id: 'user-$product',
        cardProductId: product,
        cardName: product,
        cardType: product == 'hdfc-debit' ? 'debit' : 'credit',
        isDefault: false,
        last4: last4,
      );

  DiscoveredCard suggestion({
    String product = 'placeholder_hdfc',
    String name = 'HDFC Bank Card ending 8708',
    String issuer = 'HDFC Bank',
    String type = 'credit',
    List<String> last4 = const ['8708'],
  }) => DiscoveredCard(
    cardProductId: product,
    name: name,
    score: 0.2,
    evidence: const ['SMS'],
    last4: last4,
    messageCount: 1,
    sources: const ['sms'],
    isPlaceholder: true,
    issuerName: issuer,
    cardType: type,
  );

  test('marks the named issuer/suffix candidate already owned by wallet', () {
    final result = filterOwnedCardSuggestions(
      suggestions: [suggestion()],
      ownedCards: [owned()],
      catalogue: catalogue,
    );

    expect(result, hasLength(1));
    expect(result.single.isAlreadyOwned, isTrue);
    expect(result.single.name, 'moneyback');
  });

  test('keeps a different card type with the same issuer and suffix', () {
    final result = filterOwnedCardSuggestions(
      suggestions: [suggestion(type: 'debit')],
      ownedCards: [owned()],
      catalogue: catalogue,
    );

    expect(result, hasLength(1));
  });

  test('keeps a different suffix and a different issuer', () {
    final result = filterOwnedCardSuggestions(
      suggestions: [
        suggestion(last4: const ['9080']),
        suggestion(issuer: 'Axis Bank'),
      ],
      ownedCards: [owned()],
      catalogue: catalogue,
    );

    expect(result, hasLength(2));
  });

  test('keeps an issuer-less suffix because its issuer is unknown', () {
    final result = filterOwnedCardSuggestions(
      suggestions: [suggestion(issuer: '')],
      ownedCards: [owned()],
      catalogue: catalogue,
    );

    expect(result, hasLength(1));
  });

  test(
    'drops an issuer-less duplicate when an owned issuer match is present',
    () {
      final result = filterOwnedCardSuggestions(
        suggestions: [
          suggestion(),
          suggestion(
            product: 'placeholder_generic',
            issuer: '',
            name: 'Credit card ending 8708',
          ),
        ],
        ownedCards: [owned()],
        catalogue: catalogue,
      );

      expect(result, hasLength(1));
      expect(result.single.isAlreadyOwned, isTrue);
      expect(result.single.name, 'moneyback');
    },
  );

  test('marks an exact catalogue product already owned without a suffix', () {
    final result = filterOwnedCardSuggestions(
      suggestions: [suggestion(product: 'moneyback', last4: const [])],
      ownedCards: [owned(last4: null)],
      catalogue: catalogue,
    );

    expect(result, hasLength(1));
    expect(result.single.isAlreadyOwned, isTrue);
  });

  test('keeps an already-owned Flipkart Axis match visible as added', () {
    const flipkart = CardProduct(
      id: 'axis-flipkart',
      name: 'Flipkart Axis Bank Credit Card',
      issuerName: 'Axis Bank',
      cardType: 'credit',
      network: CardNetwork.mastercard,
    );
    final result = filterOwnedCardSuggestions(
      suggestions: [
        DiscoveredCard(
          cardProductId: 'axis-flipkart',
          name: 'Flipkart Axis Bank Credit Card',
          score: 2,
          evidence: const ['Flipkart Axis Bank Credit Card'],
          last4: const ['7105'],
          messageCount: 1,
          sources: const ['sms'],
          issuerName: 'Axis Bank',
          cardType: 'credit',
        ),
      ],
      ownedCards: [
        UserCard(
          id: 'user-axis-flipkart',
          cardProductId: 'axis-flipkart',
          cardName: 'Flipkart Axis Bank Credit Card',
          cardType: 'credit',
          isDefault: false,
          last4: '7105',
        ),
      ],
      catalogue: [flipkart],
    );

    expect(result, hasLength(1));
    expect(result.single.isAlreadyOwned, isTrue);
    expect(result.single.name, 'Flipkart Axis Bank Credit Card');
  });
}
