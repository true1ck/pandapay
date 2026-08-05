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
import 'package:pandapay/data/user_cards_repository.dart';
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

  testWidgets('Chunk 19: typing a real amount into Home updates the ranking amount', (tester) async {
    final container = ProviderContainer(overrides: [
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_rupayCard()])),
      categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
      _noSessionInit,
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const PandaPayApp()));
    await tester.pump();
    await tester.pump();

    expect(container.read(enteredAmountProvider), const Money.fromPaise(100000));

    await tester.enterText(find.byType(TextField).first, '2500');
    await tester.pump();

    expect(container.read(enteredAmountProvider), Money.fromRupees(2500));
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

  testWidgets('Chunk 18: bottom nav switches away from Home to Activity, which shows login when signed out',
      (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.receipt_long));
    await tester.pump();
    await tester.pump();

    expect(find.text('PandaPay — Activity'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('Chunk 18: Activity tab shows real logged transactions when signed in', (tester) async {
    await tester.pumpWidget(
      _appWithFakeCatalogue(
        [_rupayCard()],
        extraOverrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-access-token'),
          userCardsRepositoryProvider.overrideWithValue(
            UserCardsRepository(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-access-token',
              client: MockClient((request) async {
                return http.Response(
                  jsonEncode({
                    'transactions': [
                      {
                        'id': 'txn-1',
                        'amount_inr': '1000.00',
                        'occurred_at': '2026-08-05T10:00:00Z',
                        'merchant_name': null,
                        'category_name': 'Online',
                        'card_name': 'Test RuPay Card',
                        'card_nickname': null,
                      },
                    ],
                    'userCards': <Map<String, dynamic>>[],
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

    await tester.tap(find.byIcon(Icons.receipt_long));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Test RuPay Card · Online'), findsOneWidget);
    expect(find.text('₹1,000.00'), findsOneWidget);
  });

  testWidgets('Chunk 16: Cards tab shows the login screen when signed out', (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.credit_card));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('Chunk 16: Cards tab shows a real owned card and lets it be archived', (tester) async {
    var archiveCalled = false;
    await tester.pumpWidget(
      _appWithFakeCatalogue(
        [_rupayCard()],
        extraOverrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-access-token'),
          userCardsRepositoryProvider.overrideWithValue(
            UserCardsRepository(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-access-token',
              client: MockClient((request) async {
                if (request.method == 'POST' && request.url.path.endsWith('/archive')) {
                  archiveCalled = true;
                  return http.Response(jsonEncode({'ok': true}), 200);
                }
                return http.Response(
                  jsonEncode({
                    'userCards': [
                      {
                        'id': 'user-card-1',
                        'card_product_id': 'test-rupay',
                        'nickname': null,
                        'card_name': 'Test RuPay Card',
                        'is_default': false,
                      },
                    ],
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

    await tester.tap(find.byIcon(Icons.credit_card));
    await tester.pump();
    await tester.pump();

    expect(find.text('Test RuPay Card'), findsWidgets);

    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pump();
    expect(archiveCalled, isTrue);
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
