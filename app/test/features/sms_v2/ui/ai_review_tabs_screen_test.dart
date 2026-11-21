// The three-tab Needs review screen: Needs review | AI auto-resolved | History. The AI suggested badge on a Needs
// review card, Dismiss on the AI auto-resolved cards, Recover on History rows. All data is invented.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart' show ConsentRecord;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/pipeline/ai_doubt.dart';
import 'package:pandapay/features/sms_v2/providers/ai_review_doubt.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/dismissal_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart' show LedgerSnapshot;

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Fact _fact(String id, String source, {String ruleId = 'AI-aaa111:local:abc'}) {
  final j =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/bill_due.total_only.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  j['factId'] = _hex(id);
  j['sourceKey'] = source;
  j['provenance'] = <String, Object?>{
    ...(j['provenance'] as Map).cast<String, Object?>(),
    'ruleId': ruleId,
  };
  return Fact.fromJson(j);
}

LocalReviewItem _question(
  String source,
  String body, {
  bool hasReading = true,
  String hash = 'h',
}) => LocalReviewItem(
  id: '$source:0',
  kind: 'template',
  payload: {'sourceKey': source, 'templateHash': hash, 'hasReading': hasReading},
  message: SmsIntakeEntry(
    source,
    QueuedSms(
      sender: 'AX-SYNTHBK',
      body: body,
      receivedAt: DateTime.utc(2026, 11, 5),
    ),
  ),
);

TransactionEntry _entry(String id, String source, DateTime at) =>
    TransactionEntry(
      id: id,
      amount: Money.fromPaise(25000),
      occurredAt: at,
      sourceKey: source,
      eventId: 'event-$id',
      merchantName: 'Shop $id',
      source: 'sms',
      status: 'active',
      pipelineVersion: 2,
    );

Widget _screen({
  required List<LocalReviewItem> reviews,
  required AiReviewStatus ai,
  required SettledLists settled,
  List<LocalReviewItem> dismissed = const [],
  List<Override> extra = const [],
}) => ProviderScope(
  overrides: [
    reviewItemsProvider.overrideWith((ref) async => reviews),
    dismissedReviewItemsProvider.overrideWith((ref) async => dismissed),
    aiReviewStatusProvider.overrideWith((ref) async => ai),
    settledListsProvider.overrideWith((ref) async => settled),
    aiReadPreviewProvider.overrideWith((ref, key) async => null),
    smsV2RuntimeProvider.overrideWith((ref) async => null),
    geminiServerStatusProvider.overrideWith(
      (ref) async => const AiServerStatus(
        countedNow: true,
        eligible: true,
        total: 86,
        ready: 86,
      ),
    ),
    aiUnreadCountProvider.overrideWith((ref) async => 0),
    app.smsSharedLearningConsentProvider.overrideWith(
      (ref) async => ConsentRecord(
        purpose: 'sms_shared_learning',
        granted: true,
        grantedAt: DateTime(2026, 11, 1),
      ),
    ),
    ...extra,
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ReviewInboxScreen()),
      ],
    ),
  ),
);

void main() {
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // Needs review: an AI reading the AI is unsure about, an AI reading it is sure about (AI auto-resolved), and a
  // message nothing could read.
  final unsure = _question('unsure', 'Bill due Rs.1,179 by 15 Nov', hash: 'h1');
  final sure = _question('sure', 'Bill due Rs.349 by 18 Nov', hash: 'h2');
  final unread = _question(
    'unread',
    'Something odd happened on your account',
    hasReading: false,
    hash: 'h3',
  );
  final aiStatus = AiReviewStatus(
    resolved: {
      'unsure': const AiResolution(ruleId: 'AI-x', verified: false),
      'sure': const AiResolution(ruleId: 'AI-y', verified: false),
    },
    readings: const AiOpenReadings(
      confident: {'sure'},
      doubtful: {'unsure': AiDoubt.lowConfidence},
    ),
  );
  final settled = SettledLists(
    auto: [
      SettledItem(
        entry: _entry('g', 'sg', DateTime(2026, 11, 8)),
        byUser: false,
        source: SettledSource.ai,
        how: 'Read by an AI rule, not yet verified',
      ),
    ],
    history: [
      SettledItem(
        entry: _entry('e', 'se', DateTime(2026, 11, 7)),
        byUser: true,
        source: SettledSource.ai,
        how: 'The AI read this; you confirmed or fixed it',
      ),
    ],
    dismissed: [
      DismissedAutoItem(
        record: AutoDismissal(
          sourceKey: 'dr',
          kind: AutoDismissal.kindRead,
          dismissedAt: DateTime.utc(2026, 11, 9),
        ),
        title: 'Balance ₹40,200',
        occurredAt: DateTime(2026, 11, 6),
      ),
    ],
  );
  final reviewDismissed = _question('nr', 'Your OTP is 1. Do not share it.', hasReading: false, hash: 'h4');

  testWidgets('three tabs only; counts are messages; no AI suggested or Dismissed tab', (tester) async {
    tall(tester);
    await tester.pumpWidget(
      _screen(
        reviews: [unsure, sure, unread],
        ai: aiStatus,
        settled: settled,
        dismissed: [reviewDismissed],
      ),
    );
    await tester.pumpAndSettle();
    // Needs review: the unsure reading and the unread message (the sure reading is AI auto-resolved).
    expect(find.text('Needs review (2)'), findsOneWidget);
    expect(find.text('AI auto-resolved (1)'), findsOneWidget);
    // History: one fixed reading + one dismissed from AI auto-resolved + one dismissed from Needs review.
    expect(find.text('History (3)'), findsOneWidget);
    expect(find.textContaining('AI suggested ('), findsNothing);
    expect(find.textContaining('Dismissed ('), findsNothing);
    final segments = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(segments.segments.length, 3);
    // The banner counts messages the AI read, including the one waiting for a check.
    expect(find.textContaining('AI read 2 of your messages'), findsOneWidget);
    expect(find.textContaining('1 needs your check'), findsOneWidget);
  });

  testWidgets('an AI reading the AI is unsure about stays on Needs review with the AI suggested badge; a sure one does not', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(
      _screen(reviews: [unsure, sure, unread], ai: aiStatus, settled: settled),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Bill due Rs.1,179'), findsOneWidget);
    expect(find.text('AI suggested, not yet verified'), findsOneWidget);
    expect(find.byKey(const Key('ai-doubt-reason')), findsOneWidget);
    expect(find.textContaining('not sure about this reading'), findsOneWidget);
    expect(find.byKey(const Key('ai-suggested-note')), findsOneWidget);
    // The confident reading is not a question here.
    expect(find.textContaining('Bill due Rs.349'), findsNothing);
    // The unread message has no AI badge, only the plain state.
    expect(find.textContaining('Something odd happened'), findsOneWidget);
    expect(find.textContaining('can’t read this message format yet'), findsOneWidget);
  });

  testWidgets('with no AI reading to check, there is no AI note on Needs review', (tester) async {
    tall(tester);
    await tester.pumpWidget(
      _screen(reviews: [unread], ai: const AiReviewStatus(), settled: const SettledLists()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-suggested-note')), findsNothing);
    expect(find.text('AI suggested, not yet verified'), findsNothing);
  });

  testWidgets('AI auto-resolved: Dismiss on a transaction card and on a message card', (tester) async {
    tall(tester);
    final reads = SettledLists(
      auto: [
        ...settled.auto,
        AiReadItem(
          sourceKey: 'bill',
          occurredAt: DateTime(2026, 11, 3),
          summary: 'Bill due ₹1,179 on 15 Nov',
          unverified: true,
        ),
      ],
    );
    await tester.pumpWidget(_screen(reviews: const [], ai: const AiReviewStatus(), settled: reads));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI auto-resolved (2)'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dismiss-g')), findsOneWidget);
    expect(find.byKey(const Key('dismiss-read-bill')), findsOneWidget);
    expect(find.text('Dismiss'), findsNWidgets(2));
    // Fix stays as in step 1.
    expect(find.byKey(const Key('edit-g')), findsOneWidget);
    expect(find.byKey(const Key('fix-read-bill')), findsOneWidget);
    expect(find.text('Waiting in Needs review'), findsNothing);
  });

  testWidgets('History: every dismissed row has Recover; a fixed AI reading is read-only with a note', (tester) async {
    tall(tester);
    await tester.pumpWidget(
      _screen(reviews: const [], ai: const AiReviewStatus(), settled: settled, dismissed: [reviewDismissed]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('History (3)'));
    await tester.pumpAndSettle();
    // The two dismissed rows each have Recover (one per Needs review format, one per auto-resolved message).
    expect(find.text('Recover'), findsNWidgets(2));
    expect(find.byKey(const Key('recover-dr')), findsOneWidget);
    expect(find.text('Dismissed from Needs review'), findsOneWidget);
    expect(find.textContaining('Dismissed from AI auto-resolved'), findsOneWidget);
    // The fixed reading: listed, with Edit, no way back to the AI's reading.
    expect(find.text('Shop e'), findsOneWidget);
    expect(find.byKey(const Key('history-no-restore-e')), findsOneWidget);
    expect(find.byKey(const Key('edit-e')), findsOneWidget);
    expect(find.byKey(const Key('dismiss-e')), findsNothing);
    expect(find.byKey(const Key('reopen-e')), findsNothing);
    expect(find.textContaining('all time'), findsOneWidget);
  });

  testWidgets('an empty History says what will appear there', (tester) async {
    tall(tester);
    await tester.pumpWidget(
      _screen(reviews: const [], ai: const AiReviewStatus(), settled: const SettledLists()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('History (0)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Messages you dismiss, and AI readings you fix'), findsOneWidget);
  });

  group('Dismiss and Recover write through the real store', () {
    late ResponseCache cache;
    late ProviderContainer container;
    const ns = 'user:one';

    setUp(() {
      final db = openInMemoryForTesting();
      cache = ResponseCache(db);
      SmsV2Schema.ensure(cache.financialStore.database.db);
      SmsIntakeRepository(cache.financialStore.database);
      container = ProviderContainer(
        overrides: [
          app.cacheNamespaceProvider.overrideWithValue(ns),
          app.responseCacheProvider.overrideWith((ref) async => cache),
          aiReviewStatusProvider.overrideWith((ref) async => const AiReviewStatus()),
          reviewItemsProvider.overrideWith((ref) async => const []),
          smsV2RuntimeProvider.overrideWith((ref) async => null),
          smsV2LedgerReadModelProvider.overrideWith(
            (ref) async => LedgerReadModel(
              v2Ready: true,
              ledger: LedgerSnapshot(entries: const [], events: const [], categoryByEvent: const {}),
              facts: FactStore(
                cache.financialStore.database.db,
                namespace: ns,
              ).all(),
              instruments: const [],
              transactions: const [],
            ),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        cache.financialStore.dispose();
        db.close();
      });
    });

    Future<(WidgetRef, Widget)> host(WidgetTester tester, Widget child) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  captured = ref;
                  return child;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (captured, child);
    }

    // The actions read providers and the database in real async work: give them real time, pumping in between.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
    }

    DismissalStore store() => DismissalStore(
      SyncStateStore(cache.financialStore.database.db, namespace: ns),
    );

    testWidgets('Dismiss on a message card saves the record; Recover (AI still reads it) clears it', (tester) async {
      final item = AiReadItem(
        sourceKey: 'bill',
        occurredAt: DateTime(2026, 11, 3),
        summary: 'Bill due ₹1,179 on 15 Nov',
        unverified: true,
      );
      FactStore(cache.financialStore.database.db, namespace: ns).insert(_fact('f1', 'bill'));
      await host(tester, AiReadCard(item: item));
      await tester.tap(find.byKey(const Key('dismiss-read-bill')));
      await settle(tester);
      final record = store().get('bill');
      expect(record, isNotNull);
      expect(record!.kind, AutoDismissal.kindRead);
      expect(record.origin, AutoDismissal.originAutoResolved);
      expect(find.textContaining('Dismissed. It is in History'), findsOneWidget);

      // Recover from the History row.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await host(
        tester,
        DismissedAutoCard(
          item: DismissedAutoItem(
            record: record,
            title: 'Bill due ₹1,179 on 15 Nov',
            occurredAt: DateTime(2026, 11, 3),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('recover-bill')));
      await settle(tester);
      expect(store().get('bill'), isNull);
      expect(find.text('Back in AI auto-resolved.'), findsOneWidget);
    });

    testWidgets('Recover when the AI no longer reads the message puts it on Needs review', (tester) async {
      final record = AutoDismissal(
        sourceKey: 'gone',
        kind: AutoDismissal.kindRead,
        dismissedAt: DateTime.utc(2026, 11, 9),
      );
      store().put(record);
      // No AI fact is left for 'gone' (its rule was rejected and its reading withdrawn).
      await host(
        tester,
        DismissedAutoCard(
          item: DismissedAutoItem(
            record: record,
            title: 'A message the AI read',
            occurredAt: DateTime(2026, 11, 3),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('recover-gone')));
      await settle(tester);
      expect(store().get('gone'), isNull);
      final rows = cache.financialStore.database.db.select(
        "SELECT kind,status FROM v2_review_items WHERE namespace=? AND review_id='reopen-read:gone'",
        [ns],
      );
      expect(rows.single['kind'], 'template');
      expect(rows.single['status'], 'open');
      expect(find.textContaining('back in Needs review'), findsOneWidget);
    });

    testWidgets('a transaction that cannot be hidden is not dismissed, and says so', (tester) async {
      final entry = _entry('t', 'st', DateTime(2026, 11, 8));
      await host(
        tester,
        SettledCard(
          item: SettledItem(
            entry: entry,
            byUser: false,
            source: SettledSource.ai,
            how: 'Read by an AI rule, not yet verified',
          ),
        ),
      );
      // No rule bundle in this test, so hiding fails: nothing may be left behind.
      await container.read(app.responseCacheProvider.future);
      await tester.tap(find.byKey(const Key('dismiss-t')));
      await settle(tester);
      expect(store().all(), isEmpty);
      expect(find.text('Could not dismiss this one'), findsOneWidget);
    });
  });
}
