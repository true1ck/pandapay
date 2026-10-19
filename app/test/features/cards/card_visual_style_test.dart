import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/cards/card_visual.dart';

CardProduct _card({
  required String id,
  required String name,
  required String issuer,
  CardNetwork network = CardNetwork.visa,
  String cardType = 'credit',
}) => CardProduct(
  id: id,
  name: name,
  issuerName: issuer,
  network: network,
  cardType: cardType,
);

void main() {
  test('same issuer products receive different stable visual identities', () {
    final moneyBack = _card(
      id: 'hdfc-moneyback',
      name: 'MoneyBack+ Credit Card',
      issuer: 'HDFC Bank',
    );
    final tataNeu = _card(
      id: 'hdfc-tata-neu-plus',
      name: 'Tata Neu Plus HDFC Bank Credit Card',
      issuer: 'HDFC Bank',
      network: CardNetwork.rupay,
    );

    final first = cardVisualSpecFor(moneyBack);
    final second = cardVisualSpecFor(tataNeu);

    expect('${first.family}:${first.skin}', isNot('${second.family}:${second.skin}'));
    expect(first.primary, isNot(second.primary));
  });

  test('visual identity is deterministic for every product', () {
    final cards = [
      _card(id: 'axis-ace', name: 'Axis Bank ACE', issuer: 'Axis Bank'),
      _card(
        id: 'amazon-pay',
        name: 'Amazon Pay ICICI Credit Card',
        issuer: 'ICICI Bank',
      ),
      _card(
        id: 'sbi-debit',
        name: 'SBI Classic Debit Card',
        issuer: 'State Bank of India',
        cardType: 'debit',
      ),
      _card(
        id: 'premium-metal',
        name: 'OneCard Metal',
        issuer: 'Federal Bank',
        network: CardNetwork.mastercard,
      ),
    ];

    for (final card in cards) {
      final first = cardVisualSpecFor(card);
      final second = cardVisualSpecFor(card);
      expect(first.family, second.family);
      expect(first.skin, second.skin);
      expect(first.primary, second.primary);
      expect(first.secondary, second.secondary);
      expect(first.primary, isA<Color>());
      expect(first.secondary, isA<Color>());
    }
  });
}
