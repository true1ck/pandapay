import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/split_expense_screen.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    me = '22222222-2222-4222-8222-222222222222',
    friend = '33333333-3333-4333-8333-333333333333',
    group = '44444444-4444-4444-8444-444444444444',
    txn = '55555555-5555-4555-8555-555555555555';

class _Runtime extends SharedExpensesRuntime {
  _Runtime(
    SharedExpensesStore store,
    SharedExpensesHttpTransport remote,
    ResponseCache cache,
  ) : super(store: store, remote: remote, cache: cache, isCurrent: () => true);
  @override
  Future<({String name, String ownMemberId, List<SharedEditorMember> members})>
  editorContext(String id) async => (
    name: 'Flatmates',
    ownMemberId: me,
    members: const [
      SharedEditorMember(me, 'You'),
      SharedEditorMember(friend, 'Rahul'),
    ],
  );
  @override
  Future<Map<String, Object?>> contexts({String? after}) async => {
    'items': [
      {
        'contextId': group,
        'kind': 'group',
        'name': 'Flatmates',
        'membershipState': 'active',
      },
      {
        'contextId': friend,
        'kind': 'direct',
        'name': 'Rahul',
        'membershipState': 'active',
      },
    ],
    'hasMore': false,
  };
}

void main() {
  late AppDatabase db;
  late _Runtime runtime;
  late AuthenticatedHttpClient client;
  List<TransactionSplit>? saved;

  setUp(() {
    saved = null;
    BambooFonts.useSystemFontsForTests = true;
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    runtime = _Runtime(
      SharedExpensesStore(db, namespace: 'user:$account'),
      SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: 'user:$account',
        client: client,
        accessToken: () => null,
        isCurrent: () => true,
      ),
      ResponseCache(db),
    )..capabilities = {'reads': true, 'proposals': true};
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
    BambooFonts.useSystemFontsForTests = false;
  });

  final entry = TransactionEntry(
    id: txn,
    amount: Money.fromRupees(900),
    occurredAt: DateTime(2026, 11, 4),
    merchantName: 'Dinner',
    source: 'manual',
    status: 'active',
  );

  Future<void> open(
    WidgetTester tester, {
    SplitScreenMode mode = SplitScreenMode.friends,
    List<TransactionSplit> initial = const [],
  }) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheNamespaceProvider.overrideWithValue('user:$account'),
          sharedExpensesEnabledProvider.overrideWithValue(true),
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SplitExpenseScreen(
                      entry: entry,
                      initialMode: mode,
                      initialPrivate: initial,
                      onSavePrivate: (s) async => saved = s,
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  FilledButton submit(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('split-submit')));

  testWidgets('just for me: saves labelled shares and closes', (tester) async {
    await open(tester, mode: SplitScreenMode.justMe);
    expect(find.text('Split expense'), findsOneWidget);
    expect(submit(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('private-amount-0')), '400');
    await tester.enterText(find.byKey(const ValueKey('private-label-0')), 'Priya');
    await tester.pump();
    expect(find.textContaining('Unallocated'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('split-submit')));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved!.single.amount, Money.fromRupees(400));
    expect(saved!.single.note, 'Priya');
    expect(find.text('Open'), findsOneWidget, reason: 'screen closed');
  });

  testWidgets('just for me: refuses shares above the payment', (tester) async {
    await open(tester, mode: SplitScreenMode.justMe);
    await tester.enterText(find.byKey(const ValueKey('private-amount-0')), '901');
    await tester.pump();
    expect(submit(tester).onPressed, isNull);
    expect(find.textContaining('more than the payment'), findsOneWidget);
  });

  testWidgets('just for me: clear removes an existing split', (tester) async {
    await open(
      tester,
      mode: SplitScreenMode.justMe,
      initial: [TransactionSplit(amount: Money.fromRupees(400), note: 'Priya')],
    );
    await tester.tap(find.byKey(const ValueKey('private-clear')));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
  });

  testWidgets('with friends: pick a group, see an equal split and balance', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(ValueKey('split-context-$group')), findsOneWidget);
    expect(find.byKey(ValueKey('split-context-$friend')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('split-context-$group')));
    await tester.pumpAndSettle();
    expect(find.text('Rahul'), findsWidgets);
    expect(find.text('₹450.00'), findsWidgets);
    expect(find.text('You get back'), findsOneWidget);
    expect(find.text('Split with Flatmates'), findsOneWidget);
  });

  testWidgets('with friends: exact amounts add up and show the balance', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(ValueKey('split-context-$group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('split-mode-exact')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(ValueKey('split-input-exact-$me')), '300');
    await tester.enterText(
      find.byKey(ValueKey('split-input-exact-$friend')),
      '600',
    );
    await tester.pumpAndSettle();
    expect(find.text('You get back'), findsOneWidget);
    expect(find.text('₹600.00'), findsWidgets);
  });

  testWidgets(
    'with friends: sending a split of an existing payment says why it is held',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(ValueKey('split-context-$group')));
      await tester.pumpAndSettle();
      expect(submit(tester).onPressed, isNull);
      expect(find.textContaining('not switched on yet'), findsOneWidget);
    },
  );
}
