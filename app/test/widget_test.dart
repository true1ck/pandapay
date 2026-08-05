import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/main.dart';

/// Chunk 15 added a startup session-resume step (sessionInitProvider) that
/// resolves a stored refresh token via a real SharedPreferences instance —
/// overridden to a no-op here so the catalogue/nav tests above stay pure
/// UI tests, same reasoning as console/test/widget_test.dart.
final _noSessionInit = sessionInitProvider.overrideWith((ref) async {});

const _onlineCategoryId = 'cat-online-uuid';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);

  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [
        SpendCategory(id: _onlineCategoryId, slug: 'online', name: 'Online'),
        SpendCategory(id: 'cat-fuel-uuid', slug: 'fuel', name: 'Fuel'),
      ];
}

CardProduct _rupayCard() => CardProduct(
      id: 'test-rupay',
      name: 'Test RuPay Card',
      network: CardNetwork.rupay,
      isUpiLinkable: true,
      rewardRules: [
        RewardRule(id: 'r1', categoryId: _onlineCategoryId, unit: RewardUnit.cashbackPercent, rate: 5),
      ],
    );

Widget _appWithFakeCatalogue(List<CardProduct> cards, {List<Override> extraOverrides = const []}) {
  return ProviderScope(
    overrides: [
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(cards)),
      categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
      _noSessionInit,
      ...extraOverrides,
    ],
    child: const PandaPayApp(),
  );
}

void main() {
  testWidgets('Home renders a ranked recommendation from a fake catalogue (no real network call)',
      (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pump(); // let both FutureProviders resolve
    await tester.pump();

    expect(find.text('PandaPay — Home'), findsOneWidget);
    expect(find.text('Test RuPay Card'), findsOneWidget);
    expect(find.textContaining('Base rate 5.0%'), findsOneWidget);
  });

  testWidgets('a card with no matching-category reward rule renders its exclusion reason, not a value',
      (tester) async {
    final noRuleCard = CardProduct(id: 'bare', name: 'Bare Card', network: CardNetwork.rupay);
    await tester.pumpWidget(_appWithFakeCatalogue([noRuleCard]));
    await tester.pump();
    await tester.pump();

    expect(find.text('Bare Card'), findsOneWidget);
    expect(find.text('No applicable reward rule.'), findsOneWidget);
  });

  testWidgets('bottom nav switches away from Home to a placeholder tab', (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.credit_card));
    await tester.pump();

    expect(find.text('PandaPay — Cards'), findsOneWidget);
    expect(find.text('₹12,34,567.00'), findsOneWidget);
  });

  testWidgets('Chunk 15: More tab shows the login screen when signed out', (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Send OTP'), findsOneWidget);
  });

  testWidgets('Chunk 15: More tab shows the real profile and a sign-out button when signed in',
      (tester) async {
    await tester.pumpWidget(
      _appWithFakeCatalogue(
        [_rupayCard()],
        extraOverrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-access-token'),
          profileApiProvider.overrideWithValue(
            ProfileApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-access-token',
              client: MockClient((request) async {
                return http.Response(
                  jsonEncode({
                    'profile': {'id': 'profile-123', 'display_name': null},
                  }),
                  200,
                );
              }),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Signed in.'), findsOneWidget);
    expect(find.textContaining('profile-123'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });
}
