import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_detail_screen.dart';
import 'package:pandapay/features/cards/my_cards_screen.dart';
import 'package:pandapay/features/cards/widgets/cap_bar.dart';
import 'package:pandapay/features/insights/caps_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// WP9 (B1): cap bars in native units on the My Cards tile (the fullest
/// cap), card detail (every cap) and the caps screen, with "Updating…" for an
/// unknown cap; v1 cards keep today's display.
const _dining = SpendCategory(id: 'cat-dining', slug: 'dining', name: 'Dining');

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A row for the current period, so the screens (which read the real clock)
/// treat it as live.
Map<String, dynamic> _row(String capId, {Object? native, String? kind = 'bonus_points', num amount = 1500}) {
  final today = DateTime.now();
  return capStateRowJson(
    capId,
    consumed: 0,
    consumedNative: native,
    capKind: native == null ? null : kind,
    capAmount: native == null ? null : amount,
    periodStart: native == null ? null : _day(DateTime(today.year, today.month, 1)),
    periodEnd: native == null ? null : _day(DateTime(today.year, today.month + 1, 0)),
  );
}

CardProduct _v2() =>
    parseCard(v2CardJson('a', name: 'Rewards Card', categoryId: 'cat-dining'));

UserCard _owned(Object? native) => parseUserCard(
  userCardJson('ua', 'a', capStates: [_row('a-cap', native: native)]),
);

// A second card that earns 3% on dining (more than base 1%).
CardProduct _other() => CardProduct(
  id: 'b',
  name: 'Dining Specialist',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: const [
    RewardRule(
      id: 'b-dining',
      categoryId: 'cat-dining',
      unit: RewardUnit.cashbackPercent,
      rate: 3,
    ),
  ],
);

UserCard _ownedOther() => UserCard(
  id: 'ub',
  cardProductId: 'b',
  cardName: 'Dining Specialist',
  isDefault: false,
);

List<Override> _overrides(List<CardProduct> catalogue, List<UserCard> owned) => [
  catalogueProvider.overrideWith((ref) async => catalogue),
  userCardsProvider.overrideWith((ref) async => owned),
  myCardsProvider.overrideWith((ref) async => owned),
  categoriesProvider.overrideWith((ref) async => const [_dining]),
  sessionInitProvider.overrideWith((ref) async {}),
];

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  await tester.binding.setSurfaceSize(const Size(800, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: MaterialApp(home: home)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  group('caps screen', () {
    testWidgets('a v2 cap shows its native line', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: CapsScreen()),
        _overrides([_v2()], [_owned(300)]),
      );
      expect(find.byType(CapBar), findsOneWidget);
      expect(find.textContaining('300 / 1,500 pts'), findsOneWidget);
      expect(find.textContaining('then 1 pt/₹100'), findsOneWidget);
    });

    testWidgets('an unknown cap says "Updating…" and shows no suggestion', (
      tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(body: CapsScreen()),
        _overrides([_v2(), _other()], [_owned(null), _ownedOther()]),
      );
      expect(find.text('Updating…'), findsOneWidget);
      expect(find.byKey(const ValueKey('cap-next-best')), findsNothing);
    });

    testWidgets('a nearly-used cap names the next-best owned card', (
      tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(body: CapsScreen()),
        _overrides([_v2(), _other()], [_owned(1450), _ownedOther()]),
      );
      expect(
        find.text('Use Dining Specialist for Dining instead'),
        findsOneWidget,
      );
    });

    testWidgets('no suggestion when no other card earns more than base', (
      tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(body: CapsScreen()),
        _overrides([_v2()], [_owned(1450)]),
      );
      expect(find.byKey(const ValueKey('cap-next-best')), findsNothing);
    });

    testWidgets('a v1 card keeps the v1 tile (no CapBar)', (tester) async {
      final v1 = parseCard(v1CardJson('v', withCap: true));
      final owned = parseUserCard(
        userCardJson(
          'uv',
          'v',
          capStates: [capStateRowJson('v-cap', consumed: 120)],
        ),
      );
      await _pump(
        tester,
        const Scaffold(body: CapsScreen()),
        _overrides([v1], [owned]),
      );
      expect(find.byType(CapBar), findsNothing);
      expect(find.textContaining('left'), findsOneWidget);
    });
  });

  group('card detail', () {
    testWidgets('every v2 cap is a bar in its native unit', (tester) async {
      await _pump(
        tester,
        const CardDetailScreen(userCardId: 'ua', initialTabIndex: 2),
        _overrides([_v2()], [_owned(1240)]),
      );
      // The caps section lists the cap; its detail is inside the tile.
      expect(find.text('Rewards Card'), findsWidgets);
      final tile = find.text('83%');
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(CapBar), findsOneWidget);
      expect(
        find.textContaining('1,240 / 1,500 pts · resets'),
        findsOneWidget,
      );
    });

    testWidgets('an unknown cap reads "Updating…" in the tile', (tester) async {
      await _pump(
        tester,
        const CardDetailScreen(userCardId: 'ua', initialTabIndex: 2),
        _overrides([_v2()], [_owned(null)]),
      );
      expect(find.text('Updating…'), findsOneWidget);
    });
  });

  group('my cards tile', () {
    testWidgets('shows the fullest cap as a native-unit bar', (tester) async {
      final json = v2CardJson('a', name: 'Rewards Card', categoryId: 'cat-dining');
      (json['cap_rules'] as List).add({
        ...(json['cap_rules'] as List).single as Map<String, dynamic>,
        'id': 'a-cap-2',
        'label': 'Total points cap',
        'cap_kind': 'total_points',
        'cap_amount': 4000,
      });
      final owned = parseUserCard(
        userCardJson(
          'ua',
          'a',
          capStates: [
            _row('a-cap', native: 300),
            _row('a-cap-2', native: 3600, kind: 'total_points', amount: 4000),
          ],
        ),
      );
      await _pump(
        tester,
        const Scaffold(body: MyCardsScreen()),
        _overrides([parseCard(json)], [owned]),
      );
      // 3,600 / 4,000 (90%) is the fullest, not 300 / 1,500 (20%).
      expect(find.textContaining('3,600 / 4,000 pts'), findsOneWidget);
      expect(find.textContaining('300 / 1,500'), findsNothing);
      expect(find.byType(CapBar), findsOneWidget);
    });

    testWidgets('an unknown cap is shown as "Updating…", not hidden behind a '
        'known one', (tester) async {
      final json = v2CardJson('a', name: 'Rewards Card', categoryId: 'cat-dining');
      (json['cap_rules'] as List).add({
        ...(json['cap_rules'] as List).single as Map<String, dynamic>,
        'id': 'a-cap-2',
        'cap_kind': 'total_points',
        'cap_amount': 4000,
      });
      final owned = parseUserCard(
        userCardJson(
          'ua',
          'a',
          capStates: [
            _row('a-cap', native: 300),
            _row('a-cap-2', native: null),
          ],
        ),
      );
      await _pump(
        tester,
        const Scaffold(body: MyCardsScreen()),
        _overrides([parseCard(json)], [owned]),
      );
      expect(find.text('Updating…'), findsOneWidget);
      expect(find.textContaining('300 / 1,500'), findsNothing);
    });
  });
}
