import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_overrides_repository.dart';

void main() {
  test('CardOverride toJson -> fromJson round-trips every field', () {
    final original = CardOverride(
      id: 'ov1',
      userCardId: 'uc1',
      scope: OverrideScope.merchantName,
      merchantName: 'Starbucks',
      reasonNote: 'Best cashback there',
      isEnabled: true,
      createdAt: DateTime.utc(2026, 1, 1),
      cardName: 'Test Card',
      cardNickname: 'My Card',
    );

    final roundTripped = CardOverride.fromJson(original.toJson());

    expect(roundTripped.id, 'ov1');
    expect(roundTripped.userCardId, 'uc1');
    expect(roundTripped.scope, OverrideScope.merchantName);
    expect(roundTripped.merchantName, 'Starbucks');
    expect(roundTripped.vpa, isNull);
    expect(roundTripped.reasonNote, 'Best cashback there');
    expect(roundTripped.isEnabled, true);
    expect(roundTripped.createdAt, DateTime.utc(2026, 1, 1));
    expect(roundTripped.cardName, 'Test Card');
    expect(roundTripped.cardNickname, 'My Card');
  });

  test('CardOverride toJson -> fromJson round-trips a vpa-scoped rule', () {
    final original = CardOverride(
      id: 'ov2',
      userCardId: 'uc2',
      scope: OverrideScope.vpa,
      vpa: 'merchant@upi',
      isEnabled: false,
      createdAt: DateTime.utc(2026, 2, 1),
      cardName: 'Another Card',
    );

    final roundTripped = CardOverride.fromJson(original.toJson());

    expect(roundTripped.scope, OverrideScope.vpa);
    expect(roundTripped.vpa, 'merchant@upi');
    expect(roundTripped.isEnabled, false);
    expect(roundTripped.cardNickname, isNull);
  });
}
