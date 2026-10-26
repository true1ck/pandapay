import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/auto_resolved_history_repository.dart';
import 'package:pandapay/data/local/sms_auto_resolution_controller.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/needs_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

AutoResolvedHistoryEntry _historyEntry({
  required String id,
  required String title,
  String resolvedKind = 'transaction',
  String? categorySlug = 'dining',
  int amountPaise = 49900,
  String? dueDate,
  int autoResolvedAt = 1000,
}) => AutoResolvedHistoryEntry(
  id: id,
  namespace: 'user:test',
  sourceKey: 'source-$id',
  sender: 'VM-HDFCBK',
  resolvedKind: resolvedKind,
  title: title,
  amountPaise: amountPaise,
  categorySlug: categorySlug,
  dueDate: dueDate,
  occurredAt: '2026-10-20T10:00:00.000Z',
  instrument: 'credit_card',
  accountLast4: '1234',
  confidence: 0.95,
  autoResolvedAt: autoResolvedAt,
);

class _FakeSmsAutoResolutionController implements SmsAutoResolutionController {
  AutoResolvedHistoryEntry? changedEntry;
  String? changedCategory;
  AutoResolvedHistoryEntry? movedEntry;
  Future<void> Function(AutoResolvedHistoryEntry entry, String categorySlug)?
  onChangeCategory;
  Future<void> Function(AutoResolvedHistoryEntry entry)? onMoveToReview;

  @override
  Future<void> changeCategory(
    AutoResolvedHistoryEntry entry,
    String categorySlug,
  ) async {
    changedEntry = entry;
    changedCategory = categorySlug;
    await onChangeCategory?.call(entry, categorySlug);
  }

  @override
  Future<void> moveToReview(AutoResolvedHistoryEntry entry) async {
    movedEntry = entry;
    await onMoveToReview?.call(entry);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastLogArgs;
  Map<String, dynamic>? lastOverrideArgs;
  final List<Map<String, dynamic>> allOverrideArgs = [];
  Map<String, dynamic>? lastAiJobArgs;
  bool aiJobSubmitted = false;

  @override
  Future<String> logTransaction({
    String? userCardId,
    required dynamic amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async {
    lastLogArgs = {
      'userCardId': userCardId,
      'amount': amount,
      'categoryId': categoryId,
      'entryKind': entryKind,
    };
    return 'fake-txn-id';
  }

  @override
  Future<bool> overrideSmsFact({
    required String sourceKey,
    required int factIndex,
    required Map<String, dynamic> patch,
    String? reason,
    String? templateText,
    String? sampleBody,
  }) async {
    lastOverrideArgs = {
      'sourceKey': sourceKey,
      'factIndex': factIndex,
      'patch': patch,
      'reason': reason,
      'templateText': templateText,
      'sampleBody': sampleBody,
    };
    allOverrideArgs.add(lastOverrideArgs!);
    return true;
  }

  @override
  Future<String?> submitAiJob({
    required String sourceKey,
    required String sender,
    required String body,
    DateTime? occurredAt,
    bool retryFailed = false,
  }) async {
    aiJobSubmitted = true;
    lastAiJobArgs = {
      'sourceKey': sourceKey,
      'sender': sender,
      'body': body,
      'occurredAt': occurredAt,
      'retryFailed': retryFailed,
    };
    return 'retry-job-id';
  }

  @override
  Future<Map<String, dynamic>?> fetchAiJobStatus(String sourceKey) async => {
    'status': aiJobSubmitted ? 'queued' : 'failed',
    'suggestions': const [],
  };

  Map<String, dynamic>? lastDismissArgs;
  final List<Map<String, dynamic>> allDismissArgs = [];

  @override
  Future<bool> dismissSms({
    required String sourceKey,
    String? sender,
    String? reason,
    String? templateText,
    String? sampleBody,
    String? family,
  }) async {
    lastDismissArgs = {
      'sourceKey': sourceKey,
      'sender': sender,
      'reason': reason,
      'templateText': templateText,
      'sampleBody': sampleBody,
      'family': family,
    };
    allDismissArgs.add(lastDismissArgs!);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  required NeedsReviewRepository reviews,
  CommitmentsRepository? commitments,
  List<AutoResolvedHistoryEntry> autoResolved = const [],
  SmsAutoResolutionController? autoResolutionController,
  Size surfaceSize = const Size(1000, 1000),
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        needsReviewRepositoryProvider.overrideWithValue(reviews),
        autoResolvedHistoryProvider.overrideWith((ref) async => autoResolved),
        autoResolvedCountProvider.overrideWith(
          (ref) async => autoResolved.length,
        ),
        smsAutoResolutionControllerProvider.overrideWithValue(
          autoResolutionController ?? _FakeSmsAutoResolutionController(),
        ),
        if (commitments != null)
          commitmentsRepositoryProvider.overrideWithValue(commitments),
        smsBackgroundFlushProvider.overrideWith((ref) {}),
      ],
      child: const MaterialApp(home: NeedsReviewScreen()),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late AppDatabase db;
  late NeedsReviewRepository reviews;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    reviews = NeedsReviewRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
  });
  tearDown(() => db.close());

  testWidgets('shows an empty state when nothing needs review', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets('shows the raw sender and body for a queued item', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'unparseable_amount',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('VM-HDFCBK'), findsOneWidget);
    expect(find.text('Rs.499 spent at AMAZON'), findsOneWidget);
    expect(find.text('AI review not started'), findsOneWidget);
  });

  testWidgets('shows completed AI check status beside its suggestions', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'f' * 64,
        sender: 'VM-HDFCBK',
        body: 'INR 499 spent at AMAZON on card ending 1234.',
        receivedAt: DateTime.now(),
        aiStatus: AiReviewStatus.checked,
        aiSuggestions: const [
          {
            'factIndex': 0,
            'factType': 'posted_movement',
            'payload': {'amountInr': 499, 'merchant': 'AMAZON'},
          },
        ],
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('AI review completed'), findsOneWidget);
    expect(find.textContaining('AI suggested'), findsOneWidget);
    expect(find.text('Review transaction'), findsOneWidget);
  });

  testWidgets('surfaces Gemini decision category on review tile', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'f' * 64,
        sender: 'VM-HDFCBK',
        body: 'Rs. 420 spent at Swiggy',
        reason: 'unparseable_amount',
        receivedAt: DateTime.now(),
        aiStatus: AiReviewStatus.checked,
        aiTopic: 'upi_debit',
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('✦ AI decision · upi debit'), findsOneWidget);
  });

  testWidgets(
    'shows queued AI check status with spinner and allows tap to retry',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: '1',
          sender: 'VM-HDFCBK',
          body: 'Rs.499 spent at AMAZON',
          receivedAt: DateTime.now(),
          aiStatus: AiReviewStatus.queued,
        ),
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(),
        reviews: reviews,
        settle: false,
      );

      expect(find.text('AI review queued · Checking...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('AI review queued · Checking...'));
      await tester.pump();
    },
  );

  testWidgets('failed Gemini decision can be explicitly retried', (
    tester,
  ) async {
    final itemId = List.filled(64, 'f').join();
    await reviews.add(
      NeedsReviewItem(
        id: itemId,
        sender: 'VM-HDFCBK',
        body: 'INR 499 spent at AMAZON',
        receivedAt: DateTime.now(),
        aiStatus: AiReviewStatus.unavailable,
        aiFailureReason: 'worker_retry_limit',
      ),
    );
    final repo = _FakeUserCardsRepository();
    await _pump(tester, repo: repo, reviews: reviews, settle: false);

    expect(find.text('AI review failed · Tap to retry'), findsOneWidget);
    await tester.tap(find.text('AI review failed · Tap to retry'));
    // Queued state intentionally keeps its spinner animated, so settle would
    // time out even though the retry request completed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('View AI output'));
    await tester.pump();
    expect(find.textContaining('"status": "queued"'), findsOneWidget);
    expect(find.textContaining('"sourceKey"'), findsNothing);

    expect(repo.lastAiJobArgs?['sourceKey'], itemId);
    expect(repo.lastAiJobArgs?['retryFailed'], isTrue);
    expect((await reviews.fetchAll()).single.aiStatus, AiReviewStatus.queued);
  });

  testWidgets('shows in-progress AI check status with spinner', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        receivedAt: DateTime.now(),
        aiStatus: AiReviewStatus.processing,
      ),
    );
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      settle: false,
    );

    expect(find.text('AI review in progress'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('Ignore message removes the item from the queue', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent on HDFC Bank Card ending 1234 at AMAZON.',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Ignore message'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('Review transaction opens a clear bottom-sheet review form', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'txn-review-1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'no_transaction_match',
        receivedAt: DateTime(2026, 10, 1),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Review transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Review this transaction'), findsOneWidget);
    expect(
      find.textContaining('possible transaction in this message'),
      findsOneWidget,
    );
    expect(find.text('Save transaction'), findsOneWidget);
    expect(find.text('Amount (₹)'), findsOneWidget);
    expect(find.text('Merchant or sender'), findsOneWidget);
  });

  testWidgets(
    'Dismiss filtered confirms and removes only visible items when a date filter is active',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: '1',
          sender: 'VM-OCT',
          body: 'Rs.100 spent on HDFC Bank Card ending 1234 at FIRST SHOP.',
          receivedAt: DateTime(2026, 10, 4),
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: '2',
          sender: 'VM-SEP',
          body: 'Rs.200 spent on HDFC Bank Card ending 5678 at SECOND SHOP.',
          receivedAt: DateTime(2026, 9, 4),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      await tester.tap(find.text('Oct 2026 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('VM-SEP'), findsNothing);

      await tester.tap(find.text('Dismiss filtered (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss 1 filtered review items?'), findsOneWidget);
      expect(
        find.text(
          'This removes only the 1 items currently visible under this filter. Other review items will not be affected.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await reviews.fetchAll(), hasLength(2));
      expect(find.text('VM-OCT'), findsOneWidget);
      expect(find.text('VM-SEP'), findsNothing);

      await tester.tap(find.text('Dismiss filtered (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Dismiss filtered'));
      await tester.pumpAndSettle();

      final remaining = await reviews.fetchAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, '2');
    },
  );

  testWidgets(
    'BundleReviewCard displays aggregated Pay Later drawdown bundle and expands/dismisses',
    (tester) async {
      final repo = _FakeUserCardsRepository();
      await reviews.add(
        NeedsReviewItem(
          id: 'axio-1',
          sender: 'AX-axioFS-S',
          body:
              'You have availed Amazon Pay Later credit of Rs. 250.00 for order on Amazon.',
          receivedAt: DateTime(2026, 3, 10),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: 'axio-2',
          sender: 'AX-axioFS-S',
          body:
              'You have availed Amazon Pay Later credit of Rs. 450.00 for order on Swiggy.',
          receivedAt: DateTime(2026, 3, 15),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: 'axio-3',
          sender: 'AX-axioFS-S',
          body:
              'You have availed Amazon Pay Later credit of Rs. 100.00 for order on Uber.',
          receivedAt: DateTime(2026, 3, 20),
          kind: NeedsReviewKind.payLaterDrawdown,
        ),
      );

      await _pump(tester, repo: repo, reviews: reviews);

      expect(find.text('Amazon Pay Later (Axio)'), findsOneWidget);
      expect(find.text('3 messages'), findsOneWidget);
      expect(find.text('Total: ₹800.00'), findsOneWidget);
      expect(
        find.text('Credit line drawdowns (billed in monthly AutoPay)'),
        findsOneWidget,
      );
      expect(find.text('Dismiss all 3 (Billed in AutoPay)'), findsOneWidget);
      expect(find.text('Show all 3'), findsOneWidget);

      // Expanding shows individual message tiles
      await tester.tap(find.text('Show all 3'));
      await tester.pumpAndSettle();

      expect(find.text('Hide messages'), findsOneWidget);
      expect(find.textContaining('Uber'), findsOneWidget);
      expect(find.textContaining('Swiggy'), findsOneWidget);
      expect(find.textContaining('Amazon'), findsWidgets);

      // Tapping bulk dismiss removes all 3 from repository and sends feedback
      await tester.tap(find.text('Dismiss all 3 (Billed in AutoPay)'));
      await tester.pumpAndSettle();

      expect(await reviews.fetchAll(), isEmpty);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(repo.allDismissArgs, hasLength(3));
      expect(
        repo.allDismissArgs.every((a) => a['reason'] == 'bundle_dismissed'),
        isTrue,
      );
    },
  );

  testWidgets('Pay Later / BNPL filter chip isolates Pay Later drawdowns', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'spend-1',
        sender: 'VM-HDFCBK',
        body: 'Rs. 500 spent on Card ending 1234 at RELIANCE.',
        receivedAt: DateTime(2026, 3, 10),
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: 'paylater-1',
        sender: 'AX-axioFS-S',
        body: 'You have availed Amazon Pay Later credit of Rs. 250.00.',
        receivedAt: DateTime(2026, 3, 15),
        kind: NeedsReviewKind.payLaterDrawdown,
      ),
    );

    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('VM-HDFCBK'), findsOneWidget);
    expect(find.text('AX-axioFS-S'), findsOneWidget);

    await tester.tap(find.text('Pay Later / BNPL'));
    await tester.pumpAndSettle();

    expect(find.text('VM-HDFCBK'), findsNothing);
    expect(find.text('AX-axioFS-S'), findsOneWidget);
    expect(find.text('Pay Later / Credit line drawdown'), findsOneWidget);
    expect(find.text('Add as Amazon Pay Later spend'), findsOneWidget);
  });

  testWidgets('future non-card bill bypasses review and persists directly', (
    tester,
  ) async {
    final future = DateTime.now().add(const Duration(days: 10));
    final dueOn = DateTime(future.year, future.month, future.day);
    final dueDateText =
        '${dueOn.year}-${dueOn.month.toString().padLeft(2, '0')}-${dueOn.day.toString().padLeft(2, '0')}';
    final commitments = CommitmentsRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-1',
        sender: 'JX-MYTNEU-S',
        body:
            'Your electricity bill of Rs. 10148.00 is ready. Pay by $dueDateText.',
        receivedAt: DateTime.now(),
        kind: NeedsReviewKind.commitment,
      ),
    );
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    final saved = await commitments.fetchAll();
    expect(saved, hasLength(1));
    expect(saved.single.amount?.paise, 1014800);
    expect(saved.single.dueOn, dueOn);
    expect(await reviews.fetchAll(), isEmpty);
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets('direct commitment never exposes a stale review close action', (
    tester,
  ) async {
    final future = DateTime.now().add(const Duration(days: 12));
    final dueDateText =
        '${future.day.toString().padLeft(2, '0')}-${future.month.toString().padLeft(2, '0')}-${future.year}';
    final commitments = CommitmentsRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-2',
        sender: 'HDFCBK',
        body:
            'Your utility bill of Rs. 2000 is generated. Due date $dueDateText',
        receivedAt: DateTime.now(),
        kind: NeedsReviewKind.commitment,
      ),
    );
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    expect(await reviews.fetchAll(), isEmpty);
    expect(await commitments.fetchAll(), hasLength(1));
    expect(find.byTooltip('Dismiss message'), findsNothing);
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets(
    'screenshot security case (HDFC Transaction Check Alert) is filtered out and not shown',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'sec-1',
          sender: 'VM-HDFCBK-S',
          body:
              'Transaction Check Alert! We tried to contact you twice to confirm the following txn: Rs.2,000.00 on Card XX4321 at AMAZON on 16-10-26. If this was not you, call 1860-266-2661',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'pure service alerts (ViCARE call forwarding) are filtered out and not shown',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'serv-1',
          sender: 'ViCARE',
          body: 'Call Forwarding is now active',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'screenshot investment settlement case (Kotak Neo) shows Review transfer and is actionable',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'kotak-1',
          sender: 'KOTAKN',
          body:
              'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account. You should receive funds in A/c XX1234 by EOD.',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Investment settlement payout'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Review transfer'), findsOneWidget);

      await tester.tap(find.text('Review transfer'));
      await tester.pumpAndSettle();

      expect(find.text('Review this transaction'), findsOneWidget);
      expect(find.text('Save transaction'), findsOneWidget);
    },
  );

  testWidgets(
    'ambiguous account debit shows Choose card/account action label',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'ambig-1',
          sender: 'HDFCBK',
          body: 'Rs.500 spent',
          reason: 'ambiguous_account_debit',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Choose card/account'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
    },
  );

  testWidgets(
    'saving reviewed transaction syncs structured fact override for 64-char source key',
    (tester) async {
      final key = 'f' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'VM-HDFCBK',
          body: 'Rs.499 spent at AMAZON',
          reason: 'no_transaction_match',
          receivedAt: DateTime(2026, 10, 1),
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      await tester.tap(find.text('Review transaction'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect((repo.lastOverrideArgs!['patch'] as Map)['amountRole'], 'posted');
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'balance_snapshot AI suggestion shows Confirm balance and persists observation on confirm',
    (tester) async {
      final key = 'b' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'HDFCBK',
          body: 'Available balance in A/c 1234 is INR 12500.50',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'balance_snapshot',
              'payload': {
                'availableBalanceInr': 12500.50,
                'accountLast4': '1234',
                'asOfAt': '2026-10-10T12:00:00.000Z',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      expect(find.text('Confirm balance'), findsOneWidget);
      await tester.tap(find.text('Confirm balance'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bank balance'), findsOneWidget);
      expect(find.text('12500.50'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm balance').last,
      );
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect(
        (repo.lastOverrideArgs!['patch'] as Map)['availableBalanceInr'],
        12500.50,
      );
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'bill_obligation with complete bill evidence bypasses stale AI review UI',
    (tester) async {
      final key = 'c' * 64;
      final dueOn = DateTime.now().add(const Duration(days: 10));
      final dueDate =
          '${dueOn.year}-${dueOn.month.toString().padLeft(2, '0')}-${dueOn.day.toString().padLeft(2, '0')}';
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'AIRTEL',
          body: 'Bill of Rs.1499.00 due on $dueDate for Broadband',
          receivedAt: DateTime.now(),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'bill_obligation',
              'payload': {
                'billerName': 'Airtel Broadband',
                'amountDueInr': 1499.00,
                'dueDate': dueOn.toUtc().toIso8601String(),
                'last4': '5678',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      final commitments = CommitmentsRepository(
        namespace: 'user:test',
        loadDatabase: () async => db,
      );
      await _pump(
        tester,
        repo: repo,
        reviews: reviews,
        commitments: commitments,
      );

      expect(find.text('Review bill'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(repo.lastOverrideArgs, isNull);
      expect(await reviews.fetchAll(), isEmpty);
      final savedBills = await commitments.fetchAll();
      expect(savedBills, hasLength(1));
    },
  );

  testWidgets(
    'multi-fact SMS resolves individual facts sequentially without dropping remaining ones',
    (tester) async {
      final key = 'd' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'HDFCBK',
          body: 'Rs.499.00 spent at SWIGGY. Avail Bal INR 12500.50 in A/c 1234',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'posted_movement',
              'payload': {
                'amountInr': 499.00,
                'merchant': 'SWIGGY',
                'instrument': 'upi_bank',
                'entryKind': 'spend',
              },
            },
            {
              'factIndex': 1,
              'factType': 'balance_snapshot',
              'payload': {
                'availableBalanceInr': 12500.50,
                'accountLast4': '1234',
                'asOfAt': '2026-10-10T12:00:00.000Z',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      // Both suggestions should be visible in multi-suggestion mode
      expect(find.text('Transaction: ₹499.00'), findsOneWidget);
      expect(find.text('Balance: ₹12500.50'), findsOneWidget);
      expect(find.text('Review transaction'), findsOneWidget);

      // Resolve first fact (transaction) via primary button
      await tester.tap(find.text('Review transaction'));
      await tester.pumpAndSettle();

      expect(find.text('Review this transaction'), findsOneWidget);
      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      // Transaction override recorded for fact 0
      expect(repo.allOverrideArgs, hasLength(1));
      expect(repo.allOverrideArgs[0]['factIndex'], 0);

      // Item must NOT be removed from queue; it now has 1 remaining suggestion (balance)
      final remainingItems = await reviews.fetchAll();
      expect(remainingItems, hasLength(1));
      expect(remainingItems.single.aiSuggestions, hasLength(1));
      expect(
        remainingItems.single.aiSuggestions!.single['factType'],
        'balance_snapshot',
      );

      // The button now says Confirm balance
      expect(find.text('Confirm balance'), findsOneWidget);

      // Resolve remaining fact (balance)
      await tester.tap(find.text('Confirm balance'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bank balance'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm balance').last,
      );
      await tester.pumpAndSettle();

      // Balance override recorded for fact 1
      expect(repo.allOverrideArgs, hasLength(2));
      expect(repo.allOverrideArgs[1]['factIndex'], 1);

      // Now all facts resolved, review queue is empty
      expect(await reviews.fetchAll(), isEmpty);
      expect(find.text('Nothing needs review'), findsOneWidget);
    },
  );

  testWidgets(
    'dismisses an AI promotion fact without treating it as a transaction',
    (tester) async {
      final id = List.filled(64, 'e').join();
      await reviews.add(
        NeedsReviewItem(
          id: id,
          sender: 'VM-HDFCBK',
          body: 'INR 499 spent at STORE. Get cashback on your next purchase.',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'promotion',
              'payload': <String, dynamic>{},
            },
            {
              'factIndex': 1,
              'factType': 'posted_movement',
              'payload': {
                'amountInr': 499.0,
                'merchant': 'STORE',
                'instrument': 'credit_card',
                'entryKind': 'spend',
              },
            },
          ],
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Promotional message'), findsOneWidget);
      expect(find.text('Not a transaction'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
      await tester.pumpAndSettle();

      final remaining = await reviews.fetchAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.aiSuggestions, hasLength(1));
      expect(
        remaining.single.aiSuggestions!.single['factType'],
        'posted_movement',
      );
    },
  );

  testWidgets(
    'dismissing not-a-transaction preserves immediate optimistic UI dismissal and calls dismissSms',
    (tester) async {
      final repo = _FakeUserCardsRepository();
      await reviews.add(
        NeedsReviewItem(
          id: 'txn-item-123',
          sender: 'VM-HDFCBK',
          body: 'Debited Rs. 500 at Store',
          receivedAt: DateTime(2026, 10, 22),
        ),
      );
      await _pump(tester, repo: repo, reviews: reviews);

      expect(find.text('Debited Rs. 500 at Store'), findsOneWidget);

      // Tap Ignore message (_dismissNotATransaction)
      await tester.tap(find.text('Ignore message'));
      await tester.pumpAndSettle();

      // 1. Immediate optimistic UI dismissal: item is gone immediately
      expect(find.text('Debited Rs. 500 at Store'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);

      // 2. repository.dismissSms was invoked with expected parameters
      expect(repo.lastDismissArgs, isNotNull);
      expect(repo.lastDismissArgs!['sourceKey'], 'txn-item-123');
      expect(repo.lastDismissArgs!['sender'], 'VM-HDFCBK');
      expect(repo.lastDismissArgs!['reason'], 'user_dismissed');
      expect(repo.lastDismissArgs!['family'], 'ignore_noise');
    },
  );

  testWidgets(
    'direct commitment is absent from review and does not call dismissSms',
    (tester) async {
      final repo = _FakeUserCardsRepository();
      final commitments = CommitmentsRepository(
        namespace: 'user:test',
        loadDatabase: () async => db,
      );
      final future = DateTime.now().add(const Duration(days: 14));
      final dueDateText =
          '${future.day.toString().padLeft(2, '0')}-${future.month.toString().padLeft(2, '0')}-${future.year}';
      await reviews.add(
        NeedsReviewItem(
          id: 'bill-item-456',
          sender: 'HDFCBK',
          body:
              'Your utility bill of Rs. 2000 is generated. Due date $dueDateText',
          receivedAt: DateTime.now(),
          kind: NeedsReviewKind.commitment,
        ),
      );
      await _pump(
        tester,
        repo: repo,
        reviews: reviews,
        commitments: commitments,
      );

      expect(await reviews.fetchAll(), isEmpty);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await commitments.fetchAll(), hasLength(1));
      expect(find.byTooltip('Dismiss message'), findsNothing);
      expect(repo.lastDismissArgs, isNull);
    },
  );

  testWidgets(
    'Dismiss all calls dismissSms for all queued items and immediately clears screen',
    (tester) async {
      final repo = _FakeUserCardsRepository();
      await reviews.add(
        NeedsReviewItem(
          id: 'item-1',
          sender: 'VM-HDFCBK',
          body: 'Rs.100 spent on HDFC Bank Card ending 1234 at FIRST SHOP.',
          receivedAt: DateTime.now(),
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: 'item-2',
          sender: 'VM-HDFCBK',
          body: 'Rs.200 spent on HDFC Bank Card ending 5678 at SECOND SHOP.',
          receivedAt: DateTime.now(),
        ),
      );
      await _pump(tester, repo: repo, reviews: reviews);

      await tester.tap(find.text('Dismiss all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Dismiss all'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
      expect(repo.allDismissArgs, hasLength(2));
      expect(repo.allDismissArgs.map((a) => a['sourceKey']).toSet(), {
        'item-1',
        'item-2',
      });
    },
  );

  test(
    'UserCardsRepository.dismissSms handles offline network error gracefully by recording to retry queue',
    () async {
      final failingClient = MockClient((request) async {
        throw http.ClientException('Network is unreachable / device offline');
      });

      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.pandapay.test',
        accessToken: 'test-token',
        client: failingClient,
      );

      expect(repo.dismissalRetryQueue, isEmpty);

      // Calling dismissSms when offline must return false gracefully and record into local retry queue
      final result = await repo.dismissSms(
        sourceKey: 'abc' * 21 + 'd',
        sender: 'AD-HDFCBK',
        sampleBody: 'Sample SMS text',
        reason: 'user_dismissed',
        family: 'ignore_noise',
      );

      expect(result, isFalse);
      expect(repo.dismissalRetryQueue, hasLength(1));
      final entry = repo.dismissalRetryQueue.first;
      expect(entry.sourceKey, 'abc' * 21 + 'd');
      expect(entry.sender, 'AD-HDFCBK');
      expect(entry.reason, 'user_dismissed');
      expect(entry.family, 'ignore_noise');
    },
  );

  test(
    'UserCardsRepository.flushDismissalQueue retries offline queued dismissals upon reconnection',
    () async {
      var isOnline = false;

      final mockClient = MockClient((request) async {
        if (!isOnline) {
          throw http.ClientException('Connection reset');
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.pandapay.test',
        accessToken: 'test-token',
        client: mockClient,
      );

      // Initially offline
      await repo.dismissSms(
        sourceKey: 'key-offline-1',
        sender: 'AD-HDFCBK',
        reason: 'user_dismissed',
      );
      expect(repo.dismissalRetryQueue, hasLength(1));

      // Still offline: flush fails, entries remain
      final flushedOffline = await repo.flushDismissalQueue();
      expect(flushedOffline, 0);
      expect(repo.dismissalRetryQueue, hasLength(1));

      // Device reconnects
      isOnline = true;
      final flushedOnline = await repo.flushDismissalQueue();
      expect(flushedOnline, 1);
      expect(repo.dismissalRetryQueue, isEmpty);
    },
  );

  testWidgets(
    'displays formatted timestamps and orders latest-first by default',
    (tester) async {
      final olderDate = DateTime(2026, 8, 15, 10, 30);
      final newerDate = DateTime(2026, 10, 4, 9, 53);

      await reviews.add(
        NeedsReviewItem(
          id: 'old-1',
          sender: 'VM-WELFOR',
          body: 'Rs.200 spent on card',
          receivedAt: olderDate,
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: 'new-1',
          sender: 'AD-HDFCBK',
          body: 'Rs.500 spent on card',
          receivedAt: newerDate,
        ),
      );

      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Oct 4, 2026 • 9:53 AM'), findsOneWidget);
      expect(find.text('Aug 15, 2026 • 10:30 AM'), findsOneWidget);

      final newPos = tester.getTopLeft(find.text('AD-HDFCBK')).dy;
      final oldPos = tester.getTopLeft(find.text('VM-WELFOR')).dy;
      expect(newPos, lessThan(oldPos));
    },
  );

  testWidgets(
    'filter chips filter by month and show clean empty state when no items in month',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'oct-1',
          sender: 'AD-HDFCBK',
          body: 'Rs.500 spent on card',
          reason: 'unparseable_amount',
          receivedAt: DateTime(2026, 10, 4, 9, 53),
        ),
      );
      await reviews.add(
        NeedsReviewItem(
          id: 'sep-1',
          sender: 'VA-CANBNK',
          body: 'Rs.300 spent on card',
          reason: 'unparseable_amount',
          receivedAt: DateTime(2026, 9, 10, 14, 0),
        ),
      );

      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('All time'), findsOneWidget);
      expect(find.text('Oct 2026 (1)'), findsOneWidget);
      expect(find.text('Sep 2026 (1)'), findsOneWidget);

      await tester.tap(find.text('Oct 2026 (1)'));
      await tester.pumpAndSettle();

      expect(find.text('AD-HDFCBK'), findsOneWidget);
      expect(find.text('VA-CANBNK'), findsNothing);

      await tester.tap(find.text('Bills & Mandates'));
      await tester.pumpAndSettle();

      expect(find.text('No review items in Oct 2026'), findsOneWidget);

      await tester.tap(find.text('All types'));
      await tester.pumpAndSettle();
      expect(find.text('AD-HDFCBK'), findsOneWidget);

      await tester.tap(find.text('All time'));
      await tester.pumpAndSettle();
      expect(find.text('AD-HDFCBK'), findsOneWidget);
      expect(find.text('VA-CANBNK'), findsOneWidget);
    },
  );

  testWidgets(
    'renders dual segmented tabs with pending and auto-resolved counts',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'pending-1',
          sender: 'VM-HDFCBK',
          body: 'Rs.499 spent on HDFC Bank Card ending 1234 at SHOP.',
          receivedAt: DateTime.now(),
        ),
      );
      final entries = [
        _historyEntry(id: 'auto-1', title: 'SWIGGY', autoResolvedAt: 2000),
        _historyEntry(
          id: 'auto-2',
          title: 'Airtel Broadband',
          resolvedKind: 'bill',
          categorySlug: 'bills',
          amountPaise: 149900,
          dueDate: '2026-11-05T12:00:00.000Z',
          autoResolvedAt: 1000,
        ),
      ];

      await _pump(
        tester,
        repo: _FakeUserCardsRepository(),
        reviews: reviews,
        autoResolved: entries,
      );

      expect(find.text('Needs Review (1)'), findsOneWidget);
      expect(find.text('Auto-Resolved (2)'), findsOneWidget);
      expect(find.text('Dismiss all'), findsOneWidget);
    },
  );

  testWidgets('renders both tabs without overflow at a small phone width', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'small-1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent on HDFC Bank Card ending 1234 at SHOP.',
        receivedAt: DateTime.now(),
      ),
    );
    final entries = [_historyEntry(id: 'small-auto', title: 'SWIGGY')];

    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      autoResolved: entries,
      surfaceSize: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Needs Review (1)'), findsOneWidget);
    expect(find.text('Auto-Resolved (1)'), findsOneWidget);

    await tester.tap(find.text('Auto-Resolved (1)'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Change Category'), findsOneWidget);
    expect(find.text('Move to Review'), findsOneWidget);
  });

  testWidgets(
    'auto-resolved tab shows newest-first feed with AI badge, category and due date',
    (tester) async {
      final entries = [
        _historyEntry(id: 'auto-new', title: 'SWIGGY', autoResolvedAt: 2000),
        _historyEntry(
          id: 'auto-old',
          title: 'Airtel Broadband',
          resolvedKind: 'bill',
          categorySlug: 'bills',
          amountPaise: 149900,
          dueDate: '2026-11-05T12:00:00.000Z',
          autoResolvedAt: 1000,
        ),
      ];

      await _pump(
        tester,
        repo: _FakeUserCardsRepository(),
        reviews: reviews,
        autoResolved: entries,
      );

      await tester.tap(find.text('Auto-Resolved (2)'));
      await tester.pumpAndSettle();

      expect(find.text('✦ Auto-Categorized by AI · Dining'), findsOneWidget);
      expect(
        find.text('✦ Auto-Categorized by AI · Bills & Utilities'),
        findsOneWidget,
      );
      expect(find.text('₹499.00'), findsOneWidget);
      expect(find.text('₹1,499.00'), findsOneWidget);
      expect(find.text('Due Nov 5, 2026'), findsOneWidget);
      expect(find.text('Change Category'), findsNWidgets(2));
      expect(find.text('Move to Review'), findsNWidgets(2));
      expect(find.textContaining('Gemini'), findsNothing);
      expect(find.text('Dismiss all'), findsNothing);

      final newest = tester.getTopLeft(find.text('SWIGGY')).dy;
      final oldest = tester.getTopLeft(find.text('Airtel Broadband')).dy;
      expect(newest, lessThan(oldest));
    },
  );

  testWidgets(
    'pending item with AI suggestions shows the suggested category badge',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'ai-cat-1',
          sender: 'VM-HDFCBK',
          body: 'INR 499 spent at SWIGGY on card ending 1234.',
          receivedAt: DateTime.now(),
          aiSuggestions: const [
            {
              'factIndex': 0,
              'factType': 'posted_movement',
              'payload': {
                'amountInr': 499,
                'merchant': 'SWIGGY',
                'category': 'dining',
              },
            },
          ],
        ),
      );

      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('✦ AI suggested · Dining'), findsOneWidget);
      expect(find.text('AI review not started'), findsOneWidget);
    },
  );

  testWidgets('Change Category calls the controller for the chosen category', (
    tester,
  ) async {
    final controller = _FakeSmsAutoResolutionController();
    final entries = [_historyEntry(id: 'auto-cat', title: 'SWIGGY')];

    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      autoResolved: entries,
      autoResolutionController: controller,
    );

    await tester.tap(find.text('Auto-Resolved (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change Category'));
    await tester.pumpAndSettle();

    expect(find.text('Change category'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);

    await tester.tap(find.text('Fuel'));
    await tester.pumpAndSettle();

    expect(controller.changedEntry?.id, 'auto-cat');
    expect(controller.changedCategory, 'fuel');
    expect(find.text('Change category'), findsNothing);
  });

  testWidgets(
    'Move to Review removes the history item and adds a pending review item',
    (tester) async {
      final entries = [_historyEntry(id: 'auto-move', title: 'SWIGGY')];
      final controller = _FakeSmsAutoResolutionController()
        ..onMoveToReview = (entry) async {
          entries.removeWhere((item) => item.id == entry.id);
          await reviews.add(
            NeedsReviewItem(
              id: 'review-${entry.id}',
              sender: 'VM-HDFCBK',
              body: 'Rs.499 spent on HDFC Bank Card ending 1234 at SWIGGY.',
              receivedAt: DateTime.now(),
            ),
          );
        };

      await _pump(
        tester,
        repo: _FakeUserCardsRepository(),
        reviews: reviews,
        autoResolved: entries,
        autoResolutionController: controller,
      );

      await tester.tap(find.text('Auto-Resolved (1)'));
      await tester.pumpAndSettle();
      expect(find.text('SWIGGY'), findsOneWidget);

      await tester.tap(find.text('Move to Review'));
      await tester.pumpAndSettle();

      expect(controller.movedEntry?.id, 'auto-move');
      expect(find.text('Moved to Needs Review'), findsOneWidget);
      expect(find.text('No auto-resolved items yet'), findsOneWidget);
      expect(find.text('Needs Review (1)'), findsOneWidget);
      expect(await reviews.fetchAll(), hasLength(1));

      await tester.tap(find.text('Needs Review (1)'));
      await tester.pumpAndSettle();
      expect(
        find.text('Rs.499 spent on HDFC Bank Card ending 1234 at SWIGGY.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'reviewing investment or folio allotment defaults category to investments and entryKind to investment',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'mf-allotment-1',
          sender: 'CAMSSM',
          body:
              'Folio 99887766: Purchase of Rs 12000 in Parag Parikh Flexi Cap Fund processed. 45.67 units allotted at NAV 262.75 on 05-Oct-2026.',
          kind: NeedsReviewKind.investmentSettlement,
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      expect(find.text('Review transfer'), findsOneWidget);
      await tester.tap(find.text('Review transfer'));
      await tester.pumpAndSettle();

      expect(find.text('Review this transaction'), findsOneWidget);
      expect(find.text('Investment'), findsOneWidget);

      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      expect(repo.lastLogArgs?['categoryId'], 'investments');
      expect(repo.lastLogArgs?['entryKind'], TxnEntryKind.investment);
    },
  );
}
