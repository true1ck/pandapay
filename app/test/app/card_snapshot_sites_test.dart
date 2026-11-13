import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/calculator/big_purchase_calculator_screen.dart';
import 'package:pandapay/features/onboarding/all_set_screen.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// WP9 "never mix measures", at EVERY CardSnapshot site: Home ranking, the
/// best-card-for-merchant pick, the big-purchase calculator, the scan
/// result, and the onboarding "try it now" preview (the caps screen's switch
/// suggestion has its own tests). Card X earns 5 pts/₹100 with a 1,500-point
/// monthly bonus cap; card Y earns a flat 2 pts/₹100. X wins while its bonus
/// headroom is real, Y wins once it is gone or not known.
///
/// What differs between scenarios is only what the wallet row says. The v1
/// `consumed` is set to the OPPOSITE of the native figure each time, so a
/// site that read the v1 measure would pick the wrong card.

CardProduct _x() => parseCard(
  v2CardJson('x', name: 'X Card', categoryId: null),
);

CardProduct _y() => parseCard({
  'id': 'y',
  'name': 'Y Card',
  'network': 'visa',
  'is_upi_linkable': true,
  'point_value_inr': 0.25,
  'base_reward_unit': 'points_per_100',
  'base_reward_rate': 2,
  'accrual_rounding': 'floor',
  'reward_rules': <Map<String, dynamic>>[],
  'cap_rules': <Map<String, dynamic>>[],
});

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// X's wallet row for the current period.
UserCard _ownedX({
  required Object? consumedV1,
  required Object? consumedNative,
  String? kind = 'bonus_points',
  bool withRow = true,
}) {
  final today = DateTime.now();
  return parseUserCard(
    userCardJson(
      'ux',
      'x',
      capStates: [
        if (withRow)
          capStateRowJson(
            'x-cap',
            consumed: consumedV1,
            consumedNative: consumedNative,
            capKind: kind,
            capAmount: kind == null ? null : 1500,
            periodStart: kind == null
                ? null
                : _day(DateTime(today.year, today.month, 1)),
            periodEnd: kind == null
                ? null
                : _day(DateTime(today.year, today.month + 1, 0)),
          ),
      ],
    ),
  );
}

UserCard _ownedY() => parseUserCard(userCardJson('uy', 'y'));

typedef _Scenario = ({String name, UserCard x, String winner});

final List<_Scenario> _scenarios = [
  (
    name: 'no row: nothing consumed, X has its full bonus',
    x: _ownedX(consumedV1: 0, consumedNative: 0, withRow: false),
    winner: 'x',
  ),
  (
    name: 'native 0 used but a huge v1 figure: the v1 figure is ignored',
    x: _ownedX(consumedV1: 99999, consumedNative: 0),
    winner: 'x',
  ),
  (
    name: 'native cap used up but v1 consumed 0: native wins',
    x: _ownedX(consumedV1: 0, consumedNative: 1500),
    winner: 'y',
  ),
  (
    name: 'null consumed_native is unknown, not empty: no capped bonus',
    x: _ownedX(consumedV1: 0, consumedNative: null, kind: null),
    winner: 'y',
  ),
];

Future<ProviderContainer> _container(UserCard x) async {
  final container = ProviderContainer(
    overrides: [
      catalogueProvider.overrideWith((ref) async => [_x(), _y()]),
      userCardsProvider.overrideWith((ref) async => [x, _ownedY()]),
      categoriesProvider.overrideWith((ref) async => const []),
      cardOverridesProvider.overrideWith((ref) async => const []),
      selectedCategoryProvider.overrideWith((ref) => null),
    ],
  );
  addTearDown(container.dispose);
  await container.read(catalogueProvider.future);
  await container.read(userCardsProvider.future);
  await container.read(categoriesProvider.future);
  await container.read(cardOverridesProvider.future);
  return container;
}

void main() {
  group('Home ranking (_userCardSnapshots)', () {
    for (final s in _scenarios) {
      test(s.name, () async {
        final container = await _container(s.x);
        final ranked = container.read(rankedRecommendationsProvider);
        expect(ranked.requireValue.first.card.id, s.winner);
      });
    }
  });

  group('best card for a merchant (_userCardSnapshots + directory)', () {
    for (final s in _scenarios) {
      test(s.name, () async {
        final container = await _container(s.x);
        final pick = container.read(bestCardForMerchantProvider(null));
        expect(pick.requireValue!.card.id, s.winner);
      });

      test('${s.name} (with a merchant name)', () async {
        final container = await _container(s.x);
        final pick = container.read(
          bestCardForMerchantProvider((
            categoryId: null,
            merchantName: 'Corner Cafe',
          )),
        );
        expect(pick.requireValue!.card.id, s.winner);
      });
    }
  });

  group('big purchase calculator', () {
    for (final s in _scenarios) {
      testWidgets(s.name, (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catalogueProvider.overrideWith((ref) async => [_x(), _y()]),
              userCardsProvider.overrideWith(
                (ref) async => [s.x, _ownedY()],
              ),
              categoriesProvider.overrideWith((ref) async => const []),
              cardOverridesProvider.overrideWith((ref) async => const []),
            ],
            child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final loser = s.winner == 'x' ? 'y' : 'x';
        final winnerY = tester.getTopLeft(find.byKey(ValueKey(s.winner))).dy;
        final loserY = tester.getTopLeft(find.byKey(ValueKey(loser))).dy;
        expect(winnerY, lessThan(loserY));
      });
    }
  });

  group('scan result', () {
    for (final s in _scenarios) {
      testWidgets(s.name, (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catalogueProvider.overrideWith((ref) async => [_x(), _y()]),
              userCardsProvider.overrideWith(
                (ref) async => [s.x, _ownedY()],
              ),
              categoriesProvider.overrideWith((ref) async => const []),
              cardOverridesProvider.overrideWith((ref) async => const []),
            ],
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

        final loser = s.winner == 'x' ? 'Y Card' : 'X Card';
        final win = s.winner == 'x' ? 'X Card' : 'Y Card';
        final winnerY = tester.getTopLeft(find.text(win).first).dy;
        final loserY = tester.getTopLeft(find.text(loser).first).dy;
        expect(winnerY, lessThan(loserY));
      });
    }
  });

  group('onboarding "try it now" preview', () {
    for (final s in _scenarios) {
      testWidgets(s.name, (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catalogueProvider.overrideWith((ref) async => [_x(), _y()]),
              userCardsProvider.overrideWith(
                (ref) async => [s.x, _ownedY()],
              ),
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

        final winnerName = s.winner == 'x' ? 'X Card' : 'Y Card';
        expect(find.text('with $winnerName'), findsOneWidget);
      });
    }
  });

  test('no CardSnapshot is built outside data/card_snapshots.dart', () {
    // The single place that decides the measure. A new direct
    // `CardSnapshot(` anywhere else in lib/ would bypass it.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.replaceAll(r'\', '/').endsWith('data/card_snapshots.dart')) continue;
      if (RegExp(r'\bCardSnapshot\(').hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('the domain package builds a CardSnapshot only in the engine, the '
      'acquisition engine and the split optimizer, and the optimizer\'s v2 '
      'rebuild carries capConsumed (D30a)', () {
    // A rebuild that drops capConsumed makes a v2 card forget what it has
    // used (the split planner then piles spend onto a used-up card).
    final offenders = <String>[];
    for (final entity in Directory(
      '../packages/pandapay_domain/lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (RegExp(r'\bCardSnapshot\(').hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path.replaceAll(r'\', '/').split('/').last);
      }
    }
    offenders.sort();
    expect(offenders, [
      'acquisition_engine.dart',
      'calculators.dart',
      'engine.dart',
    ]);
    final optimizer = File(
      '../packages/pandapay_domain/lib/src/engine/calculators.dart',
    ).readAsStringSync();
    expect(optimizer, contains('capConsumed: next'));
    expect(optimizer, contains('if (snapshot.product.isV2Shaped)'));
  });
}
