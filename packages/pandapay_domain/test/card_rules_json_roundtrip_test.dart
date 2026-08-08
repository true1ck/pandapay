import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  test('CardProduct toJson -> jsonEncode -> jsonDecode -> fromJson round-trips every field', () {
    final original = CardProduct(
      id: 'p1',
      name: 'Axis Ace',
      network: CardNetwork.rupay,
      isUpiLinkable: true,
      pointValueInr: 0.25,
      rewardRules: [
        RewardRule(
          id: 'r1',
          categoryId: 'c1',
          rail: TxnRail.upiQr,
          unit: RewardUnit.cashbackPercent,
          rate: 5,
          minTxn: Money.fromRupees(100),
          maxTxn: Money.fromRupees(10000),
          priority: 10,
        ),
      ],
      capRules: [
        CapRule(
          id: 'cap1',
          rewardRuleId: 'r1',
          label: 'Monthly cap',
          capValue: Money.fromRupees(500),
          measure: CapMeasure.spendAmount,
          postCapUnit: RewardUnit.cashbackPercent,
          postCapRate: 1,
          period: CapPeriod.calendarMonth,
        ),
      ],
      milestoneRules: [
        MilestoneRule(
          id: 'm1',
          label: 'Spend 1L',
          thresholdSpend: Money.fromRupees(100000),
          rewardValue: Money.fromRupees(1000),
          isRepeatable: true,
        ),
      ],
      forexRule: const ForexRule(markupPercent: 3.5, gstOnMarkup: true),
      fuelRule: FuelSurchargeRule(
        surchargePercent: 1,
        waiverPercent: 1,
        minTxn: Money.fromRupees(400),
        maxTxn: Money.fromRupees(4000),
      ),
      feeWaiverRules: [
        FeeWaiverRule(
          id: 'fw1',
          thresholdSpend: Money.fromRupees(250000),
          period: CapPeriod.annual,
          waivesFee: Money.fromRupees(499),
          excludedCategoryIds: const ['cat-fuel'],
          notes: 'Excludes fuel',
        ),
      ],
      benefits: [
        CardBenefit(
          id: 'b1',
          kind: BenefitKind.loungeDomestic,
          label: '8 visits',
          description: 'Domestic lounge access',
          quotaCount: 8,
          quotaPeriod: CapPeriod.annual,
          networkProgram: 'Visa Signature',
          valueEstimate: Money.fromRupees(2000),
        ),
      ],
      annualFeeInr: Money.fromRupees(499),
      joiningFeeInr: Money.fromRupees(499),
      verifiedAt: DateTime.utc(2026, 1, 1),
      issuerName: 'Axis Bank',
      artAssetUrl: 'https://example.com/art.png',
      artPrimaryColor: '#FF0000',
    );

    final roundTripped = CardProductJson.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );

    expect(roundTripped.id, original.id);
    expect(roundTripped.name, original.name);
    expect(roundTripped.network, original.network);
    expect(roundTripped.isUpiLinkable, original.isUpiLinkable);
    expect(roundTripped.pointValueInr, original.pointValueInr);

    expect(roundTripped.rewardRules.single.categoryId, 'c1');
    expect(roundTripped.rewardRules.single.rail, TxnRail.upiQr);
    expect(roundTripped.rewardRules.single.unit, RewardUnit.cashbackPercent);
    expect(roundTripped.rewardRules.single.rate, 5);
    expect(roundTripped.rewardRules.single.minTxn!.paise, Money.fromRupees(100).paise);
    expect(roundTripped.rewardRules.single.priority, 10);

    expect(roundTripped.capRules.single.rewardRuleId, 'r1');
    expect(roundTripped.capRules.single.capValue.paise, Money.fromRupees(500).paise);
    expect(roundTripped.capRules.single.measure, CapMeasure.spendAmount);
    expect(roundTripped.capRules.single.postCapUnit, RewardUnit.cashbackPercent);
    expect(roundTripped.capRules.single.period, CapPeriod.calendarMonth);

    expect(roundTripped.milestoneRules.single.thresholdSpend.paise, Money.fromRupees(100000).paise);
    expect(roundTripped.milestoneRules.single.isRepeatable, true);

    expect(roundTripped.forexRule!.markupPercent, 3.5);
    expect(roundTripped.fuelRule!.surchargePercent, 1);

    expect(roundTripped.feeWaiverRules.single.period, CapPeriod.annual);
    expect(roundTripped.feeWaiverRules.single.excludedCategoryIds, ['cat-fuel']);

    expect(roundTripped.benefits.single.kind, BenefitKind.loungeDomestic);
    expect(roundTripped.benefits.single.quotaPeriod, CapPeriod.annual);
    expect(roundTripped.benefits.single.valueEstimate!.paise, Money.fromRupees(2000).paise);

    expect(roundTripped.annualFeeInr!.paise, Money.fromRupees(499).paise);
    expect(roundTripped.verifiedAt, DateTime.utc(2026, 1, 1));
    expect(roundTripped.issuerName, 'Axis Bank');
    expect(roundTripped.artPrimaryColor, '#FF0000');
  });
}
