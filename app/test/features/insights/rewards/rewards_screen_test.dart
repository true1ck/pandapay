import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/reward_counting.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/rewards/rewards_comparison.dart';
import 'package:pandapay/features/insights/rewards/rewards_filter.dart';
import 'package:pandapay/features/insights/rewards/rewards_providers.dart';
import 'package:pandapay/features/insights/rewards/rewards_screen.dart';
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
  annualFeeInr: Money.fromRupees(500),
  rewardRules: const [
    RewardRule(
      id: 'f1',
      unit: RewardUnit.cashbackPercent,
      rate: 2,
      priority: 200,
    ),
  ],
);
final _travel = CardProduct(
  id: 'travel',
  name: 'Travel Card',
  network: CardNetwork.visa,
  rewardRules: const [
    RewardRule(
      id: 't1',
      unit: RewardUnit.cashbackPercent,
      rate: 0.5,
      priority: 200,
    ),
  ],
);

// Issue dates before every test spend, so each card counts as in hand.
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
final _travelCard = UserCard(
  id: 'uc-travel',
  cardProductId: 'travel',
  cardName: 'Travel Card',
  isDefault: false,
  openedOn: DateTime(2025, 1, 1),
);

TransactionEntry _spend(
  String id,
  String merchant, {
  required double rupees,
  required DateTime at,
  String? card,
  required String category,
  double? reward,
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: at,
  merchantName: merchant,
  categoryId: category.toLowerCase(),
  categoryName: category,
  userCardId: card,
  cardDisplayName: card == null ? 'Unknown Card' : null,
  source: 'sms',
  status: 'active',
  rewardValue: reward == null ? null : Money.fromRupees(reward),
);

/// November 2026: earned 20 + 100 + 20 = ₹140 on ₹7,400 of card spend.
final _transactions = [
  _spend(
    'a',
    'Swiggy',
    rupees: 1000,
    at: DateTime(2026, 11, 3),
    card: 'uc-flat',
    category: 'Food',
    reward: 20,
  ),
  _spend(
    'b',
    'MakeMyTrip',
    rupees: 5000,
    at: DateTime(2026, 11, 5),
    card: 'uc-flat',
    category: 'Travel',
    reward: 100,
  ),
  _spend(
    'c',
    'Zomato',
    rupees: 400,
    at: DateTime(2026, 11, 7),
    card: 'uc-dining',
    category: 'Food',
    reward: 20,
  ),
  _spend(
    'd',
    'Croma',
    rupees: 700,
    at: DateTime(2026, 11, 9),
    category: 'Shopping',
  ),
  _spend(
    'e',
    'Amazon',
    rupees: 300,
    at: DateTime(2026, 11, 11),
    card: 'uc-flat',
    category: 'Shopping',
  ),
  _spend(
    'f',
    'Barbeque Nation',
    rupees: 2000,
    at: DateTime(2026, 10, 12),
    card: 'uc-dining',
    category: 'Food',
    reward: 100,
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  List<(UserCard, CardProduct)>? wallet,
  List<TransactionEntry>? transactions,
  String location = '/insights/rewards',
  Size screen = const Size(390, 844),
  Future<Map<String, SpendCheck>> Function(
    List<TransactionEntry> inRange,
    List<(UserCard, CardProduct)> wallet,
  )?
  checks,
}) async {
  tester.view.physicalSize = screen * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final rows = transactions ?? _transactions;
  final walletCards = wallet ?? [(_diningCard, _dining), (_flatCard, _flat)];
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/insights/rewards',
        builder: (context, state) => RewardsScreen(
          initialTab: RewardsTab.fromParam(state.uri.queryParameters['tab']),
          initialQuery: RewardsFilter.queryFromParams(
            state.uri.queryParameters,
          ),
        ),
      ),
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) =>
            Scaffold(body: Text('detail ${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(TestClock(DateTime(2026, 11, 18, 10))),
        ownedCardsWithProductProvider.overrideWithValue(
          AsyncData(walletCards),
        ),
        rewardsTransactionsProvider.overrideWith(
          (ref, range) async => [
            for (final row in rows)
              if (range.contains(row.occurredAt)) row,
          ],
        ),
        // The real provider reads the ledger, the category list and the
        // catalogue; the answer itself is the same comparison, run inline.
        rewardsChecksProvider.overrideWith((ref, range) async {
          final inRange = [
            for (final row in rows)
              if (range.contains(row.occurredAt)) row,
          ];
          if (checks != null) return checks(inRange, walletCards);
          return computeSpendChecks(
            buildRewardsComparisonRequest(
              transactions: inRange,
              walletCards: walletCards,
              firstUseByCardId: firstCardUseOf(rows),
            ),
          );
        }),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _list(String key) => find
    .descendant(
      of: find.byKey(PageStorageKey<String>(key)),
      matching: find.byType(Scrollable),
    )
    .first;

Finder _money(String key, String text) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

void main() {
  testWidgets('summary answers how much the cards earned this month', (
    tester,
  ) async {
    await _pump(tester);

    expect(_money('rewards-earned', '₹140'), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text('on ₹7,400 by card'), findsOneWidget);
    expect(find.text('· 1.9% back · 5 spends'), findsOneWidget);
    expect(find.textContaining('More than only'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('rewards-not-counted')),
        matching: find.text('2 spends'),
      ),
      findsOneWidget,
    );
    expect(find.text('Missed on 1 spend'), findsOneWidget);
    // October's spend is outside the range.
    expect(find.text('Barbeque Nation'), findsNothing);
  });

  testWidgets('the card filter narrows every figure and can be removed', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Filter rewards'), findsOneWidget);
    await tester.tap(find.text('Dining Card · 1'));
    await tester.pumpAndSettle();
    expect(
      find.text('1 card spend · '),
      findsOneWidget,
      reason: 'live preview before applying',
    );
    await tester.tap(find.byKey(const Key('rewards-filter-apply')));
    await tester.pumpAndSettle();

    expect(_money('rewards-earned', '₹20'), findsOneWidget);
    expect(find.text('Filters · 1'), findsOneWidget);
    expect(find.byKey(const Key('rewards-active-filters')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rewards-clear-filters')));
    await tester.pumpAndSettle();
    expect(_money('rewards-earned', '₹140'), findsOneWidget);
    expect(find.byKey(const Key('rewards-active-filters')), findsNothing);
  });

  testWidgets('the summary charts are display only', (tester) async {
    await _pump(tester, location: '/insights/rewards?period=quarter');
    expect(find.text('Q4 2026'), findsOneWidget);
    expect(find.byKey(const Key('rewards-month-bars')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rewards-month-bars')));
    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();

    // Nothing narrowed: same dates, no filter chips, chart still there.
    expect(find.text('Q4 2026'), findsOneWidget);
    expect(find.byKey(const Key('rewards-active-filters')), findsNothing);
    expect(find.byKey(const Key('rewards-month-bars')), findsOneWidget);
    expect(_money('rewards-earned', '₹240'), findsOneWidget);
  });

  for (final (name, size) in [
    ('a 6.1-inch phone', const Size(390, 844)),
    ('an iPhone 16 Pro Max', const Size(430, 932)),
  ]) {
    testWidgets('Summary fits on one screen of $name, charts included', (
      tester,
    ) async {
      await _pump(
        tester,
        location: '/insights/rewards?period=quarter',
        screen: size,
      );
      final bottom = tester
          .getBottomLeft(find.byKey(const Key('rewards-month-bars')))
          .dy;
      // A real phone also loses its status bar and home indicator (about
      // 59 + 34 points) that the test window does not have.
      expect(bottom, lessThanOrEqualTo(size.height - 93));
    });
  }

  testWidgets('the not-counted note opens those spends in Transactions', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.byKey(const Key('rewards-not-counted')));
    await tester.pumpAndSettle();

    expect(find.text('Croma'), findsOneWidget);
    expect(find.text('Amazon'), findsOneWidget);
    expect(find.text('Card not in wallet'), findsOneWidget);
    expect(find.text('Not worked out yet'), findsOneWidget);
    expect(find.text('Swiggy'), findsNothing);

    await tester.tap(find.byKey(const Key('rewards-status-all')));
    await tester.pumpAndSettle();
    expect(find.text('Swiggy'), findsOneWidget);
    expect(find.text('5 spends'), findsOneWidget);
  });

  testWidgets('a transaction row opens the transaction', (tester) async {
    await _pump(tester, location: '/insights/rewards?tab=transactions');

    await tester.tap(find.text('MakeMyTrip'));
    await tester.pumpAndSettle();
    expect(find.text('detail b'), findsOneWidget);
  });

  testWidgets('Missed lists the spend another card would have done better on', (
    tester,
  ) async {
    await _pump(tester, location: '/insights/rewards?tab=missed');

    expect(find.byKey(const Key('rewards-missed-total')), findsOneWidget);
    expect(find.text('Swiggy'), findsOneWidget);
    expect(find.text('+₹30'), findsOneWidget);
    // Each card's rate for this very spend, so the gap can be checked by eye.
    expect(find.text('2% back'), findsOneWidget);
    expect(find.text('5% back'), findsOneWidget);
    expect(
      find.text('MakeMyTrip'),
      findsNothing,
      reason: 'Flat Card was the best card for travel',
    );
    // The total says how much was checked, so it is never taken for "all".
    expect(
      find.textContaining('Checked 4 of 5 spends against your other cards'),
      findsOneWidget,
    );
  });

  testWidgets('Missed says what was checked when nothing clearly came up', (
    tester,
  ) async {
    await _pump(
      tester,
      location: '/insights/rewards?tab=missed',
      transactions: [
        // Travel on the flat card: 2% beats the dining card's 1%.
        _spend(
          'b',
          'MakeMyTrip',
          rupees: 5000,
          at: DateTime(2026, 11, 5),
          card: 'uc-flat',
          category: 'Travel',
          reward: 100,
        ),
      ],
    );
    expect(find.text('No clear misses'), findsOneWidget);
    expect(
      find.textContaining('Checked 1 spend in November 2026'),
      findsOneWidget,
    );
    expect(find.textContaining('₹5 or more extra'), findsOneWidget);
    expect(find.byKey(const Key('rewards-missed-total')), findsNothing);
  });

  testWidgets('Missed does not call it a clean sheet when nothing was compared', (
    tester,
  ) async {
    // A second card with no history and no issue date was not in hand.
    final unused = UserCard(
      id: 'uc-unused',
      cardProductId: 'dining',
      cardName: 'Dining Card',
      isDefault: false,
    );
    await _pump(
      tester,
      wallet: [(_flatCard, _flat), (unused, _dining)],
      location: '/insights/rewards?tab=missed',
    );
    expect(find.text('Nothing to compare yet'), findsOneWidget);
    expect(find.text('No clear misses'), findsNothing);
  });

  testWidgets('Missed says so when the comparison could not run', (
    tester,
  ) async {
    var attempts = 0;
    await _pump(
      tester,
      location: '/insights/rewards?tab=missed',
      checks: (inRange, wallet) async {
        attempts++;
        if (attempts == 1) throw StateError('comparison failed');
        return computeSpendChecks(
          buildRewardsComparisonRequest(
            transactions: inRange,
            walletCards: wallet,
            firstUseByCardId: firstCardUseOf(inRange),
          ),
        );
      },
    );
    expect(find.text('Could not check your cards'), findsOneWidget);
    expect(find.text('No clear misses'), findsNothing);

    await tester.tap(find.byKey(const Key('rewards-missed-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Swiggy'), findsOneWidget, reason: 'the retry worked');
  });

  testWidgets('Missed explains itself with only one card', (tester) async {
    await _pump(
      tester,
      wallet: [(_flatCard, _flat)],
      location: '/insights/rewards?tab=missed',
    );
    expect(find.text('Add a second card to compare'), findsOneWidget);
  });

  testWidgets('Missed warns when the better card cannot take UPI', (
    tester,
  ) async {
    // The better card is card-only; the card used takes UPI.
    final upiFlat = CardProduct(
      id: 'upi-flat',
      name: 'UPI Flat Card',
      network: CardNetwork.rupay,
      isUpiLinkable: true,
      rewardRules: const [
        RewardRule(
          id: 'u1',
          unit: RewardUnit.cashbackPercent,
          rate: 0.5,
          priority: 200,
        ),
      ],
    );
    final upiCard = UserCard(
      id: 'uc-upi',
      cardProductId: 'upi-flat',
      cardName: 'UPI Flat Card',
      isDefault: false,
      openedOn: DateTime(2025, 1, 1),
    );
    await _pump(
      tester,
      wallet: [(upiCard, upiFlat), (_flatCard, _flat)],
      location: '/insights/rewards?tab=missed',
      transactions: [
        _spend(
          'x',
          'Cafe',
          rupees: 1000,
          at: DateTime(2026, 11, 3),
          card: 'uc-upi',
          category: 'Food',
          reward: 5,
        ),
      ],
    );
    expect(find.byKey(const Key('rewards-missed-card-only')), findsOneWidget);
  });

  testWidgets('Cards shows each wallet card, unused ones last', (tester) async {
    await _pump(
      tester,
      wallet: [
        (_diningCard, _dining),
        (_flatCard, _flat),
        (_travelCard, _travel),
      ],
      location: '/insights/rewards?tab=cards',
    );

    expect(find.byKey(const Key('rewards-card-uc-flat')), findsOneWidget);
    expect(find.text('Everyday'), findsOneWidget);
    expect(find.text('3 spends · 1.9% back'), findsOneWidget);
    expect(
      find.text('Rewards have not covered the annual fee yet.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('rewards-card-uc-travel')),
      300,
      scrollable: _list('rewards-cards'),
    );
    expect(find.text('No spends in this range'), findsOneWidget);

    // "See this card's spends" narrows the page and opens Transactions.
    await tester.scrollUntilVisible(
      find.text('See this card\'s spends').first,
      -300,
      scrollable: _list('rewards-cards'),
    );
    await tester.tap(find.text('See this card\'s spends').first);
    await tester.pumpAndSettle();
    expect(find.text('MakeMyTrip'), findsOneWidget);
    expect(find.text('Zomato'), findsNothing);
  });

  testWidgets('picking last month in the date sheet shows October', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Nov 2026'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Rewards cover purchases paid by a credit card in your wallet.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Last month'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply range'));
    await tester.pumpAndSettle();

    expect(find.text('October 2026'), findsOneWidget);
    expect(_money('rewards-earned', '₹100'), findsOneWidget);
  });

  testWidgets('a range with no card spends says so', (tester) async {
    await _pump(tester, transactions: const []);
    expect(find.text('No card spends in November 2026'), findsOneWidget);
  });

  test('equal scopes are one provider key, so a rebuild never refetches', () {
    final now = DateTime(2026, 11, 18);
    final a = RewardsScope.of(
      RewardsFilter(cardIds: {'x', 'y'}, categories: {'Food'}),
      now,
    );
    final b = RewardsScope.of(
      RewardsFilter(cardIds: {'y', 'x'}, categories: {'Food'}),
      now,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      RewardsScope.of(
            const RewardsFilter(
              query: SpendReportQuery.preset(SpendPeriod.year),
            ),
            now,
          ) ==
          a,
      isFalse,
    );
  });
}
