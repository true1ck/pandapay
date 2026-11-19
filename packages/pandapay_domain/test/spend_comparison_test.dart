import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// "Would another card in the wallet have paid more on this spend?" priced by
/// the reward engine itself. The cards below are shaped like the live v2
/// catalogue: exclusion rows with no category at priority 0 in front of the
/// earning rules, merchant rows, info rows. The first comparison read those
/// shapes as 0% on every card, so the Missed tab was empty for a wallet with
/// ten cards (see docs/rewards-missed-fix-2026-11-19.md).

final _directory = MerchantDirectory.fromJson({
  'merchants': [
    {
      'slug': 'swiggy',
      'name': 'Swiggy',
      'aliases': ['swiggy'],
      'vpa_prefixes': ['swiggy'],
    },
    {
      'slug': 'amazon',
      'name': 'Amazon',
      'aliases': ['amazon'],
      'vpa_prefixes': ['amazon'],
    },
  ],
});

/// Swiggy HDFC's real shape: 10% on Swiggy (min ₹249), 1% base (min ₹100),
/// nothing under ₹100, nothing on EMI, rent left out. Not UPI-linkable.
CardProduct swiggyCard() => CardProduct(
  id: 'swiggy-card',
  name: 'Swiggy Card',
  network: CardNetwork.visa,
  isUpiLinkable: false,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: [
    RewardRule(
      id: 'x-under-100',
      unit: RewardUnit.cashbackPercent,
      rate: 0,
      priority: 0,
      role: RuleRole.exclusion,
      maxTxn: Money.fromRupees(100),
      minEngineVersion: 2,
    ),
    RewardRule(
      id: 'e-swiggy',
      unit: RewardUnit.cashbackPercent,
      rate: 10,
      priority: 1,
      role: RuleRole.earn,
      merchantSlugs: const ['swiggy'],
      minTxn: Money.fromRupees(249),
      displayNote: '10% cashback on eligible Swiggy app transactions.',
    ),
    RewardRule(
      id: 'b-base',
      unit: RewardUnit.cashbackPercent,
      rate: 1,
      priority: 3,
      role: RuleRole.earn,
      minTxn: Money.fromRupees(100),
    ),
  ],
);

/// A flat 2% v1-shaped card that takes UPI.
CardProduct flatCard({String id = 'flat'}) => CardProduct(
  id: id,
  name: 'Flat Card',
  network: CardNetwork.rupay,
  isUpiLinkable: true,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 2,
  rewardRules: const [
    RewardRule(
      id: 'f1',
      unit: RewardUnit.cashbackPercent,
      rate: 2,
      priority: 200,
    ),
  ],
);

/// A v2 card whose catalogue says "1% everywhere" and nothing about rent.
CardProduct silentCard() => CardProduct(
  id: 'silent',
  name: 'Silent Card',
  network: CardNetwork.visa,
  isUpiLinkable: true,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 3,
  modelStatus: ModelStatus.verified,
  rewardRules: const [
    RewardRule(
      id: 's-base',
      unit: RewardUnit.cashbackPercent,
      rate: 3,
      priority: 100,
      role: RuleRole.base,
      minEngineVersion: 2,
    ),
  ],
);

/// Pays 4% on rent by an explicit rule for that category.
CardProduct rentCard() => CardProduct(
  id: 'rent-card',
  name: 'Rent Card',
  network: CardNetwork.visa,
  isUpiLinkable: true,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: const [
    RewardRule(
      id: 'r-rent',
      categoryId: 'rent',
      unit: RewardUnit.cashbackPercent,
      rate: 4,
      priority: 1,
      role: RuleRole.earn,
      minEngineVersion: 2,
    ),
    RewardRule(
      id: 'r-base',
      unit: RewardUnit.cashbackPercent,
      rate: 1,
      priority: 100,
      role: RuleRole.base,
      minEngineVersion: 2,
    ),
  ],
);

SpendProbe spend(
  double rupees, {
  String merchant = 'SOME SHOP',
  String? categoryId = 'dining',
  String? categorySlug = 'dining',
  TxnRail rail = TxnRail.unknown,
  DateTime? at,
}) => SpendProbe(
  amount: Money.fromRupees(rupees),
  occurredAt: at ?? DateTime(2026, 6, 10),
  categoryId: categoryId,
  categorySlug: categorySlug,
  merchantName: merchant,
  rail: rail,
);

SpendComparer comparer(
  List<CardProduct> products, {
  Map<String, DateTime> usableFrom = const {},
  Money? minimumGain,
}) => SpendComparer(
  wallet: [
    for (final product in products)
      WalletCardOption(product, usableFrom: usableFrom[product.id]),
  ],
  directory: _directory,
  minimumGain: minimumGain ?? const Money.fromPaise(500),
);

void main() {
  final swiggy = swiggyCard();
  final flat = flatCard();

  group('a better card is found', () {
    test('a Swiggy order on the flat card: the Swiggy card pays 10%', () {
      final result = comparer([swiggy, flat]).check(
        flat,
        spend(1000, merchant: 'SWIGGY', categoryId: 'dining'),
      );
      expect(result.compared, isTrue);
      final better = result.better!;
      expect(better.betterCard!.id, 'swiggy-card');
      expect(better.actualValue, Money.fromRupees(20));
      expect(better.betterValue, Money.fromRupees(100));
      expect(better.missedValue, Money.fromRupees(80));
      expect(better.usedRate, closeTo(0.02, 1e-9));
      expect(better.betterRate, closeTo(0.10, 1e-9));
      expect(
        better.betterNote,
        '10% cashback on eligible Swiggy app transactions.',
      );
    });

    test('the same order on the Swiggy card has nothing better', () {
      final result = comparer([swiggy, flat]).check(
        swiggy,
        spend(1000, merchant: 'SWIGGY'),
      );
      // The flat card pays 2% against the Swiggy card's 10%.
      expect(result.compared, isTrue);
      expect(result.better, isNull);
    });

    test('exclusion rows with no category do not zero a card (the live catalogue shape)', () {
      // Ordinary shopping, ₹1,000: the Swiggy card pays its 1% base rule. Used
      // on a card paying 0.5%, it is a ₹5 gap. Before the fix every v2 card
      // priced at 0 and no gap was ever found.
      final half = CardProduct(
        id: 'half',
        name: 'Half Card',
        network: CardNetwork.visa,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 0.5,
      );
      final result = comparer([swiggy, half]).check(
        half,
        spend(1000, merchant: 'SOME SHOP', categoryId: 'other', categorySlug: 'other'),
      );
      expect(result.better?.betterCard?.id, 'swiggy-card');
      expect(result.better?.missedValue, Money.fromRupees(5));
    });
  });

  group('the rules decide, not a headline rate', () {
    test('under the minimum spend the Swiggy 10% does not apply', () {
      // ₹200 is under the ₹249 minimum: the card pays its 1% base, which the
      // flat 2% card beats.
      final result = comparer([swiggy, flat]).check(
        flat,
        spend(200, merchant: 'SWIGGY'),
      );
      expect(result.better, isNull);
    });

    test('a spend the card excludes is not offered', () {
      // Under ₹100 the Swiggy card pays nothing at all.
      final half = CardProduct(
        id: 'half',
        name: 'Half Card',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 0.5,
      );
      final result = comparer([swiggy, half]).check(
        half,
        spend(80, merchant: 'SWIGGY'),
        );
      expect(result.better, isNull);
    });

    test('a merchant row needs the merchant to be known', () {
      // "SOME SHOP" is not Swiggy, so the 10% row does not apply.
      final result = comparer([swiggy, flat]).check(
        flat,
        spend(1000, merchant: 'SOME SHOP'),
      );
      expect(result.better, isNull);
    });
  });

  group('only cards that were real options count', () {
    test('a card not yet in hand on the day is not offered', () {
      final spendDay = DateTime(2026, 6, 10);
      final before = comparer(
        [swiggy, flat],
        usableFrom: {'swiggy-card': DateTime(2026, 7, 1)},
      ).check(flat, spend(1000, merchant: 'SWIGGY', at: spendDay));
      expect(before.better, isNull);
      expect(before.compared, isFalse, reason: 'nothing else to compare with');

      final after = comparer(
        [swiggy, flat],
        usableFrom: {'swiggy-card': DateTime(2026, 6, 1)},
      ).check(flat, spend(1000, merchant: 'SWIGGY', at: spendDay));
      expect(after.better?.betterCard?.id, 'swiggy-card');
    });

    test('a UPI payment cannot have gone on a card that cannot take UPI', () {
      final result = comparer([swiggy, flat]).check(
        flat,
        spend(1000, merchant: 'SWIGGY', rail: TxnRail.upiQr),
      );
      expect(result.better, isNull);
      expect(result.compared, isFalse);
    });

    test('a UPI payment can still be compared with another UPI card', () {
      final result = comparer([flatCard(id: 'a'), silentCard()]).check(
        flatCard(id: 'a'),
        spend(1000, rail: TxnRail.upiQr, categoryId: 'other', categorySlug: 'other'),
      );
      expect(result.better?.betterCard?.id, 'silent');
    });

    test('a UPI payment on a card the catalogue says cannot take UPI is left alone', () {
      final result = comparer([swiggy, flat]).check(
        swiggy,
        spend(1000, merchant: 'SWIGGY', rail: TxnRail.upiQr),
      );
      expect(result.compared, isFalse);
      expect(result.better, isNull);
    });

    test('the same product held twice, or the card used itself, is never the better card', () {
      final result = comparer([flat, flatCard(), flatCard(id: 'flat')]).check(
        flat,
        spend(1000),
      );
      expect(result.compared, isFalse);
      expect(result.better, isNull);
    });

    test('a debit card is not an option', () {
      final debit = CardProduct(
        id: 'debit',
        name: 'Debit',
        network: CardNetwork.visa,
        cardType: 'debit',
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 9,
      );
      final result = comparer([flat, debit]).check(flat, spend(1000));
      expect(result.better, isNull);
      expect(result.compared, isFalse);
    });

    test('a wallet with one card cannot compare', () {
      final single = comparer([flat]);
      expect(single.canCompare, isFalse);
      expect(single.check(flat, spend(1000)).compared, isFalse);
      expect(comparer([flat, swiggy]).canCompare, isTrue);
    });
  });

  group('categories issuers usually leave out', () {
    test('a silent catalogue entry is not trusted on rent', () {
      // "3% on everything" says nothing about rent. Kiwi-style: verified, but
      // its rent exclusion is an MCC list and a past spend has no MCC.
      final result = comparer([silentCard(), flat]).check(
        flat,
        spend(20000, categoryId: 'rent', categorySlug: 'rent'),
      );
      expect(result.better, isNull);
      expect(result.compared, isTrue);
    });

    test('a card whose own rule names rent is trusted on rent', () {
      final result = comparer([rentCard(), flat]).check(
        flat,
        spend(20000, categoryId: 'rent', categorySlug: 'rent'),
      );
      expect(result.better?.betterCard?.id, 'rent-card');
      expect(result.better?.missedValue, Money.fromRupees(400)); // 4% - 2% of 20,000
    });

    test('everywhere else the engine answer stands', () {
      final result = comparer([silentCard(), flat]).check(
        flat,
        spend(1000, categoryId: 'dining', categorySlug: 'dining'),
      );
      expect(result.better?.betterCard?.id, 'silent');
    });
  });

  group('noise and limits', () {
    test('a gap under the minimum is not a mistake', () {
      final cheap = CardProduct(
        id: 'cheap',
        name: 'Cheap',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1.4,
      );
      // 2% vs 1.4% on ₹500 is ₹3 under the ₹5 minimum...
      expect(comparer([flat, cheap]).check(cheap, spend(500)).better, isNull);
      // ...and ₹6 on ₹1,000.
      expect(
        comparer([flat, cheap]).check(cheap, spend(1000)).better?.missedValue,
        Money.fromRupees(6),
      );
    });

    test('a catalogue rate above 100% is clamped to the spend', () {
      final broken = CardProduct(
        id: 'broken',
        name: 'Broken',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 500,
      );
      final result = comparer([flat, broken]).check(flat, spend(100));
      expect(result.better?.betterValue, Money.fromRupees(100));
    });

    test('a zero or negative amount is skipped', () {
      expect(comparer([flat, swiggy]).check(flat, spend(0)).compared, isFalse);
      expect(comparer([flat, swiggy]).check(flat, spend(-50)).compared, isFalse);
    });
  });

  group('payment gateway text means online', () {
    test('only a spend routed through a gateway earns an online-rail rule', () {
      final online = CardProduct(
        id: 'online',
        name: 'Online Card',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: const [
          RewardRule(
            id: 'o-online',
            unit: RewardUnit.cashbackPercent,
            rate: 5,
            priority: 1,
            role: RuleRole.earn,
            rail: TxnRail.online,
            minEngineVersion: 2,
          ),
          RewardRule(
            id: 'o-base',
            unit: RewardUnit.cashbackPercent,
            rate: 1,
            priority: 100,
            role: RuleRole.base,
            minEngineVersion: 2,
          ),
        ],
      );
      final c = comparer([online, flat]);
      // "PYU*Flipkar" names a gateway: online, so 5% beats the flat 2%.
      expect(
        c.check(flat, spend(1000, merchant: 'PYU*Flipkar')).better?.betterCard?.id,
        'online',
      );
      // A plain name leaves the rail unknown, which never earns a rail rule.
      expect(c.check(flat, spend(1000, merchant: 'FLIPKART')).better, isNull);
    });

    test('inferSpendRail never overrides a rail the message stated', () {
      expect(inferSpendRail(TxnRail.upiQr, 'PYU*Flipkar'), TxnRail.upiQr);
      expect(inferSpendRail(TxnRail.unknown, 'Runnr Razorpay'), TxnRail.online);
      expect(inferSpendRail(TxnRail.unknown, 'RAZ*Alegra'), TxnRail.online);
      expect(inferSpendRail(TxnRail.unknown, 'SWIGGY'), TxnRail.unknown);
      expect(inferSpendRail(TxnRail.unknown, null), TxnRail.unknown);
    });
  });
}
