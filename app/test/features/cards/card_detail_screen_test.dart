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
  Future<List<SpendCategory>> fetchCategories() async =>
      const [SpendCategory(id: 'cat-bills', slug: 'bills', name: 'Bills & Utilities')];
}

CardProduct _fullCard() => CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      pointValueInr: 1,
      verifiedAt: DateTime(2026, 3, 1),
      rewardRules: const [
        RewardRule(id: 'r1', categoryId: 'cat-bills', unit: RewardUnit.cashbackPercent, rate: 5),
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
        MilestoneRule(id: 'm1', label: 'Spend ₹1L', thresholdSpend: Money.fromRupees(100000), rewardValue: Money.fromRupees(1000)),
      ],
      benefits: const [
        CardBenefit(id: 'b1', kind: BenefitKind.loungeDomestic, label: '8 lounge visits'),
      ],
    );

UserCard _ownedCard({Map<String, Money> capConsumed = const {}}) => UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      nickname: 'My Test Card',
      cardName: 'Test Card',
      isDefault: false,
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

Future<void> _pump(WidgetTester tester, {required List<CardProduct> catalogue, required List<UserCard> owned, String id = 'uc1'}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
      ],
      child: MaterialApp(home: CardDetailScreen(userCardId: id)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an error state when the card id does not resolve', (tester) async {
    await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()], id: 'does-not-exist');
    expect(find.textContaining('could not be found'), findsOneWidget);
  });

  testWidgets('renders the nickname as the app bar title and all seven tabs', (tester) async {
    await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()]);
    expect(find.text('My Test Card'), findsOneWidget);
    // Spend sits second, right after Rewards: the other six describe the
    // card's TERMS, and this one is the only tab that says what the card
    // has actually done.
    for (final label in ['Rewards', 'Spend', 'Caps', 'Milestones', 'Fees', 'Benefits', 'Statement']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('Rewards tab shows the category name and rate, plus freshness date', (tester) async {
    await _pump(tester, catalogue: [_fullCard()], owned: [_ownedCard()]);
    expect(find.text('Bills & Utilities'), findsOneWidget);
    expect(find.text('5%'), findsOneWidget);
    expect(find.textContaining('Verified March 2026'), findsOneWidget);
  });

  testWidgets('Caps tab, when selected, shows the cap label and consumption', (tester) async {
    await _pump(
      tester,
      catalogue: [_fullCard()],
      owned: [_ownedCard(capConsumed: {'cap1': Money.fromPaise(25000)})],
    );
    await tester.tap(find.text('Caps'));
    await tester.pumpAndSettle();
    expect(find.text('5% bills cap'), findsOneWidget);
    expect(find.textContaining('of'), findsWidgets);
  });

  testWidgets('Statement tab shows a prompt when no statement day is set', (tester) async {
    final noStatementCard = UserCard(
      id: 'uc2',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
    );
    await _pump(tester, catalogue: [_fullCard()], owned: [noStatementCard], id: 'uc2');
    // The tab bar is scrollable and, since the Spend tab was added, wider
    // than the 800px test viewport — Statement sits past the right edge, so
    // it has to be scrolled into view before it can be tapped.
    await tester.dragUntilVisible(
      find.text('Statement'),
      find.byType(TabBar),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Statement'));
    await tester.pumpAndSettle();
    expect(find.text('Statement date not set'), findsOneWidget);
  });
}
