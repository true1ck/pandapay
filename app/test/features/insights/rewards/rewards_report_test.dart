import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/reward_counting.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_reward_label.dart';
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

const _diningCard = UserCard(
  id: 'uc-dining',
  cardProductId: 'dining',
  cardName: 'Dining Card',
  isDefault: false,
);
const _flatCard = UserCard(
  id: 'uc-flat',
  cardProductId: 'flat',
  cardName: 'Flat Card',
  isDefault: false,
  nickname: 'Everyday',
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
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: at,
  merchantName: 'Shop $id',
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

  group('missed and best single card', () {
    test('flags a food spend on the flat card and totals it', () {
      final report = buildRewardsReport(
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
      expect(report.missedRows.single.entry.id, 'food-on-flat');
      expect(report.missedRows.single.missed!.betterCard!.id, 'dining');
      expect(
        report.cards.firstWhere((c) => c.userCardId == 'uc-flat').missed,
        Money.fromRupees(30),
      );
      // Used: 20 + 20 = 40 at base rate; dining alone 50 + 10 = 60, flat alone
      // 40: the mix did not beat one card, so no claim is made.
      expect(report.beatBestSingleCard, isNull);
    });

    test('says how much the mix beat the best single card', () {
      final report = buildRewardsReport(
        range: _november,
        walletCards: _wallet,
        transactions: [
          _spend(
            'food-on-dining',
            rupees: 1000,
            at: DateTime(2026, 11, 3),
            card: 'uc-dining',
            reward: 50,
          ),
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
      // Used 50 + 20 = 70; dining alone 50 + 10 = 60; flat alone 20 + 20 = 40.
      expect(report.beatBestSingleCard, Money.fromRupees(10));
      expect(report.bestSingleCardName, 'Dining Card');
      expect(report.missedCount, 0);
    });

    test('one card has nothing to compare against', () {
      final report = buildRewardsReport(
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
      expect(report.beatBestSingleCard, isNull);
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
  });
}
