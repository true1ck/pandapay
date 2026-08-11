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
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/main.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chunk 15 added a startup session-resume step (sessionInitProvider) that
/// resolves a stored refresh token via a real SharedPreferences instance —
/// overridden to a no-op here so the catalogue/nav tests above stay pure
/// UI tests, same reasoning as console/test/widget_test.dart.
final _noSessionInit = sessionInitProvider.overrideWith((ref) async {});

/// Tasks 4-6 put a real onboarding redirect guard in front of the shell —
/// see test/app/router_onboarding_test.dart for that behaviour on its own.
/// This file's tests are about the four TABS, not onboarding, so every test
/// here simulates a device that has already finished it.
void _simulateOnboardingComplete() {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': true,
  });
}

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
  _simulateOnboardingComplete();
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


/// Finds a bottom-navigation destination by its visible label, scoped to the
/// BottomAppBar so it can never collide with same-named text in screen body
/// content. Deliberately not `find.byIcon` — the icon set is a styling detail
/// that changed wholesale in the design-system pass, and a nav test should not
/// break because a rounded icon variant was adopted.
Finder _navTab(String label) => find.descendant(
      of: find.byKey(const ValueKey('appShellNavBar')),
      matching: find.text(label),
    );

void main() {
  testWidgets('Home renders a ranked recommendation from a fake catalogue (no real network call)',
      (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Test RuPay Card'), findsOneWidget);
    expect(find.textContaining('Base rate 5.0%'), findsOneWidget);
  });

  testWidgets('Chunk 19: typing a real amount into Home updates the ranking amount', (tester) async {
    _simulateOnboardingComplete();
    final container = ProviderContainer(overrides: [
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_rupayCard()])),
      categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
      _noSessionInit,
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const PandaPayApp()));
    await tester.pumpAndSettle();

    expect(container.read(enteredAmountProvider), const Money.fromPaise(100000));

    await tester.enterText(find.byType(TextField).first, '2500');
    await tester.pump();

    expect(container.read(enteredAmountProvider), Money.fromRupees(2500));
  });

  testWidgets('a card with no matching-category reward rule renders its exclusion reason, not a value',
      (tester) async {
    final noRuleCard = CardProduct(id: 'bare', name: 'Bare Card', network: CardNetwork.rupay);
    await tester.pumpWidget(_appWithFakeCatalogue([noRuleCard]));
    await tester.pumpAndSettle();

    expect(find.text('Bare Card'), findsOneWidget);
    expect(find.text('No applicable reward rule.'), findsOneWidget);
  });

  testWidgets(
      'Chunk 18/Task 7: Insights Hub -> All Activity shows login when signed out',
      (tester) async {
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pumpAndSettle();

    // Activity moved out of the bottom nav under Insights Hub (Task 7) —
    // Material's 5-item ceiling meant Insights displaced it, not joined it.
    await tester.tap(_navTab('Insights'));
    await tester.pumpAndSettle();
    // The tile grid now sits below design 04's content (earned hero,
    // category bars, missed/best pair) and is a shrinkWrap GridView, so
    // every tile is built from first pump but laid out off-screen.
    // scrollUntilVisible would match immediately and never scroll;
    // ensureVisible is what actually brings the tile into the viewport.
    await tester.ensureVisible(find.text('All Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Activity'));
    await tester.pumpAndSettle();

    expect(find.text('Activity'), findsWidgets);
    expect(find.byType(LoginScreen), findsOneWidget);
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
                        'user_card_id': 'uc-1',
                        'source': 'manual',
                        'status': 'active',
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
    await tester.pumpAndSettle();

    await tester.tap(_navTab('Insights'));
    await tester.pumpAndSettle();
    // The tile grid now sits below design 04's content (earned hero,
    // category bars, missed/best pair) and is a shrinkWrap GridView, so
    // every tile is built from first pump but laid out off-screen.
    // scrollUntilVisible would match immediately and never scroll;
    // ensureVisible is what actually brings the tile into the viewport.
    await tester.ensureVisible(find.text('All Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Activity'));
    await tester.pumpAndSettle();

    expect(find.text('Test RuPay Card · Online'), findsOneWidget);
    // The D1 summary card's total-spend header shows the same figure as
    // the sole transaction tile below it when there's only one entry, so
    // both legitimately render '₹1,000.00' — this only checks it appears
    // (not exactly once).
    expect(find.text('₹1,000.00'), findsWidgets);
  });

  testWidgets('Chunk 16 + guest mode: Cards tab renders (no login wall) when signed out', (tester) async {
    // A3 guest/local mode (see LocalUserCardsRepository) made this screen a
    // real destination for signed-out users too — the login gate this test
    // originally asserted was removed on purpose, not a regression.
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pumpAndSettle();

    await tester.tap(_navTab('Wallet'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsNothing);
    // Design 02 puts adding a card in the header pill, which opens a sheet —
    // the permanently docked "Add a card" bar this used to assert on is
    // gone on purpose.
    expect(find.text('Wallet'), findsWidgets);
    expect(find.text('Add card'), findsOneWidget);
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
    await tester.pumpAndSettle();

    await tester.tap(_navTab('Wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Test RuPay Card'), findsWidgets);

    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pump();
    expect(archiveCalled, isTrue);
  });

  testWidgets('Chunk 28: Cards tab shows lifetime points earned and fee-waiver progress',
      (tester) async {
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
                    'userCards': [
                      {
                        'id': 'user-card-1',
                        'card_product_id': 'test-rupay',
                        'nickname': null,
                        'card_name': 'Test RuPay Card',
                        'is_default': false,
                        'total_points_earned': 10000,
                        'fee_waiver_states': [
                          {
                            'fee_waiver_rule_id': 'fw-1',
                            'qualified_spend': 200000,
                            'threshold_spend_inr': 100000,
                            'waives_fee_inr': 500,
                            'waived_at': '2026-08-05T19:44:27.168Z',
                            'period_end': '2026-08-31T00:00:00.000Z',
                          },
                        ],
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
    await tester.pumpAndSettle();

    await tester.tap(_navTab('Wallet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('10000 pts earned'), findsOneWidget);
    expect(find.textContaining('Fee waived'), findsOneWidget);
  });

  testWidgets('Chunk 15 + guest mode: Account tab shows the guest banner, not a login wall', (tester) async {
    // Same A3 guest/local mode change as the Cards tab above — the login
    // gate this test originally asserted was removed on purpose.
    await tester.pumpWidget(_appWithFakeCatalogue([_rupayCard()]));
    await tester.pumpAndSettle();

    await tester.tap(_navTab('You'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text("You're browsing as a guest"), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
      'Chunk 15 + H1: Account tab shows the real profile and the Settings hub rows when signed in',
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
    await tester.pumpAndSettle();

    await tester.tap(_navTab('You'));
    await tester.pumpAndSettle();
    await tester.pump();

    // Design 05 replaced the bare "Signed in · ID · <uuid>" strip with a
    // profile card: name, card count, and the two stat tiles.
    expect(find.text('Lifetime earned'), findsOneWidget);
    expect(find.text('Panda rank'), findsOneWidget);
    // H1: sign-out moved off this top-level screen into the pushed Account
    // settings screen (H2) — this tab now shows the Settings hub row list
    // instead of a bare sign-out button. The hub's ListView is long enough
    // that later rows aren't built until scrolled into view (sliver lazy
    // building applies even to the ListView(children:) constructor), so
    // scrollUntilVisible is required here rather than a bare find.text.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Notifications'), 300, scrollable: scrollable);
    expect(find.text('Notifications'), findsOneWidget);
    await tester.scrollUntilVisible(find.text("What's New"), 300, scrollable: scrollable);
    expect(find.text("What's New"), findsOneWidget);
  });
}
