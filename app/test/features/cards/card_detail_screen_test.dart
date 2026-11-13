import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [
    SpendCategory(id: 'cat-bills', slug: 'bills', name: 'Bills & Utilities'),
  ];
}

CardProduct _fullCard() => CardProduct(
  id: 'p1',
  name: 'Test Card',
  network: CardNetwork.rupay,
  pointValueInr: 1,
  verifiedAt: DateTime(2026, 3, 1),
  rewardRules: const [
    RewardRule(
      id: 'r1',
      categoryId: 'cat-bills',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
    ),
  ],
  capRules: const [
    CapRule(
      id: 'cap1',
      label: '5% bills cap',
      capValue: Money.fromPaise(50000),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
    ),
  ],
  milestoneRules: [
    MilestoneRule(
      id: 'm1',
      label: 'Spend ₹1L',
      thresholdSpend: Money.fromRupees(100000),
      rewardValue: Money.fromRupees(1000),
    ),
  ],
  benefits: const [
    CardBenefit(
      id: 'b1',
      kind: BenefitKind.loungeDomestic,
      label: '8 lounge visits',
    ),
  ],
);

UserCard _ownedCard({
  Map<String, Money> capConsumed = const {},
  Money? creditLimit,
}) => UserCard(
  id: 'uc1',
  cardProductId: 'p1',
  nickname: 'My Test Card',
  cardName: 'Test Card',
  isDefault: false,
  creditLimit: creditLimit,
  capConsumed: capConsumed,
  statementDay: 5,
  dueDay: 25,
  feeWaiverStates: [
    FeeWaiverProgress(
      feeWaiverRuleId: 'fw1',
      qualifiedSpend: Money.fromRupees(1000),
      thresholdSpend: Money.fromRupees(250000),
      waivesFee: Money.fromRupees(499),
      periodEnd: DateTime(2026, 12, 31),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  String id = 'uc1',
  int initialTabIndex = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(
          _FakeCatalogueRepository(catalogue),
        ),
        categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
        categoriesProvider.overrideWith(
          (ref) => _FakeCategoryRepository().fetchCategories(),
        ),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
      ],
      child: MaterialApp(
        home: CardDetailScreen(
          userCardId: id,
          initialTabIndex: initialTabIndex,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an error state when the card id does not resolve', (
    tester,
  ) async {
    await _pump(
      tester,
      catalogue: [_fullCard()],
      owned: [_ownedCard()],
      id: 'does-not-exist',
    );
    expect(find.textContaining('could not be found'), findsOneWidget);
  });

  testWidgets(
    'renders the nickname as the app bar title and all seven sections',
    (tester) async {
      await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()]);
      expect(find.text('My Test Card'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('REWARDS'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Spend'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('cardDetailScroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Spend'), findsOneWidget);
      expect(find.text('Spent this month'), findsNothing);
    },
  );

  testWidgets(
    'Rewards tab shows the category name and rate, plus freshness date',
    (tester) async {
      await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()]);
      expect(find.text('Bills & Utilities'), findsOneWidget);
      expect(find.textContaining('Reward 5%'), findsOneWidget);
      expect(find.textContaining('Verified March 2026'), findsOneWidget);
    },
  );

  testWidgets('Caps section shows the cap label and consumption', (
    tester,
  ) async {
    await _pump(
      tester,
      catalogue: [_fullCard()],
      owned: [
        _ownedCard(capConsumed: {'cap1': Money.fromPaise(25000)}),
      ],
    );
    await tester.scrollUntilVisible(
      find.text('CAPS'),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('cardDetailScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('5% bills cap'), findsOneWidget);
    expect(find.textContaining('of'), findsWidgets);
  });

  testWidgets('Statement tab shows a prompt when no statement day is set', (
    tester,
  ) async {
    final noStatementCard = UserCard(
      id: 'uc2',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
    );
    await _pump(
      tester,
      catalogue: [_fullCard()],
      owned: [noStatementCard],
      id: 'uc2',
    );
    await tester.scrollUntilVisible(
      find.text('STATEMENT'),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('cardDetailScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Statement date not set'), findsOneWidget);
  });

  testWidgets('can open directly on the Statement tab', (tester) async {
    await _pump(
      tester,
      catalogue: [_fullCard()],
      owned: [_ownedCard()],
      initialTabIndex: 6,
    );

    expect(find.text('Statement cuts on day 5'), findsOneWidget);
    expect(find.text('Payment due on day 25'), findsOneWidget);
  });

  testWidgets(
    'renders credit utilization header bar when card has credit limit and tracked spend',
    (tester) async {
      final cardWithLimit = _ownedCard(creditLimit: Money.fromRupees(100000));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueRepositoryProvider.overrideWithValue(
              _FakeCatalogueRepository([_fullCard()]),
            ),
            categoryRepositoryProvider.overrideWithValue(
              _FakeCategoryRepository(),
            ),
            categoriesProvider.overrideWith(
              (ref) => _FakeCategoryRepository().fetchCategories(),
            ),
            userCardsProvider.overrideWith((ref) async => [cardWithLimit]),
            myCardsProvider.overrideWith((ref) async => [cardWithLimit]),
            creditUtilizationProvider.overrideWith(
              (ref) => {
                'uc1': UtilizationResult(
                  ratio: 0.25,
                  currentBalance: Money.fromRupees(25000),
                  overThreshold: false,
                ),
              },
            ),
          ],
          child: const MaterialApp(home: CardDetailScreen(userCardId: 'uc1')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Credit utilization: 25%'), findsOneWidget);
      expect(find.textContaining('Healthy headroom'), findsOneWidget);
      expect(find.textContaining('75,000 headroom'), findsOneWidget);
      expect(
        find.byKey(const Key('card_credit_utilization_bar')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders empty credit utilization bar when the card has no credit limit',
    (tester) async {
      await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()]);

      expect(find.text('Credit utilization · Add a limit'), findsOneWidget);
      expect(find.text('Add limit'), findsOneWidget);
      expect(find.text('Track credit utilization'), findsNothing);
      expect(
        find.byKey(const Key('card_credit_utilization_bar')),
        findsNothing,
      );
    },
  );

  group('rewards balance tile', () {
    CardProduct productWith({
      required RewardUnit unit,
      double pointValue = 1,
    }) => CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      pointValueInr: pointValue,
      verifiedAt: DateTime(2026, 3, 1),
      baseRewardUnit: unit,
      baseRewardRate: 1,
      rewardRules: const [
        RewardRule(id: 'r1', unit: RewardUnit.cashbackPercent, rate: 1),
      ],
    );

    // The server always sends points_balance (the typed-in starting figure, 0 by
    // default), so a realistic card has pointsBalance: 0 next to what it earned.
    UserCard owned({double earned = 0, double credited = 0}) => UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      nickname: 'My Test Card',
      cardName: 'Test Card',
      isDefault: false,
      totalPointsEarned: earned,
      creditedPoints: credited,
      pointsBalance: 0,
    );

    testWidgets('a cashback card shows its balance in rupees, never as pts', (
      tester,
    ) async {
      await _pump(
        tester,
        catalogue: [productWith(unit: RewardUnit.cashbackPercent)],
        owned: [owned(earned: 120)],
      );
      expect(find.textContaining('₹120 cashback'), findsOneWidget);
      expect(find.textContaining('120 pts'), findsNothing);
    });

    testWidgets('a points card shows points with their rupee value', (
      tester,
    ) async {
      await _pump(
        tester,
        catalogue: [
          productWith(unit: RewardUnit.pointsPer200, pointValue: 0.2),
        ],
        owned: [owned(earned: 1000)],
      );
      expect(find.textContaining('1000 pts'), findsOneWidget);
      expect(find.textContaining('≈ ₹200'), findsOneWidget);
    });

    testWidgets('a starting balance of 0 does not hide what the card earned', (
      tester,
    ) async {
      await _pump(
        tester,
        catalogue: [productWith(unit: RewardUnit.cashbackPercent)],
        owned: [owned(earned: 100)],
      );
      expect(find.textContaining('₹100 cashback'), findsOneWidget);
      expect(find.textContaining('₹0 cashback'), findsNothing);
      // A cashback card has no "1 pt = ₹x" line.
      expect(find.textContaining('1 pt ='), findsNothing);
      expect(find.textContaining('Estimated from your spends'), findsOneWidget);
    });

    testWidgets(
      'points show the earned total, not the typed-in starting balance',
      (tester) async {
        await _pump(
          tester,
          catalogue: [
            productWith(unit: RewardUnit.pointsPer200, pointValue: 0.2),
          ],
          owned: [owned(earned: 350)],
        );
        expect(find.textContaining('350 pts'), findsOneWidget);
        expect(find.text('0 pts'), findsNothing);
      },
    );

    testWidgets('points the bank credited get their own line', (tester) async {
      await _pump(
        tester,
        catalogue: [
          productWith(unit: RewardUnit.pointsPer200, pointValue: 0.2),
        ],
        owned: [owned(earned: 856, credited: 2500)],
      );
      expect(
        find.byKey(const ValueKey('points-credited-line')),
        findsOneWidget,
      );
      expect(find.textContaining('Bank credited 2500 pts'), findsOneWidget);
    });

    testWidgets('no credited line when the bank credited nothing', (
      tester,
    ) async {
      await _pump(
        tester,
        catalogue: [
          productWith(unit: RewardUnit.pointsPer200, pointValue: 0.2),
        ],
        owned: [owned(earned: 856)],
      );
      expect(find.byKey(const ValueKey('points-credited-line')), findsNothing);
    });
  });
}
