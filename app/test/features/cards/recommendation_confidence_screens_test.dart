import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/merchant_search_repository.dart';
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay/features/geofence/nearby_merchants_screen.dart';
import 'package:pandapay/features/onboarding/all_set_screen.dart';
import 'package:pandapay/features/search/merchant_search_screen.dart';
import 'package:pandapay/main.dart' show MoneyText;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// D35b: every screen that shows a recommendation's confidence reads it
/// through `confidenceOf` and shows the caution under the figure when an
/// exclusion rule could not be read (`exclusion_unparsed`): merchant search,
/// nearby merchants, the comparison view and the onboarding all-set preview
/// (Home, scan result, the calculator, quick add and the widget settings are
/// covered in recommendation_confidence_test.dart and by the grep guard below).
const _cautionKey = ValueKey('unparsed-exclusion-caution');

class _FakeMerchantSearchRepository implements MerchantSearchRepository {
  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async => const [
    NearbyMerchantCandidate(
      merchantId: 'm1',
      displayName: 'Corner Cafe',
      categoryId: 'cat-dining',
      location: GeoPoint(lat: 19.1, lng: 72.9),
    ),
  ];

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async => null;
}

void _expectEstimateAndCaution({required bool flagged}) {
  expect(
    find.byKey(_cautionKey),
    flagged ? findsOneWidget : findsNothing,
    reason: flagged ? 'caution shown' : 'no caution on a clean card',
  );
}

/// The money figure beside the card shows the estimate marker, never a
/// confirmed one.
void _expectEstimateMarker(WidgetTester tester) {
  final figures = tester.widgetList<MoneyText>(find.byType(MoneyText));
  expect(figures, isNotEmpty);
  for (final figure in figures) {
    expect(figure.confidence, Confidence.estimated);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BambooFonts.useSystemFontsForTests = true;
  });
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  test('no screen reads a Recommendation\'s raw .confidence (grep guard)', () {
    // A recommendation's confidence is read through confidenceOf(...) so
    // exclusion_unparsed is honoured everywhere. The names below are the
    // variables the app uses for a Recommendation.
    final raw = RegExp(
      r'\b(?:rec|recommendation|winner|backup|best|best\.value!?|currentRecommendation)\.confidence\b',
    );
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('recommendation_confidence.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in raw.allMatches(source)) {
        offenders.add('${entity.path}: ${match.group(0)}');
      }
    }
    expect(offenders, isEmpty);
  });

  group('merchant search', () {
    Future<void> pump(WidgetTester tester, CardProduct card) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            merchantSearchRepositoryProvider.overrideWithValue(
              _FakeMerchantSearchRepository(),
            ),
            catalogueProvider.overrideWith((ref) async => [card]),
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: MerchantSearchScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'cafe');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('a flagged card shows the estimate marker and the caution', (
      tester,
    ) async {
      await pump(tester, parseCard(flaggedExclusionCardJson('f')));
      expect(find.text('Corner Cafe'), findsOneWidget);
      _expectEstimateAndCaution(flagged: true);
      _expectEstimateMarker(tester);
    });

    testWidgets('a clean card shows no caution', (tester) async {
      await pump(tester, parseCard(v2CardJson('c')));
      expect(find.text('Corner Cafe'), findsOneWidget);
      _expectEstimateAndCaution(flagged: false);
    });
  });

  group('nearby merchants', () {
    Future<void> pump(WidgetTester tester, CardProduct card) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith((ref) async => [card]),
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: NearbyMerchantTile(
                NearbyMerchantMatch(
                  candidate: NearbyMerchantCandidate(
                    merchantId: 'm1',
                    displayName: 'Corner Cafe',
                    categoryId: 'cat-dining',
                    location: GeoPoint(lat: 19.1, lng: 72.9),
                  ),
                  distanceMeters: 120,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a flagged card shows the estimate marker and the caution', (
      tester,
    ) async {
      await pump(tester, parseCard(flaggedExclusionCardJson('f')));
      expect(find.textContaining('Use Flagged Card'), findsOneWidget);
      _expectEstimateAndCaution(flagged: true);
      _expectEstimateMarker(tester);
    });

    testWidgets('a clean card shows no caution', (tester) async {
      await pump(tester, parseCard(v2CardJson('c')));
      expect(find.textContaining('Use Rewards Card'), findsOneWidget);
      _expectEstimateAndCaution(flagged: false);
    });
  });

  group('comparison view', () {
    Recommendation rec(Confidence confidence, {required bool flagged}) =>
        Recommendation(
          card: parseCard(v2CardJson('x', name: 'Compared Card')),
          expectedValue: Money.fromRupees(100),
          confidence: confidence,
          reasonLines: const ['Base rate 5.0%'],
          reward: RewardEvaluation(
            excluded: false,
            valueInr: 100,
            assumptions: flagged ? const ['exclusion_unparsed'] : const [],
          ),
        );

    Future<void> pump(WidgetTester tester, Recommendation r) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rankedRecommendationsProvider.overrideWithValue(
              AsyncValue.data([r]),
            ),
          ],
          child: const MaterialApp(home: ComparisonViewScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a flagged row shows the caution and is never confirmed', (
      tester,
    ) async {
      // A confirmed confidence is lowered one step by the flag.
      await pump(tester, rec(Confidence.confirmed, flagged: true));
      _expectEstimateAndCaution(flagged: true);
      _expectEstimateMarker(tester);
    });

    testWidgets('a clean confirmed row stays confirmed (untouched)', (
      tester,
    ) async {
      await pump(tester, rec(Confidence.confirmed, flagged: false));
      _expectEstimateAndCaution(flagged: false);
      final figure = tester.widget<MoneyText>(find.byType(MoneyText).first);
      expect(figure.confidence, Confidence.confirmed);
    });
  });

  group('onboarding all-set preview', () {
    Future<void> pump(WidgetTester tester, CardProduct card) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final owned = parseUserCard(userCardJson('u-${card.id}', card.id));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith((ref) async => [card]),
            userCardsProvider.overrideWith((ref) async => [owned]),
            categoriesProvider.overrideWith(
              (ref) async => const [
                SpendCategory(id: 'g', slug: 'groceries', name: 'Groceries'),
              ],
            ),
          ],
          child: const MaterialApp(home: AllSetScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a flagged card shows the estimate marker and the caution', (
      tester,
    ) async {
      await pump(tester, parseCard(flaggedExclusionCardJson('f')));
      expect(find.text('with Flagged Card'), findsOneWidget);
      _expectEstimateAndCaution(flagged: true);
    });

    testWidgets('a clean card shows no caution', (tester) async {
      await pump(tester, parseCard(v2CardJson('c')));
      expect(find.text('with Rewards Card'), findsOneWidget);
      _expectEstimateAndCaution(flagged: false);
    });
  });
}
