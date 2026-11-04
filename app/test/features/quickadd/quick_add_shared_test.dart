import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
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
    String? draft,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
                      sharedDraftId: draft,
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

  testWidgets(
    'friend-paid entry uses the existing amount/merchant form and saves one shared command',
    (tester) async {
      await launch(tester);
      expect(
        find.byKey(const ValueKey('quick-add-amount-field')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('quick-add-amount-field')),
        '900',
      );
      await tester.ensureVisible(
        find.widgetWithText(DropdownButtonFormField<String>, 'Paid by'),
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Paid by'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rahul').last);
      await tester.pumpAndSettle();
      expect(find.text('Paid with'), findsNothing);
      final merchant = find.byKey(const ValueKey('quick-add-merchant-field'));
      await tester.ensureVisible(merchant);
      await tester.enterText(merchant, 'Dinner');
      await tester.pumpAndSettle();
      expect(find.text('Your share'), findsOneWidget);
      expect(find.text('Submit shared expense'), findsOneWidget);
      await tester.tap(find.text('Submit shared expense'));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(runtime.store.pendingCount, 1);
      expect(
        db.db
            .select('SELECT COUNT(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
      expect(runtime.store.editorDrafts(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Back keeps incomplete amount input in a resumable draft', (
    tester,
  ) async {
    await launch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-amount-field')),
      '900.',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    final saved = runtime.store.editorDrafts().single;
    expect(saved.value['billText'], '900.');
    expect(runtime.store.pendingCount, 0);
  });
  testWidgets(
    'sharing controls fit 320dp and 2x text without hiding the amount',
    (tester) async {
      await launch(tester, width: 320, scale: 2);
      await tester.enterText(
        find.byKey(const ValueKey('quick-add-amount-field')),
        '100',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Shared with · 2/50'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a failed submit resumes the same sealed operation instead of claiming a new draft',
    (tester) async {
      final editor = SharedEditor(store: runtime.store, accountId: account);
      editor.selectContext(group, 'Flatmates', const [
        SharedEditorMember(me, 'You'),
        SharedEditorMember(friend, 'Rahul'),
      ], me);
      editor.choosePayer(friend);
      editor.setBill('900');
      editor.setTitle('Dinner');
      await editor.persist();
      final id = editor.id;
      editor.dispose();
      runtime.failFlush = true;
      await launch(tester, draft: id);
      await tester.tap(find.text('Submit shared expense'));
      await tester.pumpAndSettle();
      expect(runtime.store.pendingCount, 1);
      expect(find.text('Check submission'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('quick-add-amount-field')),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('quick-add-merchant-field')),
            )
            .readOnly,
        isTrue,
      );
      runtime.failFlush = false;
      await tester.tap(find.text('Check submission'));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(runtime.store.pendingCount, 1);
      expect(runtime.store.editorDrafts(), isEmpty);
    },
  );
  testWidgets(
    'draft recovery retains the note and private receipt reference after Back',
    (tester) async {
      final editor = SharedEditor(store: runtime.store, accountId: account);
      editor.selectContext(group, 'Flatmates', const [
        SharedEditorMember(me, 'You'),
        SharedEditorMember(friend, 'Rahul'),
      ], me);
      editor.choosePayer(friend);
      editor.setBill('900');
      editor.setTitle('Dinner');
      await editor.persist();
      final receipt = await runtime.store.saveEditorReceipt(
        editor.id,
        name: 'Bill.jpg',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      editor.setPrivateFields({
        'note': 'Dinner receipt',
        'receiptHash': receipt.hash,
        'receiptName': 'Bill.jpg',
        'tagIds': <String>[],
      });
      await editor.persist();
      final id = editor.id;
      editor.dispose();
      await launch(tester, draft: id);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final saved = runtime.store.editorDraft(id)!;
      expect(saved.value['title'], 'Dinner');
      expect(saved.value['billText'], '900');
      expect((saved.value['privateFields'] as Map)['note'], 'Dinner receipt');
      expect(
        (saved.value['privateFields'] as Map)['receiptHash'],
        receipt.hash,
      );
      expect(runtime.store.editorReceipt(id, receipt.hash)!.bytes, [
        1,
        2,
        3,
        4,
      ]);
    },
  );
}
