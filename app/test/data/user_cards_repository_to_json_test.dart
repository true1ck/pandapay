import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('UserCard toJson -> fromJson round-trips cap/milestone/fee-waiver state', () {
    final original = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      nickname: 'My Card',
      cardName: 'Test Card',
      isDefault: true,
      capConsumed: {'cap1': Money.fromRupees(2000)},
      milestoneQualifiedSpend: {'m1': Money.fromRupees(5000)},
      milestonePeriodEnd: {'m1': DateTime.utc(2026, 6, 30)},
      totalPointsEarned: 1234.5,
      feeWaiverStates: [
        FeeWaiverProgress(
          feeWaiverRuleId: 'fw1',
          qualifiedSpend: Money.fromRupees(1000),
          thresholdSpend: Money.fromRupees(250000),
          waivesFee: Money.fromRupees(499),
          waivedAt: DateTime.utc(2026, 3, 1),
          periodEnd: DateTime.utc(2026, 12, 31),
        ),
      ],
      statementDay: 5,
      openedOn: DateTime.utc(2024, 1, 1),
      creditLimit: Money.fromRupees(300000),
      dueDay: 25,
      anniversaryOn: DateTime.utc(2024, 1, 15),
      isArchived: false,
    );

    final roundTripped = UserCard.fromJson(original.toJson());

    expect(roundTripped.id, 'uc1');
    expect(roundTripped.cardProductId, 'p1');
    expect(roundTripped.nickname, 'My Card');
    expect(roundTripped.isDefault, true);
    expect(roundTripped.capConsumed['cap1']!.paise, Money.fromRupees(2000).paise);
    expect(roundTripped.milestoneQualifiedSpend['m1']!.paise, Money.fromRupees(5000).paise);
    expect(roundTripped.milestonePeriodEnd['m1'], DateTime.utc(2026, 6, 30));
    expect(roundTripped.totalPointsEarned, 1234.5);
    expect(roundTripped.feeWaiverStates.single.feeWaiverRuleId, 'fw1');
    expect(roundTripped.feeWaiverStates.single.waivedAt, DateTime.utc(2026, 3, 1));
    expect(roundTripped.feeWaiverStates.single.periodEnd, DateTime.utc(2026, 12, 31));
    expect(roundTripped.statementDay, 5);
    expect(roundTripped.openedOn, DateTime.utc(2024, 1, 1));
    expect(roundTripped.creditLimit!.paise, Money.fromRupees(300000).paise);
    expect(roundTripped.dueDay, 25);
    expect(roundTripped.anniversaryOn, DateTime.utc(2024, 1, 15));
    expect(roundTripped.isArchived, false);
  });

  test('UserCard toJson -> fromJson round-trips a card with no optional fields set', () {
    final original = UserCard(id: 'uc2', cardProductId: 'p2', cardName: 'Bare Card', isDefault: false);
    final roundTripped = UserCard.fromJson(original.toJson());

    expect(roundTripped.id, 'uc2');
    expect(roundTripped.nickname, isNull);
    expect(roundTripped.capConsumed, isEmpty);
    expect(roundTripped.feeWaiverStates, isEmpty);
    expect(roundTripped.creditLimit, isNull);
  });
}
