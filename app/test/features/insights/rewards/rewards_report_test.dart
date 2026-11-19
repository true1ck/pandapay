import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/reward_counting.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_reward_label.dart';
import 'package:pandapay/features/insights/rewards/rewards_comparison.dart';
import 'package:pandapay/features/insights/rewards/rewards_filter.dart';
import 'package:pandapay/features/insights/rewards/rewards_report.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

final _dining = CardProduct(
  id: 'dining',
  name: 'Dining Card',
  network: CardNetwork.rupay,
  rewardRules: const [
    RewardRule(
      id: 'd1',
      categoryId: 'food',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
    ),
    RewardRule(
      id: 'd2',
      unit: RewardUnit.cashbackPercent,
      rate: 1,
      priority: 200,
    ),
  ],
);
final _flat = CardProduct(
  id: 'flat',
  name: 'Flat Card',
  network: CardNetwork.visa,
  rewardRules: const [
    RewardRule(
      id: 'f1',
      unit: RewardUnit.cashbackPercent,
      rate: 2,
      priority: 200,
    ),
  ],
);

// Issue dates before every test spend: a card only counts as an option for a
// spend from the day it was in hand.
final _diningCard = UserCard(
  id: 'uc-dining',
  cardProductId: 'dining',
  cardName: 'Dining Card',
  isDefault: false,
  openedOn: DateTime(2025, 1, 1),
);
final _flatCard = UserCard(
  id: 'uc-flat',
  cardProductId: 'flat',
  cardName: 'Flat Card',
  isDefault: false,
  nickname: 'Everyday',
  openedOn: DateTime(2025, 1, 1),
);

final _wallet = [(_diningCard, _dining), (_flatCard, _flat)];
final _november = RewardsRange.days(
  DateTime(2026, 11, 1),
  DateTime(2026, 11, 30),
);

TransactionEntry _spend(
  String id, {
  required double rupees,
  required DateTime at,
  String? card,
  String category = 'Food',
  String categoryId = 'food',
  double? reward,
  TxnInstrument instrument = TxnInstrument.creditCard,
  String status = 'active',
  TxnEntryKind kind = TxnEntryKind.spend,
  String? paymentMethod,
  String? merchant,
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: at,
  merchantName: merchant ?? 'Shop $id',
  categoryId: categoryId,
  categoryName: category,
  userCardId: card,
  cardDisplayName: card == null ? 'Some Card' : null,
  instrument: instrument,
  entryKind: kind,
  source: 'sms',
  status: status,
  rewardValue: reward == null ? null : Money.fromRupees(reward),
  paymentMethod: paymentMethod,
);

/// The report with the card comparison worked out the way the app does it
/// (`rewardsChecksProvider`), synchronously.
RewardsReport _report({
  required List<TransactionEntry> transactions,
  required RewardsRange range,
  required List<(UserCard, CardProduct)> walletCards,
  Set<String> cardIds = const {},
  Set<String> categories = const {},
  MerchantDirectory? directory,
}) {
  final checks = computeSpendChecks(
    buildRewardsComparisonRequest(
      transactions: [
        for (final t in transactions)
          if (range.contains(t.occurredAt)) t,
      ],
      walletCards: walletCards,
      firstUseByCardId: firstCardUseOf(transactions),
      directory: directory,
    ),
  );
  return buildRewardsReport(
    transactions: transactions,
    range: range,
    walletCards: walletCards,
    cardIds: cardIds,
    categories: categories,
    checks: checks,
  );
}

void main() {
  group('scope', () {
    test('counts only active credit-card purchases inside the range', () {
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        transactions: [
          _spend(
            'in',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-dining',
            reward: 50,
          ),
          _spend(
            'last-day',
            rupees: 100,
            at: DateTime(2026, 11, 30, 23, 59),
            card: 'uc-flat',
            reward: 2,
          ),
          _spend(
            'october',
            rupees: 999,
            at: DateTime(2026, 10, 31, 23, 59),
            card: 'uc-dining',
            reward: 9,
          ),
          _spend(
            'december',
            rupees: 999,
            at: DateTime(2026, 12, 1),
            card: 'uc-dining',
            reward: 9,
          ),
          _spend(
            'upi',
            rupees: 500,
            at: DateTime(2026, 11, 4),
            instrument: TxnInstrument.upiBank,
          ),
          _spend(
            'debit',
            rupees: 500,
            at: DateTime(2026, 11, 4),
            instrument: TxnInstrument.debitCard,
            card: 'uc-flat',
            reward: 5,
          ),
          _spend(
            'ignored',
            rupees: 500,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 10,
            status: 'ignored',
          ),
          _spend(
            'income',
            rupees: 500,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 10,
            kind: TxnEntryKind.income,
          ),
        ],
      );
      expect(report.rows.map((r) => r.entry.id), ['last-day', 'in']);
      expect(report.earned, Money.fromRupees(52));
      expect(report.spend, Money.fromRupees(1100));
      expect(report.ratePct, closeTo(52 / 1100 * 100, 1e-9));
    });

    test('the same transaction id twice counts once', () {
      final row = _spend(
        'dup',
        rupees: 1000,
        at: DateTime(2026, 11, 3),
        card: 'uc-dining',
        reward: 50,
      );
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        transactions: [row, row],
      );
      expect(report.rows, hasLength(1));
      expect(report.earned, Money.fromRupees(50));
    });

    test(
      'card and category filters narrow every figure but not the filter choices',
      () {
        final transactions = [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-dining',
            reward: 50,
          ),
          _spend(
            'b',
            rupees: 2000,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 40,
            category: 'Travel',
            categoryId: 'travel',
          ),
          _spend(
            'c',
            rupees: 500,
            at: DateTime(2026, 11, 5),
            card: 'uc-flat',
            reward: 10,
          ),
        ];
        final report = buildRewardsReport(
          range: _november,
          walletCards: _wallet,
          transactions: transactions,
          cardIds: {'uc-flat'},
          categories: {'Food'},
        );
        expect(report.rows.map((r) => r.entry.id), ['c']);
        expect(report.earned, Money.fromRupees(10));
        expect(report.cards.map((c) => c.userCardId), ['uc-flat']);
        expect(report.cardOptions.map((o) => o.key).toSet(), {
          'uc-dining',
          'uc-flat',
        });
        expect(report.categoryOptions.map((o) => o.key), ['Travel', 'Food']);
        expect(report.cardLabel('uc-flat'), 'Everyday');
      },
    );
  });

  group('status', () {
    test('each row gets the same answer the transaction screen gives', () {
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        transactions: [
          _spend(
            'earned',
            rupees: 100,
            at: DateTime(2026, 11, 2),
            card: 'uc-flat',
            reward: 2,
          ),
          _spend(
            'zero',
            rupees: 100,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 0,
          ),
          _spend(
            'emi',
            rupees: 100,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 2,
            paymentMethod: 'emi',
          ),
          _spend(
            'pending',
            rupees: 100,
            at: DateTime(2026, 11, 5),
            card: 'uc-flat',
          ),
          _spend('not-in-wallet', rupees: 100, at: DateTime(2026, 11, 6)),
        ],
      );
      final byId = {for (final r in report.rows) r.entry.id: r};
      expect(byId['earned']!.status, RewardRowStatus.earned);
      expect(byId['zero']!.status, RewardRowStatus.noReward);
      expect(byId['emi']!.status, RewardRowStatus.noReward);
      expect(byId['pending']!.status, RewardRowStatus.notCounted);
      expect(
        byId['pending']!.notCountedReason,
        RewardNotCountedReason.notWorkedOut,
      );
      expect(
        byId['not-in-wallet']!.notCountedReason,
        RewardNotCountedReason.notInWallet,
      );
      expect(
        report.earned,
        Money.fromRupees(2),
        reason: 'the EMI reward is not counted',
      );
      expect(report.earnedCount, 1);
      expect(report.noRewardCount, 2);
      expect(report.notCountedCount, 2);
      // The activity chip agrees with the page about what counts.
      expect(activityRewardChip(byId['earned']!.entry), isNotNull);
      expect(activityRewardChip(byId['emi']!.entry), isNull);
      expect(countedRewardValue(byId['zero']!.entry), isNull);
    });
  });

  group('missed', () {
    test('flags a food spend on the flat card and totals it', () {
      final report = _report(
        range: _november,
        walletCards: _wallet,
        transactions: [
          // 5% on dining vs 2% on flat: 30 missed.
          _spend(
            'food-on-flat',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
          // Travel: flat 2% beats dining 1%: right card.
          _spend(
            'travel-on-flat',
            rupees: 1000,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 20,
            category: 'Travel',
            categoryId: 'travel',
          ),
        ],
      );
      expect(report.canCompare, isTrue);
      expect(report.missedCount, 1);
      expect(report.missed, Money.fromRupees(30));
      expect(
        report.comparedCount,
        2,
        reason: 'both spends had another card to compare with',
      );
      expect(report.comparisonFailed, isFalse);
      final row = report.missedRows.single;
      expect(row.entry.id, 'food-on-flat');
      expect(row.missed!.betterCard!.id, 'dining');
      expect(row.missed!.usedRate, closeTo(0.02, 1e-9));
      expect(row.missed!.betterRate, closeTo(0.05, 1e-9));
      expect(
        report.cards.firstWhere((c) => c.userCardId == 'uc-flat').missed,
        Money.fromRupees(30),
      );
    });

    test('one card has nothing to compare against', () {
      final report = _report(
        range: _november,
        walletCards: [(_flatCard, _flat)],
        transactions: [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
        ],
      );
      expect(report.canCompare, isFalse);
      expect(report.missedCount, 0);
      expect(report.comparedCount, 0);
    });

    test('two cards of the same product are not a choice', () {
      final twin = UserCard(
        id: 'uc-flat-2',
        cardProductId: 'flat',
        cardName: 'Flat Card',
        isDefault: false,
        openedOn: DateTime(2025, 1, 1),
      );
      final report = _report(
        range: _november,
        walletCards: [(_flatCard, _flat), (twin, _flat)],
        transactions: [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
        ],
      );
      expect(report.canCompare, isFalse, reason: 'one product, held twice');
      expect(report.missedCount, 0);
    });

    test(
      'a wallet shaped like the live catalogue finds the better card',
      () {
        // The Swiggy HDFC card as the live catalogue writes it: rows with no
        // category at priority 0 ("nothing under ₹100", "nothing on EMI") in
        // front of the earning rules. The first comparison read those as the
        // card's base rate, so every card priced at 0% and the Missed tab was
        // empty for a wallet of ten cards.
        final swiggyProduct = CardProduct(
          id: 'swiggy',
          name: 'Swiggy Card',
          network: CardNetwork.visa,
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
            const RewardRule(
              id: 'x-emi',
              unit: RewardUnit.cashbackPercent,
              rate: 0,
              priority: 0,
              role: RuleRole.exclusion,
              rail: TxnRail.emi,
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
        final swiggyCard = UserCard(
          id: 'uc-swiggy',
          cardProductId: 'swiggy',
          cardName: 'Swiggy Card',
          isDefault: false,
          openedOn: DateTime(2025, 1, 1),
        );
        final report = _report(
          range: _november,
          walletCards: [(_flatCard, _flat), (swiggyCard, swiggyProduct)],
          directory: MerchantDirectory.fromJson({
            'merchants': [
              {
                'slug': 'swiggy',
                'name': 'Swiggy',
                'aliases': ['swiggy'],
              },
            ],
          }),
          transactions: [
            _spend(
              'order',
              merchant: 'SWIGGY',
              rupees: 1000,
              at: DateTime(2026, 11, 3),
              card: 'uc-flat',
              reward: 20,
            ),
          ],
        );
        expect(report.missedCount, 1);
        expect(report.missed, Money.fromRupees(80)); // 10% - 2% of 1,000
        expect(report.missedRows.single.missed!.betterCard!.id, 'swiggy');
      },
    );

    test('a card counts only from the day it was first used', () {
      // Dining Card has no issue date, and its first spend is on 20 Nov: it was
      // not in hand for the 3 Nov food spend on the flat card.
      final late = UserCard(
        id: 'uc-late',
        cardProductId: 'dining',
        cardName: 'Dining Card',
        isDefault: false,
      );
      final report = _report(
        range: _november,
        walletCards: [(_flatCard, _flat), (late, _dining)],
        transactions: [
          _spend(
            'before',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
          _spend(
            'first-on-dining',
            rupees: 1000,
            at: DateTime(2026, 11, 20),
            card: 'uc-late',
            reward: 50,
          ),
        ],
      );
      expect(report.missedCount, 0);
      // Only the 20 Nov spend had another card (the flat card) to compare with.
      expect(report.comparedCount, 1);
    });

    test('a card with no use and no issue date is not an option for past spends', () {
      final unused = UserCard(
        id: 'uc-unused',
        cardProductId: 'dining',
        cardName: 'Dining Card',
        isDefault: false,
      );
      final report = _report(
        range: _november,
        walletCards: [(_flatCard, _flat), (unused, _dining)],
        transactions: [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
        ],
      );
      expect(report.missedCount, 0);
      expect(report.comparedCount, 0);
    });

    test('an EMI or gift-card payment has no better card', () {
      final report = _report(
        range: _november,
        walletCards: _wallet,
        transactions: [
          _spend(
            'emi',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
            paymentMethod: 'emi',
          ),
          _spend(
            'gift',
            rupees: 1000,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 20,
            paymentMethod: 'gift_card',
          ),
        ],
      );
      expect(report.missedCount, 0);
      expect(report.comparedCount, 0);
    });

    test('a failed comparison says so rather than claiming nothing was missed', () {
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        comparisonFailed: true,
        transactions: [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
        ],
      );
      expect(report.comparisonFailed, isTrue);
      expect(report.missedCount, 0);
      expect(report.comparedCount, 0);
    });

    test('the card and category filters re-slice the same answers', () {
      final transactions = [
        _spend(
          'food-on-flat',
          rupees: 1000,
          at: DateTime(2026, 11, 3),
          card: 'uc-flat',
          reward: 20,
        ),
        _spend(
          'travel-on-dining',
          rupees: 1000,
          at: DateTime(2026, 11, 4),
          card: 'uc-dining',
          reward: 10,
          category: 'Travel',
          categoryId: 'travel',
        ),
      ];
      // Dining Card pays 1% on travel, Flat Card 2%: 10 missed there too.
      final all = _report(
        range: _november,
        walletCards: _wallet,
        transactions: transactions,
      );
      expect(all.missedCount, 2);
      expect(all.missed, Money.fromRupees(40));
      final onFlat = _report(
        range: _november,
        walletCards: _wallet,
        transactions: transactions,
        cardIds: {'uc-flat'},
      );
      expect(onFlat.missedCount, 1);
      expect(onFlat.missed, Money.fromRupees(30));
      final travel = _report(
        range: _november,
        walletCards: _wallet,
        transactions: transactions,
        categories: {'Travel'},
      );
      expect(travel.missedCount, 1);
      expect(travel.missed, Money.fromRupees(10));
    });
  });

  group('breakdowns', () {
    test('categories that earned, highest first; cards with no spend last', () {
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        transactions: [
          _spend(
            'a',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-flat',
            reward: 20,
          ),
          _spend(
            'b',
            rupees: 5000,
            at: DateTime(2026, 11, 4),
            card: 'uc-flat',
            reward: 100,
            category: 'Travel',
            categoryId: 'travel',
          ),
          _spend(
            'c',
            rupees: 300,
            at: DateTime(2026, 11, 5),
            card: 'uc-flat',
            reward: 0,
            category: 'Fuel',
            categoryId: 'fuel',
          ),
        ],
      );
      expect(report.byCategory.map((s) => s.key), ['Travel', 'Food']);
      expect(report.cards.map((c) => c.userCardId), ['uc-flat', 'uc-dining']);
      expect(report.cards.last.spends, 0);
      expect(report.cards.first.ratePct, closeTo(120 / 6300 * 100, 1e-9));
    });

    test(
      'month bars only for ranges over one month, years for long ranges',
      () {
        final rows = [
          _spend(
            'sep',
            rupees: 1000,
            at: DateTime(2026, 9, 10),
            card: 'uc-flat',
            reward: 20,
          ),
          _spend(
            'nov',
            rupees: 1000,
            at: DateTime(2026, 11, 10),
            card: 'uc-flat',
            reward: 30,
          ),
        ];
        expect(
          buildRewardsReport(
            range: _november,
            walletCards: _wallet,
            transactions: rows,
          ).buckets,
          isEmpty,
        );
        final quarter = buildRewardsReport(
          range: RewardsRange.days(
            DateTime(2026, 9, 1),
            DateTime(2026, 11, 30),
          ),
          walletCards: _wallet,
          transactions: rows,
        );
        expect(quarter.buckets.map((b) => b.start.month), [9, 10, 11]);
        expect(quarter.buckets.map((b) => b.earned), [
          Money.fromRupees(20),
          const Money.zero(),
          Money.fromRupees(30),
        ]);
        final long = buildRewardsReport(
          range: RewardsRange.days(
            DateTime(2024, 1, 1),
            DateTime(2026, 11, 30),
          ),
          walletCards: _wallet,
          transactions: rows,
        );
        expect(long.buckets.map((b) => b.start.year), [2024, 2025, 2026]);
        expect(long.buckets.every((b) => b.isYear), isTrue);
        expect(long.buckets.last.earned, Money.fromRupees(50));
      },
    );
  });

  group('range', () {
    final now = DateTime(2026, 11, 18, 15, 30);
    test('presets are whole calendar periods', () {
      expect(
        rewardsRangeFor(const SpendReportQuery.preset(SpendPeriod.month), now),
        RewardsRange.days(DateTime(2026, 11, 1), DateTime(2026, 11, 30)),
      );
      expect(
        rewardsRangeFor(
          const SpendReportQuery.preset(SpendPeriod.quarter),
          now,
        ),
        RewardsRange.days(DateTime(2026, 10, 1), DateTime(2026, 12, 31)),
      );
      expect(
        rewardsRangeFor(const SpendReportQuery.preset(SpendPeriod.year), now),
        RewardsRange.days(DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
      );
      // 18 Nov 2026 is a Wednesday.
      expect(
        rewardsRangeFor(const SpendReportQuery.preset(SpendPeriod.week), now),
        RewardsRange.days(DateTime(2026, 11, 16), DateTime(2026, 11, 22)),
      );
    });

    test('labels', () {
      expect(rewardsRangeLabel(_november), 'November 2026');
      expect(
        rewardsRangeLabel(
          RewardsRange.days(DateTime(2026, 9, 1), DateTime(2026, 11, 30)),
        ),
        'Sep – Nov 2026',
      );
      expect(
        rewardsRangeLabel(
          RewardsRange.days(DateTime(2025, 12, 1), DateTime(2026, 2, 28)),
        ),
        'Dec 2025 – Feb 2026',
      );
      expect(
        rewardsRangeLabel(
          RewardsRange.days(DateTime(2026, 11, 16), DateTime(2026, 11, 22)),
        ),
        '16 – 22 Nov 2026',
      );
      expect(
        rewardsRangeLabel(
          RewardsRange.days(DateTime(2026, 1, 1), DateTime(2026, 11, 18)),
        ),
        '1 Jan – 18 Nov 2026',
      );
    });

    test('deep link params', () {
      expect(
        RewardsFilter.queryFromParams({'period': 'quarter'}),
        const SpendReportQuery.preset(SpendPeriod.quarter),
      );
      expect(
        RewardsFilter.queryFromParams({}),
        const SpendReportQuery.preset(SpendPeriod.month),
      );
      expect(
        RewardsFilter.queryFromParams({
          'from': '2026-10-01',
          'to': '2026-10-31',
        }),
        SpendReportQuery.custom(
          from: DateTime(2026, 10, 1),
          to: DateTime(2026, 10, 31),
        ),
      );
      // Backwards dates are ignored rather than trusted.
      expect(
        RewardsFilter.queryFromParams({
          'from': '2026-10-31',
          'to': '2026-10-01',
        }),
        const SpendReportQuery.preset(SpendPeriod.month),
      );
    });
  });

  test('a year of heavy card use with six cards stays cheap', () {
    final products = [
      for (var i = 0; i < 6; i++)
        CardProduct(
          id: 'p$i',
          name: 'Card $i',
          network: CardNetwork.visa,
          rewardRules: [
            for (var r = 0; r < 25; r++)
              RewardRule(
                id: 'p$i-r$r',
                categoryId: 'cat$r',
                unit: RewardUnit.cashbackPercent,
                rate: (r % 5) + 1.0,
              ),
            RewardRule(
              id: 'p$i-base',
              unit: RewardUnit.cashbackPercent,
              rate: 1,
              priority: 200,
            ),
          ],
        ),
    ];
    final wallet = [
      for (var i = 0; i < 6; i++)
        (
          UserCard(
            id: 'uc$i',
            cardProductId: 'p$i',
            cardName: 'Card $i',
            isDefault: false,
          ),
          products[i],
        ),
    ];
    final start = DateTime(2025, 12, 1);
    final rows = [
      for (var i = 0; i < 3000; i++)
        _spend(
          't$i',
          rupees: 100.0 + i,
          at: start.add(Duration(hours: i * 2)),
          card: 'uc${i % 6}',
          reward: 2,
          category: 'Cat ${i % 30}',
          categoryId: 'cat${i % 30}',
        ),
    ];
    final range = RewardsRange.days(
      DateTime(2025, 12, 1),
      DateTime(2026, 11, 30),
    );
    buildRewardsReport(
      range: range,
      walletCards: wallet,
      transactions: rows,
    ); // warm up
    final watch = Stopwatch()..start();
    final report = buildRewardsReport(
      range: range,
      walletCards: wallet,
      transactions: rows,
    );
    watch.stop();
    // ignore: avoid_print
    print(
      'rewards report: ${report.rows.length} spends x 6 cards in ${watch.elapsedMilliseconds} ms',
    );
    expect(report.rows, hasLength(3000));
    expect(watch.elapsedMilliseconds, lessThan(120));

    // Pricing every spend on every other card is the costly part. The app runs
    // it in an isolate (rewards_comparison.dart); this pins its cost so it can
    // not quietly grow: 3,000 spends x 6 cards is 18,000 engine evaluations.
    final request = buildRewardsComparisonRequest(
      transactions: rows,
      walletCards: wallet,
      firstUseByCardId: firstCardUseOf(rows),
    );
    final priced = Stopwatch()..start();
    final checks = computeSpendChecks(request);
    priced.stop();
    // ignore: avoid_print
    print(
      'rewards comparison: ${request.spends.length} spends x 6 cards in ${priced.elapsedMilliseconds} ms',
    );
    expect(checks, isNotEmpty);
    expect(priced.elapsedMilliseconds, lessThan(4000));
  });
}
