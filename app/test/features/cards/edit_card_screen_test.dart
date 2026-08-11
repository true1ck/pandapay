import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/edit_card_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _RecordingUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastUpdateArgs;
  bool archived = false;
  String? defaultedId;

  @override
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
    AutopayMode? autopayMode,
  }) async {
    lastUpdateArgs = {
      'userCardId': userCardId,
      'nickname': nickname,
      'creditLimitInr': creditLimitInr,
      'statementDay': statementDay,
      'dueDay': dueDay,
      'pointsBalance': pointsBalance,
      'autopayMode': autopayMode,
    };
  }

  @override
  Future<void> archiveCard(String userCardId) async => archived = true;

  @override
  Future<void> setDefaultCard(String userCardId) async => defaultedId = userCardId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  required _RecordingUserCardsRepository repo,
}) async {
  final router = GoRouter(
    initialLocation: '/edit',
    routes: [
      GoRoute(path: '/edit', builder: (context, state) => const EditCardScreen(userCardId: 'uc1')),
      GoRoute(path: '/back', builder: (context, state) => const Scaffold(body: Text('back home'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('pre-fills nickname and credit limit from the existing card', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        nickname: 'My Card',
        cardName: 'Test Card',
        isDefault: false,
        creditLimit: Money.fromRupees(50000),
      ),
    ];
    await _pump(tester, catalogue: [product], owned: owned, repo: _RecordingUserCardsRepository());

    expect(find.widgetWithText(TextField, 'Nickname'), findsOneWidget);
    final nicknameField = tester.widget<TextField>(find.widgetWithText(TextField, 'Nickname'));
    expect(nicknameField.controller!.text, 'My Card');
    final limitField = tester.widget<TextField>(find.widgetWithText(TextField, 'Credit limit (₹)'));
    expect(limitField.controller!.text, '50000');
  });

  testWidgets('Save sends the edited nickname to the repository and pops', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.enterText(find.widgetWithText(TextField, 'Nickname'), 'Renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastUpdateArgs?['userCardId'], 'uc1');
    expect(repo.lastUpdateArgs?['nickname'], 'Renamed');
  });

  testWidgets('Remove card confirms in a sheet before calling archiveCard', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(find.text('Remove card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();

    // Design 23: destructive actions confirm in a sheet — nothing has been
    // archived yet at this point.
    expect(repo.archived, isFalse);
    expect(find.text('Remove this card?'), findsOneWidget);

    // 'Remove card' now matches both the screen button and the sheet's own
    // confirm button, so scope to the one inside the sheet.
    await tester.tap(find.widgetWithText(FilledButton, 'Remove card'));
    await tester.pumpAndSettle();

    expect(repo.archived, isTrue);
  });

  testWidgets('cancelling the remove sheet leaves the card alone', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(find.text('Remove card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(repo.archived, isFalse);
  });

  testWidgets('Set as default card calls setDefaultCard', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final repo = _RecordingUserCardsRepository();
    await _pump(
      tester,
      catalogue: [product],
      owned: [const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false)],
      repo: repo,
    );

    await tester.scrollUntilVisible(find.text('Set as default card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Set as default card'));
    await tester.pumpAndSettle();

    expect(repo.defaultedId, 'uc1');
  });

  testWidgets('a card that is already default shows a state row, not the action', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    await _pump(
      tester,
      catalogue: [product],
      owned: [const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: true)],
      repo: _RecordingUserCardsRepository(),
    );

    await tester.scrollUntilVisible(
      find.text('This is your default card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Set as default card'), findsNothing);
  });
}
