import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart' show CardCommand, CardCommandContext, cardCommandHandlers;
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

Future<CommandOutbox> _pump(
  WidgetTester tester, {
  required List<UserCard> archived,
  required UserCardsRepository? repo,
  bool online = true,
}) async {
  final db = openInMemoryForTesting();
  addTearDown(db.close);
  final commands = CommandOutbox(db, namespace: 'test');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandOutboxProvider.overrideWith((ref) async => commands),
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
  return commands;
}

void main() {
  test('a restore the server refuses (409 card_already_added) parks and the '
      'phone goes back to the server state', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final commands = CommandOutbox(db, namespace: 'test');
    commands.enqueue(
      kind: CardCommand.unarchiveCard,
      target: 'uc1',
      payload: {'cardId': 'uc1'},
    );
    final repo = _FakeArchivedRepository()
      ..failure = ApiException(
        'unarchive failed: 409 {"error":"card_already_added"}',
      );
    var undone = 0;
    final delivered = await commands.flush(
      cardCommandHandlers(
        CardCommandContext(
          userCards: repo,
          overrides: null,
          commands: commands,
          db: db.db,
          namespace: 'test',
          onChanged: () => undone++,
        ),
      ),
    );
    expect(delivered, 0);
    expect(commands.parkedCount, 1);
    expect(commands.pendingCount, 0);
    expect(undone, 1, reason: 'the local un-archive was undone');
  });

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
    final commands = await _pump(
      tester,
      archived: [_archivedCard()],
      repo: repo,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    // Local first: stored and queued, the screen never called the server.
    expect(repo.unarchived, isEmpty);
    expect(
      commands.pendingOf({CardCommand.unarchiveCard}).single.target,
      'uc1',
    );
    expect(find.text('Old card restored to your wallet.'), findsOneWidget);
    expect(find.text('No deleted cards'), findsOneWidget);
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

  testWidgets('signed out shows a sign-in state instead of local card rows', (
    tester,
  ) async {
    await _pump(
      tester,
      archived: [_archivedCard()],
      repo: null,
    );

    expect(find.text('Sign in to manage deleted cards'), findsOneWidget);
    expect(find.text('Old card'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
  });

  testWidgets('restoring while offline is saved on the phone and queued', (
    tester,
  ) async {
    final repo = _FakeArchivedRepository();
    final commands = await _pump(
      tester,
      archived: [_archivedCard()],
      repo: repo,
      online: false,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Old card restored to your wallet.'), findsOneWidget);
    expect(commands.pendingOf({CardCommand.unarchiveCard}), hasLength(1));
    expect(repo.unarchived, isEmpty);
  });
}
