import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';

/// Task 11: statement_day/opened_on now come back from GET /user-cards
/// (previously computed server-side for cap/milestone period math but never
/// returned to a client) — Billing Cycle Float needs both.
void main() {
  group('UserCard.fromJson', () {
    test('parses statement_day and opened_on when both are set', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'nickname': null,
        'card_name': 'Test Card',
        'is_default': false,
        'statement_day': 15,
        'opened_on': '2025-03-10',
      });

      expect(card.statementDay, 15);
      expect(card.openedOn, DateTime(2025, 3, 10));
    });

    test('leaves both null when the card has never had them set', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'nickname': null,
        'card_name': 'Test Card',
        'is_default': false,
        'statement_day': null,
        'opened_on': null,
      });

      expect(card.statementDay, isNull);
      expect(card.openedOn, isNull);
    });

    test('defaults both to null when the keys are absent entirely', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'card_name': 'Test Card',
        'is_default': false,
      });

      expect(card.statementDay, isNull);
      expect(card.openedOn, isNull);
    });
  });
}
