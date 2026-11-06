import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/calculator/big_purchase_calculator_screen.dart';
import 'package:pandapay/features/cards/recommendation_confidence.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// D32d: `exclusion_unparsed` (an exclusion rule the card could not read) is
/// not just a string in the engine's assumptions. The app shows such a
/// recommendation as an estimate, never confirmed, and says why in words.
///
/// A card whose exclusion rule was skipped: its `mcc_include` holds a number,
/// which makes the rule unparseable (D15e), and its raw role was `exclusion`.
Map<String, dynamic> _flaggedCardJson(String id) {
  final json = v2CardJson(id, name: 'Flagged Card');
  (json['reward_rules'] as List).add({
    'id': '$id-exclusion',
    'category_id': null,
    'merchant_pattern': null,
    'rail': null,
    'unit': 'points_per_100',
    'rate': 0,
    'priority': 1,
    'rule_role': 'exclusion',
    'mcc_include': [5411], // a number: unparseable, so the rule is skipped
    'min_engine_version': 2,
  });
  return json;
}

Recommendation _rank(CardProduct card) => const RecommendationEngine()
    .rank(
      RecommendationContext(
        amount: Money.fromRupees(2000),
        rail: TxnRail.swipe,
        now: DateTime(2026, 11, 6),
      ),
      [CardSnapshot(product: card)],
    )
    .single;

Recommendation _withConfidence(
  Confidence confidence, {
  required List<String> assumptions,
}) => Recommendation(
  card: parseCard(v2CardJson('x')),
  expectedValue: Money.fromRupees(10),
  confidence: confidence,
  reasonLines: const [],
  reward: RewardEvaluation(
    excluded: false,
    valueInr: 10,
    assumptions: assumptions,
  ),
);

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  group('the engine really flags a card with an unparsed exclusion', () {
    test('the flagged fixture carries exclusion_unparsed', () {
      final card = parseCard(_flaggedCardJson('f'));
      expect(card.skippedExclusionRule, isTrue);
      expect(hasUnparsedExclusion(_rank(card)), isTrue);
    });

    test('a clean v2 card does not', () {
      expect(hasUnparsedExclusion(_rank(parseCard(v2CardJson('c')))), isFalse);
    });

    test('a v1 card (no engine assumptions) does not', () {
      expect(hasUnparsedExclusion(_rank(parseCard(v1CardJson('v')))), isFalse);
    });
  });

  group('confidenceOf', () {
    test('lowers a confirmed recommendation one step when an exclusion could '
        'not be read', () {
      expect(
        confidenceOf(
          _withConfidence(
            Confidence.confirmed,
            assumptions: const ['exclusion_unparsed'],
          ),
        ),
        Confidence.estimated,
      );
    });

    test('an estimate stays an estimate (the floor)', () {
      expect(
        confidenceOf(
          _withConfidence(
            Confidence.estimated,
            assumptions: const ['exclusion_unparsed'],
          ),
        ),
        Confidence.estimated,
      );
    });

    test('otherwise the confidence is untouched', () {
      expect(
        confidenceOf(_withConfidence(Confidence.confirmed, assumptions: const [])),
        Confidence.confirmed,
      );
      expect(
        confidenceOf(
          _withConfidence(
            Confidence.confirmed,
            assumptions: const ['merchant_resolved_by_alias'],
          ),
        ),
        Confidence.confirmed,
      );
    });
  });

  group('RecommendationCaution', () {
    Future<void> pumpCaution(WidgetTester tester, Recommendation rec) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: RecommendationCaution(recommendation: rec)),
          ),
        );

    testWidgets('says so in words for a flagged recommendation', (
      tester,
    ) async {
      await pumpCaution(tester, _rank(parseCard(_flaggedCardJson('f'))));
      expect(find.text(kUnparsedExclusionCaution), findsOneWidget);
    });

    testWidgets('shows nothing for a clean one', (tester) async {
      await pumpCaution(tester, _rank(parseCard(v2CardJson('c'))));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('at the sites that show a recommendation', () {
    UserCard owned(String id) => parseUserCard(userCardJson('u-$id', id));

    List<Override> overrides(CardProduct card) => [
      catalogueProvider.overrideWith((ref) async => [card]),
      userCardsProvider.overrideWith((ref) async => [owned(card.id)]),
      categoriesProvider.overrideWith((ref) async => const []),
      cardOverridesProvider.overrideWith((ref) async => const []),
    ];

    testWidgets('big purchase calculator: a flagged card carries the caution', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(parseCard(_flaggedCardJson('f'))),
          child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unparsed-exclusion-caution')),
          findsOneWidget);
    });

    testWidgets('big purchase calculator: a clean card does not', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(parseCard(v2CardJson('c'))),
          child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unparsed-exclusion-caution')),
          findsNothing);
    });

    testWidgets('scan result: a flagged card carries the caution', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(parseCard(_flaggedCardJson('f'))),
          child: MaterialApp(
            home: ScanResultScreen(
              parsed: ParsedUpiQr(
                pa: 'shop@okaxis',
                pn: 'Corner Cafe',
                mc: '5411',
                am: Money.fromRupees(2000),
                isLikelyP2P: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unparsed-exclusion-caution')),
          findsOneWidget);
    });

    testWidgets('scan result: a clean card does not', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(parseCard(v2CardJson('c'))),
          child: MaterialApp(
            home: ScanResultScreen(
              parsed: ParsedUpiQr(
                pa: 'shop@okaxis',
                pn: 'Corner Cafe',
                mc: '5411',
                am: Money.fromRupees(2000),
                isLikelyP2P: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('unparsed-exclusion-caution')),
          findsNothing);
    });
  });
}
