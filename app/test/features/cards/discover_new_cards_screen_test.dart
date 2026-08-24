import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/cards/discover_new_cards_screen.dart';

const _diningCategoryId = 'cat-dining-uuid';

CardProduct _card(String id, String name) => CardProduct(
      id: id,
      name: name,
      network: CardNetwork.rupay,
      issuerName: 'Test Bank',
      rewardRules: [
        RewardRule(id: '$id-r', categoryId: _diningCategoryId, unit: RewardUnit.cashbackPercent, rate: 8),
      ],
    );

Widget _screenWith({required AsyncValue<List<AcquisitionCandidate>> candidates}) {
  return ProviderScope(
    overrides: [
      acquisitionCandidatesProvider.overrideWithValue(candidates),
      categoriesProvider.overrideWith(
        (ref) async => const [SpendCategory(id: _diningCategoryId, slug: 'dining', name: 'Dining')],
      ),
    ],
    child: const MaterialApp(home: DiscoverNewCardsScreen()),
  );
}

void main() {
  testWidgets('renders a worthwhile candidate with its uplift and a why-this-card breakdown', (tester) async {
    final card = _card('candidate-1', 'Test Dining Card');
    final candidate = AcquisitionCandidate(
      card: card,
      projectedAnnualValue: Money.fromRupees(4000),
      annualFeeNet: const Money.zero(),
      uplift: Money.fromRupees(2500),
      valueByCategory: {_diningCategoryId: Money.fromRupees(4000)},
    );

    await tester.pumpWidget(_screenWith(candidates: AsyncValue.data([candidate])));
    await tester.pumpAndSettle();

    expect(find.text('Test Dining Card'), findsOneWidget);
    expect(find.text('Test Bank'), findsOneWidget);
    expect(find.textContaining('2,500'), findsOneWidget); // the uplift, MoneyText-rendered
    expect(find.text('Apply'), findsOneWidget);

    // Collapsed by default — the category breakdown line isn't visible yet.
    expect(find.textContaining('Dining:'), findsNothing);

    await tester.tap(find.text('Why this card?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dining:'), findsOneWidget);
    expect(find.textContaining('4,000'), findsOneWidget);
  });

  testWidgets('a non-worthwhile candidate (negative uplift) is not shown, and the empty state renders instead',
      (tester) async {
    final card = _card('candidate-2', 'Bad Fit Card');
    final candidate = AcquisitionCandidate(
      card: card,
      projectedAnnualValue: const Money.zero(),
      annualFeeNet: Money.fromRupees(500),
      uplift: Money.fromRupees(-500),
      valueByCategory: const {},
    );

    await tester.pumpWidget(_screenWith(candidates: AsyncValue.data([candidate])));
    await tester.pumpAndSettle();

    expect(find.text('Bad Fit Card'), findsNothing);
    expect(find.text('Nothing to recommend yet'), findsOneWidget);
  });

  testWidgets('tapping Apply while signed out shows a sign-in prompt rather than crashing', (tester) async {
    final card = _card('candidate-3', 'Sign-In Test Card');
    final candidate = AcquisitionCandidate(
      card: card,
      projectedAnnualValue: Money.fromRupees(1000),
      annualFeeNet: const Money.zero(),
      uplift: Money.fromRupees(1000),
      valueByCategory: {_diningCategoryId: Money.fromRupees(1000)},
    );

    await tester.pumpWidget(_screenWith(candidates: AsyncValue.data([candidate])));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pump(); // let the SnackBar animate in
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Sign in to apply for a card.'), findsOneWidget);
  });

  testWidgets('an error from the recommender shows the retryable error state', (tester) async {
    await tester.pumpWidget(_screenWith(candidates: AsyncValue.error(Exception('boom'), StackTrace.empty)));
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
  });
}
