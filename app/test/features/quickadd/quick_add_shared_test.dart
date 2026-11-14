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
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor_fields.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    me = '22222222-2222-4222-8222-222222222222',
    friend = '33333333-3333-4333-8333-333333333333',
    group = '44444444-4444-4444-8444-444444444444';

class Runtime extends SharedExpensesRuntime {
  bool failFlush = false;
  Runtime(
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
        'name': 'test',
        'membershipState': 'active',
      },
      {
        'contextId': friend,
        'kind': 'direct',
        'name': 'test',
        'membershipState': 'active',
      },
    ],
    'hasMore': false,
  };
  @override
  Future<void> flushEditor() async {
    if (failFlush) throw StateError('offline');
  }
}

void main() {
  late AppDatabase db;
  late Runtime runtime;
  late AuthenticatedHttpClient client;
  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    final store = SharedExpensesStore(db, namespace: 'user:$account');
    runtime = Runtime(
      store,
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
  Future<void> launch(
    WidgetTester tester, {
    double width = 430,
    double scale = 1,
    TransactionEntry? source,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (source != null)
            cacheNamespaceProvider.overrideWithValue('user:$account'),
          // The screen prints today's date ("Mon, Nov 9"). flutter_test draws text
          // in the Ahem font, one em per glyph, so at 2x text a two-digit day
          // ("Tue, Nov 10") fills the whole header row and the layout test failed
          // on every day from the 10th of the month. A fixed day makes it the same
          // test every day (the Clock comment says tests must not read the real
          // time).
          clockProvider.overrideWithValue(TestClock(DateTime(2026, 11, 9, 12))),
          sharedExpensesEnabledProvider.overrideWithValue(true),
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          transactionsProvider.overrideWith((ref) async => const []),
          foreignPaymentsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => QuickAddScreen(
                      autofocus: false,
                      sharedExpense: true,
                      sharedContextId: group,
                      sharedSourceEntry: source,
                      sharedSourceAccountId: source == null ? null : account,
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

  Future<void> fillFriendPaid(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-amount-field')),
      '900',
    );
    // "Paid by" is the only dropdown inside the sharing fields.
    final payer = find.descendant(
      of: find.byType(SharedEditorFields),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    await tester.ensureVisible(payer);
    await tester.tap(payer);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rahul').last);
    await tester.pumpAndSettle();
    final merchant = find.byKey(const ValueKey('quick-add-merchant-field'));
    await tester.ensureVisible(merchant);
    await tester.enterText(merchant, 'Dinner');
    await tester.pumpAndSettle();
  }

  testWidgets(
    'chooser separates friends from groups, even with the same name, and offers both creations',
    (tester) async {
      await launch(tester);
      await tester.tap(find.text('Flatmates'));
      await tester.pumpAndSettle();
      expect(find.text('FRIENDS'), findsOneWidget);
      expect(find.text('GROUPS'), findsOneWidget);
      expect(find.text('Friend · just the two of you'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
      expect(find.text('Add friend'), findsOneWidget);
      expect(find.text('Create group'), findsOneWidget);
    },
  );
  testWidgets(
    'unfinished sharing never autosaves or resumes when the form is reopened',
    (tester) async {
      await launch(tester);
      expect(find.text('Save draft'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('quick-add-amount-field')),
        '900.',
      );
      await tester.pump(const Duration(milliseconds: 400));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('quick-add-amount-field')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(runtime.store.pendingCount, 0);
    },
  );
  testWidgets(
    'existing purchase keeps exact paise and closes without a draft or duplicate transaction',
    (tester) async {
      final source = TransactionEntry(
        id: group,
        amount: const Money.fromPaise(90001),
        occurredAt: DateTime(2026, 11, 4),
        merchantName: 'Existing dinner',
        note: 'Original note',
        source: 'manual',
        status: 'active',
      );
      await launch(tester, source: source);
      final amount = tester.widget<TextField>(
        find.byKey(const ValueKey('quick-add-amount-field')),
      );
      expect(amount.controller!.text, '900.01');
      expect(amount.readOnly, isTrue);
      expect(find.text('Charged on your original payment'), findsOneWidget);
      final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit shared expense'),
      );
      // Stays tappable so the person is told what is missing; the linked
      // payment still cannot be submitted (see the hint above the button).
      expect(submit.onPressed, isNotNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
      expect(
        db.db
            .select('SELECT count(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
      expect(runtime.store.pendingCount, 0);
    },
  );
  testWidgets(
    'friend paid submits one exact proposal without a bank transaction or saved form',
    (tester) async {
      await launch(tester);
      await fillFriendPaid(tester);
      expect(find.text('Paid with'), findsNothing);
      // A friend paid: the answer is what you owe, said once, with no row for a
      // "share" that only repeats your line in the split.
      expect(find.text('You will owe'), findsOneWidget);
      expect(find.text('Your share'), findsNothing);
      await tester.tap(find.text('Submit shared expense'));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(runtime.store.pendingCount, 1);
      expect(
        db.db
            .select('SELECT count(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'retrying a submitted expense keeps its sealed operation and cannot create another',
    (tester) async {
      runtime.failFlush = true;
      await launch(tester);
      await fillFriendPaid(tester);
      await tester.tap(find.text('Submit shared expense'));
      await tester.pumpAndSettle();
      expect(runtime.store.pendingCount, 1);
      final id = runtime.store
          .readPendingOperations()
          .items
          .single
          .command
          .operationId;
      expect(find.text('Check submission'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('quick-add-amount-field')),
            )
            .readOnly,
        isTrue,
      );
      runtime.failFlush = false;
      await tester.tap(find.text('Check submission'));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(runtime.store.pendingCount, 1);
      expect(
        runtime.store.readPendingOperations().items.single.command.operationId,
        id,
      );
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
    },
  );
  testWidgets('sharing fits 320dp and 2x text without obscuring the amount', (
    tester,
  ) async {
    await launch(tester, width: 320, scale: 2);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-amount-field')),
      '100',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('Shared with \u00b7 2 people *', findRichText: true),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the summary answers first and says each figure once', (
    tester,
  ) async {
    await launch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-amount-field')),
      '1000',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('You get back'));

    // Paid by you, split equally with Rahul: one result, then who pays what.
    expect(find.text('You get back'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    expect(find.text('Your share counts as your spending.'), findsOneWidget);
    // The rows that repeated one figure under three names are gone, and so are
    // the bill's own figures, which only repeat the amount and "Paid by".
    for (final gone in [
      'Your share',
      'Your spending',
      'Bill total',
      'You paid',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // Banner, your part and Rahul's part: three figures, each labelled once.
    expect(find.text('\u20b9500.00'), findsNWidgets(3));
  });

  testWidgets('multiple payers and part-of-bill sit behind More options', (
    tester,
  ) async {
    await launch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-amount-field')),
      '1000',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More options'));
    expect(find.text('Multiple payers'), findsNothing);
    expect(find.text('Share only part of this bill'), findsNothing);

    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Multiple payers'), findsOneWidget);
    expect(find.text('Share only part of this bill'), findsOneWidget);

    // Turning one on is remembered by the row, so it is never hidden unseen.
    await tester.tap(find.text('Share only part of this bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Part of the bill'), findsOneWidget);
  });
}
