import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart' show UserCard;
import 'package:pandapay/features/voice/voice_draft_editor.dart';

void main() {
  group('voicePointsAvailable', () {
    test('is the figure the card screen shows, not the ledger plus the credits', () {
      // 1,000 estimated points on the screen; the bank also credited 2,500, which
      // the server keeps out of totalPointsEarned (it is returned apart).
      const card = UserCard(
        id: 'c1',
        cardProductId: 'p1',
        cardName: 'Test Card',
        isDefault: false,
        totalPointsEarned: 1000,
        creditedPoints: 2500,
        pointsBalance: 0,
      );
      expect(voicePointsAvailable(card), 1000);
    });

    test('a card with nothing earned has nothing to redeem', () {
      const card = UserCard(
        id: 'c2',
        cardProductId: 'p2',
        cardName: 'Test Card',
        isDefault: false,
      );
      expect(voicePointsAvailable(card), 0);
    });
  });

  test('the voice sheet no longer folds the points ledger itself', () {
    // Folding every ledger row counted the bank credits the card screen leaves
    // out, so a redemption was checked and corrected against a different number.
    final source = File('lib/features/voice/voice_input_sheet.dart').readAsStringSync();
    expect(source, contains('voicePointsAvailable('));
    expect(source, isNot(contains('fetchPointsLedger')));
    expect(source, isNot(contains('row.deltaPoints')));
  });
}
