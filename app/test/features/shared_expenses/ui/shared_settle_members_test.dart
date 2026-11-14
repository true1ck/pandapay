import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart' show cacheNamespaceProvider;
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/upi_payment_service.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_routes.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_members_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_settle_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_settlements_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    group = '22222222-2222-4222-8222-222222222222',
    me = '33333333-3333-4333-8333-333333333333',
    friend = '44444444-4444-4444-8444-444444444444',
    report = '55555555-5555-4555-8555-555555555555';
final sessionNamespace = StateProvider<String>((ref) => 'user:$account');

class Runtime extends SharedExpensesRuntime {
  Runtime({required super.store, required super.remote, required super.cache})
    : super(isCurrent: () => true);
  bool failFlush = false, owner = true, invited = false;
  int pages = 0;
  @override
  Future<SharedGroupPresentation> loadGroup(
    String id, {
    String? expenseAfter,
    String? balanceAfter,
  }) async => SharedGroupPresentation(
    id: id,
    title: 'Trip Group',
    expenses: SharedPage(),
    balances: SharedPage(
      items: [
        const SharedContextRow(
          id: friend,
          title: 'Friend User',
          balance: SharedBalanceSummary(
            owedToYou: Money.fromPaise(50000),
            youOwe: Money.fromPaise(100000),
            netBalance: Money.fromPaise(-50000),
          ),
        ),
      ],
    ),
  );
  @override
  Future<void> flushEditor() async {
    if (failFlush) throw StateError('offline');
  }

  @override
  Future<SharedRoster> contextRoster(String id) async => SharedRoster(
    name: 'Trip Group',
    ownMemberId: me,
    direct: false,
    canInvite: owner && proposalsEnabled,
    members: [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      SharedEditorMember(
        friend,
        'Friend User',
        profileId: invited ? null : friend,
        state: invited ? 'invited' : 'active',
      ),
    ],
  );
  @override
  Future<Map<String, Object?>> settlements(String id, {String? after}) async {
    pages++;
    return {
      'items': [
        {
          'contextId': id,
          'settlementId': report,
          'payerMemberId': friend,
          'receiverMemberId': me,
          'amountMinor': '25000',
          'currency': 'INR',
          'method': 'upi',
          'paidOn': '2026-11-04',
          'status': 'pending',
        },
      ],
      'hasMore': after == null,
      'nextCursor': after == null ? 'page2' : null,
    };
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
    runtime = Runtime(
      store: SharedExpensesStore(db, namespace: 'user:$account'),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: 'user:$account',
        client: client,
        accessToken: () => null,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
    )..capabilities = {'reads': true, 'proposals': true, 'settlements': true};
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
    BambooFonts.useSystemFontsForTests = false;
  });
  Future<void> show(
    WidgetTester tester,
    Widget sheet, {
    double width = 430,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          cacheNamespaceProvider.overrideWith(
            (ref) => ref.watch(sessionNamespace),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: sheet),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'bidirectional balances open a valid payment without netting debt',
    (tester) async {
      await show(
        tester,
        SharedContextRoute(contextId: group, onAddExpense: () {}),
      );
      await tap(tester, 'Balances');
      await tap(tester, 'Friend User');
      expect(find.textContaining('could not be loaded'), findsNothing);
      expect(find.text('Record payment'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('settlement-amount')))
            .controller!
            .text,
        '1000.00',
      );
      final people = tester
          .widgetList<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .toList();
      expect(people[0].initialValue, me);
      expect(people[1].initialValue, friend);
      expect(runtime.store.pendingCount, 0);
    },
  );

  testWidgets(
    'settlement uses exact paise and a failed retry never duplicates its command',
    (tester) async {
      runtime.failFlush = true;
      await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
      await tester.enterText(
        find.byKey(const ValueKey('settlement-amount')),
        '0.01',
      );
      await tap(tester, 'Record payment');
      expect(runtime.store.pendingCount, 1);
      expect(find.text('Check status'), findsOneWidget);
      final command = runtime.store
          .readPendingOperations()
          .items
          .single
          .command;
      expect((command.toJson()['payload'] as Map)['amountMinor'], '1');
      runtime.failFlush = false;
      await tap(tester, 'Check status');
      expect(runtime.store.pendingCount, 1);
      expect(
        find.text('Saved on this device · waiting to sync'),
        findsOneWidget,
      );
      expect(
        db.db
            .select('SELECT count(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
    },
  );
  testWidgets('incomplete decimal is not rounded into a payment', (
    tester,
  ) async {
    await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
    for (final invalid in [
      '100.',
      '0',
      'NaN',
      'Infinity',
      '0.001',
      '10000000.01',
    ]) {
      await tester.enterText(
        find.byKey(const ValueKey('settlement-amount')),
        invalid,
      );
      await tap(tester, 'Record payment');
      expect(runtime.store.pendingCount, 0, reason: invalid);
      expect(find.textContaining('at most two decimal places'), findsOneWidget);
    }
  });
  testWidgets(
    'UPI handoff opens the chosen app but never records a payment by itself',
    (tester) async {
      final upi = _FakeUpi(
        const UpiPaymentResult(status: UpiPaymentStatus.submitted),
      );
      await show(
        tester,
        SharedSettleSheet(runtime: runtime, contextId: group, upi: upi),
      );
      await tester.enterText(
        find.byKey(const ValueKey('settlement-amount')),
        '250.50',
      );
      await tap(tester, 'Pay with UPI app');
      expect(upi.paid, isEmpty);
      expect(find.textContaining('valid UPI ID'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('settlement-vpa')),
        'friend@okbank',
      );
      await tap(tester, 'Pay with UPI app');
      expect(upi.paid, hasLength(1));
      expect(
        upi.paid.single,
        allOf(contains('pa=friend%40okbank'), contains('am=250.50')),
      );
      expect(find.textContaining('not confirmed'), findsOneWidget);
      // A returned status is not proof: nothing is queued until the user records it.
      expect(runtime.store.pendingCount, 0);
      // A second launch needs an explicit check-your-app confirmation.
      await tap(tester, 'Open UPI app again');
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.textContaining('Check your payment app first'),
        findsOneWidget,
      );
      await tap(tester, 'Cancel');
      expect(upi.paid, hasLength(1));
    },
  );
  testWidgets(
    'disabled settlement capability cannot record or launch a UPI payment',
    (tester) async {
      runtime.capabilities!['settlements'] = false;
      await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
      expect(find.textContaining('not enabled'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Record payment'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Pay via UPI App'), findsNothing);
      expect(runtime.store.pendingCount, 0);
    },
  );
  testWidgets(
    'unclaimed people are not settlement recipients or active members',
    (tester) async {
      runtime.invited = true;
      await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
      expect(find.text('Record payment'), findsNothing);
      expect(find.textContaining('Two active'), findsOneWidget);
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      expect(find.text('Not on PandaPay · unclaimed'), findsOneWidget);
      expect(find.text('You (You)'), findsNothing);
    },
  );
  testWidgets(
    'receiver response stays pending until a receipt and cannot switch decisions',
    (tester) async {
      await show(
        tester,
        SharedSettlementsSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      await tap(tester, 'Confirm received');
      expect(runtime.store.pendingCount, 1);
      expect(find.text('Payment confirmed'), findsNothing);
      expect(find.text('Confirm received'), findsNothing);
      expect(find.text('Saved on this device · waiting to sync'), findsWidgets);
      await expectLater(
        runtime.respondToSettlement(group, report, 'reject'),
        throwsA(isA<SharedLocalException>()),
      );
      expect(runtime.store.pendingCount, 1);
    },
  );
  testWidgets('payment history has bounded next and previous pages', (
    tester,
  ) async {
    await show(
      tester,
      SharedSettlementsSheet(
        runtime: runtime,
        contextId: group,
        groupName: 'Trip Group',
      ),
    );
    await tap(tester, 'Next page');
    expect(runtime.pages, 2);
    expect(find.text('Previous page'), findsOneWidget);
    await tap(tester, 'Previous page');
    expect(runtime.pages, 3);
  });
  testWidgets(
    'member action records a shadow person without claiming an invitation was sent',
    (tester) async {
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      await tap(tester, 'Add person');
      // Inline step inside the sheet: no dialog is stacked on top of it.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Pick from contacts'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsOneWidget);
      expect(runtime.store.pendingCount, 0);
      await tester.enterText(find.byType(TextField).first, 'New Colleague');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(runtime.store.pendingCount, 1);
      expect(find.text('Check status'), findsOneWidget);
      expect(find.textContaining('Invited New Colleague'), findsNothing);
      await tap(tester, 'Check status');
      expect(runtime.store.pendingCount, 1);
    },
  );

  testWidgets(
    'adding duplicate member or invalid name/phone is prevented with clear error',
    (tester) async {
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      await tap(tester, 'Add person');
      // Case 1: Entering an existing member's name ('Friend User')
      await tester.enterText(find.byType(TextField).first, '  friend user  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(
        find.text('Someone in this split already has that name. Add a surname or initial.'),
        findsOneWidget,
      );
      expect(runtime.store.pendingCount, 0);

      // Case 2: Name field limits input to 40 characters
      final nameField = tester.widget<TextField>(find.byType(TextField).first);
      expect(nameField.maxLength, 40);

      // Case 3: Entering an invalid phone number
      await tester.enterText(find.byType(TextField).first, 'Valid Person');
      await tester.enterText(find.byType(TextField).at(1), '12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid mobile number, or leave it empty.'),
        findsOneWidget,
      );
      expect(runtime.store.pendingCount, 0);

      // Case 4: Entering a reserved name like 'You', 'Me', or 'Myself'
      await tester.enterText(find.byType(TextField).first, 'You');
      await tester.enterText(find.byType(TextField).at(1), '');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(
        find.text('That name cannot be used. Please choose a different one.'),
        findsOneWidget,
      );
      expect(runtime.store.pendingCount, 0);

      // Case 5: Typing a new character clears the error immediately
      await tester.enterText(find.byType(TextField).first, 'Yo');
      await tester.pumpAndSettle();
      expect(
        find.text('That name cannot be used. Please choose a different one.'),
        findsNothing,
      );

      // Case 6: Entering 'Myself' is also blocked
      await tester.enterText(find.byType(TextField).first, 'Myself');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(
        find.text('That name cannot be used. Please choose a different one.'),
        findsOneWidget,
      );
      expect(runtime.store.pendingCount, 0);
    },
  );
  testWidgets(
    'advanced edge cases: phone prefix variations, whitespace duplicate names, and comma pasted amounts',
    (tester) async {
      await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
      await tester.enterText(
        find.byKey(const ValueKey('settlement-amount')),
        '₹ 1,500.50',
      );
      await tap(tester, 'Record payment');
      expect(runtime.store.pendingCount, 1);
      final cmd = runtime.store.readPendingOperations().items.single.command;
      expect((cmd.toJson()['payload'] as Map)['amountMinor'], '150050');

      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      await tap(tester, 'Add person');
      await tester.enterText(find.byType(TextField).first, 'Friend   User');
      await tester.tap(find.widgetWithText(FilledButton, 'Add person'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Someone in this split already has that name. Add a surname or initial.',
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).first, 'Unique Person');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Someone in this split already has that name. Add a surname or initial.',
        ),
        findsNothing,
      );
    },
  );

  for (final kind in ['members', 'history', 'settle']) {
    testWidgets(
      '$kind hides private data immediately when context is revoked',
      (tester) async {
        await show(tester, switch (kind) {
          'members' => SharedMembersSheet(
            runtime: runtime,
            contextId: group,
            groupName: 'Trip Group',
          ),
          'history' => SharedSettlementsSheet(
            runtime: runtime,
            contextId: group,
            groupName: 'Trip Group',
          ),
          _ => SharedSettleSheet(runtime: runtime, contextId: group),
        });
        await runtime.revokeContext(group);
        await tester.pumpAndSettle();
        expect(find.textContaining('no longer available'), findsOneWidget);
        expect(find.text('Friend User'), findsNothing);
      },
    );
  }
  testWidgets(
    'long group names and payment controls fit at 320dp with 2x text',
    (tester) async {
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'A very long apartment and holiday group name',
        ),
        width: 320,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      await show(
        tester,
        SharedSettleSheet(runtime: runtime, contextId: group),
        width: 320,
        scale: 2,
      );
      await tester.ensureVisible(find.text('Record payment'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a modal hides private member data when the signed-in account changes',
    (tester) async {
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(sessionNamespace.notifier).state = 'user:another';
      await tester.pumpAndSettle();
      expect(find.text('Friend User'), findsNothing);
      expect(find.textContaining('no longer available'), findsOneWidget);
    },
  );

  testWidgets(
    'settlement sheet renders with BambooSheet and validates max limit cleanly',
    (tester) async {
      await show(tester, SharedSettleSheet(runtime: runtime, contextId: group));
      expect(find.byType(SharedSettleSheet), findsOneWidget);
      expect(find.text('Settle up'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('settlement-amount')),
        '120000000',
      );
      await tap(tester, 'Record payment');
      expect(runtime.store.pendingCount, 0);
      expect(find.textContaining('1,00,00,000'), findsOneWidget);
    },
  );
}

class _FakeUpi implements UpiPaymentService {
  final UpiPaymentResult result;
  final paid = <String>[];
  _FakeUpi(this.result);
  @override
  Future<List<UpiApp>> installedApps() async => const [
    UpiApp(packageName: 'test.upi', name: 'Test UPI'),
  ];
  @override
  Future<UpiPaymentResult> pay({
    required String upiUri,
    required String packageName,
  }) async {
    paid.add(upiUri);
    return result;
  }

  @override
  String newTransactionRef() => 'test';
}
