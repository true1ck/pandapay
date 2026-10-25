import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/deleted_cards_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeArchivedRepository implements UserCardsRepository {
  final List<String> unarchived = [];
  Object? failure;

  @override
  Future<void> unarchiveCard(String userCardId) async {
    if (failure != null) throw failure!;
    unarchived.add(userCardId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarmIsOnline extends ConsumerWidget {
  final Widget child;
  const _WarmIsOnline({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(isOnlineProvider);
    return child;
  }
}

CardProduct _product() => const CardProduct(
  id: 'p1',
  name: 'Test Card',
  issuerName: 'Test Bank',
  network: CardNetwork.rupay,
);

UserCard _archivedCard({String id = 'uc1', String? nickname = 'Old card'}) =>
    UserCard(
      id: id,
      cardProductId: 'p1',
      nickname: nickname,
      cardName: 'Test Card',
      isDefault: false,
      isArchived: true,
      last4: '4242',
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<UserCard> archived,
  required UserCardsRepository repo,
  bool online = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        archivedCardsProvider.overrideWith((ref) async => archived),
        catalogueProvider.overrideWith((ref) async => [_product()]),
        userCardsRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWith((ref) => Stream.value(online)),
        responseCacheProvider.overrideWith(
          (ref) => Future.error(StateError('no cache in tests')),
        ),
      ],
      child: const MaterialApp(
        home: _WarmIsOnline(child: DeletedCardsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists archived cards with a restore action', (tester) async {
    await _pump(
      tester,
      archived: [_archivedCard()],
      repo: _FakeArchivedRepository(),
    );

    expect(find.text('Deleted cards'), findsOneWidget);
    expect(find.text('Old card'), findsOneWidget);
    expect(find.text('Test Bank · •••• 4242'), findsOneWidget);
    expect(find.text('REMOVED'), findsOneWidget);
    expect(find.text('1 deleted card'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore'), findsOneWidget);
  });

  testWidgets('restoring a card unarchives it and removes it from the list', (
    tester,
  ) async {
    final repo = _FakeArchivedRepository();
    await _pump(
      tester,
      archived: [_archivedCard()],
      repo: repo,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(repo.unarchived, ['uc1']);
    expect(find.text('Old card restored to your wallet.'), findsOneWidget);
    expect(find.text('No deleted cards'), findsOneWidget);
  });

  testWidgets('a duplicate active card explains the conflict and keeps the card', (
    tester,
  ) async {
    final repo = _FakeArchivedRepository()
      ..failure = ApiException(
        'unarchive failed: 409 {"error":"card_already_added"}',
      );
    await _pump(
      tester,
      archived: [_archivedCard()],
      repo: repo,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'You already have an active card with the same issuer, type and '
        'last four. Remove that card first.',
      ),
      findsOneWidget,
    );
    expect(repo.unarchived, isEmpty);
    expect(find.text('Old card'), findsOneWidget);
  });

  testWidgets('an empty archived list shows the deleted-cards empty state', (
    tester,
  ) async {
    await _pump(
      tester,
      archived: const [],
      repo: _FakeArchivedRepository(),
    );

    expect(find.text('No deleted cards'), findsOneWidget);
    expect(
      find.text(
        'Cards you remove from your wallet show up here, ready to restore.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('restoring while signed in and offline asks for a connection', (
    tester,
  ) async {
    final repo = _FakeArchivedRepository();
    await _pump(
      tester,
      archived: [_archivedCard()],
      repo: repo,
      online: false,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Restoring a card needs a connection. Try again when you are online.',
      ),
      findsOneWidget,
    );
    expect(repo.unarchived, isEmpty);
  });
}
