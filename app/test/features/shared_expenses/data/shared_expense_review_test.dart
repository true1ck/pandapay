import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_expense_review.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const account = '11111111-1111-4111-8111-111111111111',
    group = '22222222-2222-4222-8222-222222222222',
    expense = '33333333-3333-4333-8333-333333333333',
    revision = '44444444-4444-4444-8444-444444444444';

class Runtime extends SharedExpensesRuntime {
  bool canRespond = true;
  Runtime(
    SharedExpensesStore store,
    SharedExpensesHttpTransport remote,
    ResponseCache cache,
  ) : super(store: store, remote: remote, cache: cache, isCurrent: () => true);
  @override
  Future<void> flushEditor() async {}
  @override
  Future<Map<String, Object?>> expenseReviewPage(
    String contextId,
    String expenseId, {
    String? after,
  }) async => {
    'memberNames': {'me': 'You', 'friend': 'Rahul'},
    'hasMore': false,
    'nextCursor': null,
    'items': [
      {
        'contextId': group,
        'expenseId': expense,
        'revisionId': revision,
        'title': 'Dinner',
        'occurredOn': '2026-11-04',
        'reviewState': canRespond ? 'awaiting_approval' : 'accepted',
        'canRespond': canRespond,
        'yourDecision': null,
        'yourPaidMinor': '120000',
        'yourShareMinor': '60000',
        'ownMemberId': 'me',
        'totalMinor': '120000',
        'bill': {
          'totalMinor': '140000',
          'contributions': [
            {'memberId': 'me', 'amountMinor': '140000'},
          ],
        },
        'snapshot': {
          'memberOrder': ['me', 'friend'],
          'contributions': [
            {'memberId': 'me', 'amountMinor': '120000'},
          ],
          'shares': [
            {'memberId': 'me', 'amountMinor': '60000'},
            {'memberId': 'friend', 'amountMinor': '60000'},
          ],
        },
      },
    ],
  };
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
  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SharedExpenseReviewSheet(
              runtime: runtime,
              contextId: group,
              expenseId: expense,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'review shows personal spending separately and submits one durable response',
    (tester) async {
      await launch(tester);
      expect(find.text('Bill total'), findsOneWidget);
      expect(find.text('Your personal spending'), findsOneWidget);
      final approve = find.text('Approve this revision');
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(runtime.store.pendingCount, 1);
      expect(find.text('Approve this revision'), findsNothing);
      expect(find.textContaining('waiting to sync'), findsOneWidget);
      await runtime.respondToExpense(group, expense, revision, 'approve');
      expect(runtime.store.pendingCount, 1);
      await expectLater(
        runtime.respondToExpense(group, expense, revision, 'reject'),
        throwsA(isA<SharedLocalException>()),
      );
      expect(
        db.db
            .select('SELECT count(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('removing an accepted expense asks once, then queues one void', (
    tester,
  ) async {
    runtime.canRespond = false;
    await launch(tester);
    final remove = find.text('Remove this expense');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('Remove this expense?'), findsOneWidget);
    expect(runtime.store.pendingCount, 0, reason: 'nothing before confirming');
    await tester.tap(find.byKey(const Key('confirm-remove-expense')));
    await tester.pumpAndSettle();
    expect(runtime.store.pendingCount, 1);
    final row = db.db
        .select('SELECT kind, request_json FROM shared_commands')
        .single;
    expect(row['kind'], 'expense.propose');
    final sent = jsonDecode(row['request_json'] as String) as Map;
    final payload = (sent['payload'] ?? sent) as Map;
    expect(payload['void'], true);
    expect(payload['snapshot'], isNull);
    expect(payload['expenseId'], expense);
    expect(payload['expectedHeadRevisionId'], revision);
    expect(payload.containsKey('bill'), isFalse);
  });
  testWidgets(
    'accepted revisions never offer another approval; revoked data disappears',
    (tester) async {
      runtime.canRespond = false;
      await launch(tester);
      expect(find.text('Accepted expense'), findsOneWidget);
      expect(find.text('Approve this revision'), findsNothing);
      // An accepted expense can be taken back out, not approved again.
      expect(find.text('Remove this expense'), findsOneWidget);
      await runtime.revokeContext(group);
      await tester.pumpAndSettle();
      expect(find.text('Dinner'), findsNothing);
      expect(find.textContaining('no longer available'), findsOneWidget);
    },
  );
}
