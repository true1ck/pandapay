import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  test('deduplicates identical cap definitions but keeps separate reward rules', () {
    final duplicate = CapRule(
      id: 'duplicate',
      rewardRuleId: null,
      categoryId: 'dining',
      label: 'bonus_reward_points cap',
      capValue: Money.fromRupees(2000),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
    );
    final sameDefinition = CapRule(
      id: 'same-definition',
      rewardRuleId: null,
      categoryId: 'dining',
      label: 'bonus_reward_points cap',
      capValue: Money.fromRupees(2000),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
    );
    final separateRewardRule = CapRule(
      id: 'separate-reward-rule',
      rewardRuleId: 'other-rule',
      categoryId: 'dining',
      label: 'bonus_reward_points cap',
      capValue: Money.fromRupees(2000),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
    );

    expect(uniqueCapRules([duplicate, sameDefinition, separateRewardRule]), [
      duplicate,
      separateRewardRule,
    ]);
  });

  test('cap labels identify their category instead of exposing catalogue keys', () {
    final cap = CapRule(
      id: 'cap',
      label: 'bonus_reward_points cap',
      categoryId: 'dining',
      capValue: Money.fromRupees(2000),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
    );

    expect(
      capRuleDisplayLabel(cap, categoryName: 'Dining'),
      'Dining rewards cap',
    );
    expect(capRuleDisplayLabel(cap), 'Bonus reward points cap');
  });

  test('benefits and reward rules use semantic identity, not generated ids', () {
    final benefit = CardBenefit(
      id: 'benefit-1',
      kind: BenefitKind.other,
      label: 'Insurance cover',
      description: 'Protection',
    );
    final duplicateBenefit = CardBenefit(
      id: 'benefit-2',
      kind: BenefitKind.other,
      label: ' insurance cover ',
      description: 'Protection',
    );
    expect(uniqueCardBenefits([benefit, duplicateBenefit]), [benefit]);

    final rule = RewardRule(
      id: 'rule-1',
      categoryId: 'dining',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
    );
    final duplicateRule = RewardRule(
      id: 'rule-2',
      categoryId: 'dining',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
    );
    expect(uniqueRewardRules([rule, duplicateRule]), [rule]);
  });
}
