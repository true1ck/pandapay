// The AI results tab (AI auto-resolved) lists every message an AI rule read, not
// only the ones that made a transaction. All data here is invented.
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
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

/// A fact built from a contract fixture, with its source, reader and time set.
Fact _fact(
  String fixture,
  String id,
  String source, {
  String engine = 'rules',
  String ruleId = 'AI-aaa111',
  DateTime? observedAt,
  void Function(Map<String, Object?> json)? edit,
}) {
  final j =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/$fixture.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  j['factId'] = _hex(id);
  j['sourceKey'] = source;
  if (observedAt != null) {
    j['observedAt'] = observedAt.toUtc().toIso8601String();
    j['occurredAt'] = observedAt.toUtc().toIso8601String();
  }
  final prov = (j['provenance'] as Map).cast<String, Object?>();
  prov['engine'] = engine;
  prov['ruleId'] = ruleId;
  j['provenance'] = prov;
  edit?.call(j);
  return Fact.fromJson(j);
}

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

void main() {
  final now = DateTime(2026, 11, 21);

  // Bill due 10 Nov, an attempt, an info message, a balance, plus a transaction.
  Map<String, List<Fact>> sampleFacts() => {
    'bill': [
      _fact(
        'bill_due.total_only',
        'f-bill',
        'bill',
        observedAt: DateTime.utc(2026, 11, 3, 8),
        edit: (j) {
          (j['attrs'] as Map)['dueDate'] = '2026-11-15';
          (j['amounts'] as List)[0] = {
            'role': 'due_total',
            'minor': 117900,
            'unit': 'INR',
          };
        },
      ),
    ],
    'attempt': [
      _fact(
        'attempt.declined_card',
        'f-att',
        'attempt',
        ruleId: 'AI-bbb222:local:${'c' * 64}',
        observedAt: DateTime.utc(2026, 11, 5, 8),
        edit: (j) {
          (j['attrs'] as Map)['status'] = 'failed';
          (j['amounts'] as List)[0] = {
            'role': 'posted',
            'minor': 34900,
            'unit': 'INR',
          };
        },
      ),
    ],
    'info': [
      _fact(
        'info.service',
        'f-info',
        'info',
        observedAt: DateTime.utc(2026, 11, 4, 8),
        edit: (j) {
          (j['attrs'] as Map)['amountMinor'] = null;
          j['attrs'] = {'category': 'service'};
        },
      ),
    ],
    'txn': [
      _fact(
        'movement.card_spend',
        'f-txn',
        'txn',
        observedAt: DateTime.utc(2026, 11, 6, 8),
      ),
    ],
    // Read by a signed rule, not an AI rule: never listed.
    'rule-bill': [
      _fact(
        'bill_due.total_only',
        'f-rb',
        'rule-bill',
        ruleId: 'BNK-RULE-1',
        observedAt: DateTime.utc(2026, 11, 7, 8),
      ),
    ],
    // An AI read the person then edited: never listed.
    'edited': [
      _fact(
        'bill_due.total_only',
        'f-ed1',
        'edited',
        observedAt: DateTime.utc(2026, 11, 8, 8),
      ),
      _fact(
        'bill_due.total_only',
        'f-ed2',
        'edited',
        engine: 'user',
        ruleId: 'USER-CORRECTION',
        observedAt: DateTime.utc(2026, 11, 8, 8),
      ),
    ],
  };

  group('settledLists: AI reads that made no transaction', () {
    test(
      'lists bill, attempt and info reads next to the transaction, newest first',
      () {
        final lists = settledLists(
          [_entry('t1', 'txn', DateTime(2026, 11, 6))],
          sampleFacts(),
          now: now,
        );
        expect(lists.auto.length, 4);
        expect(lists.autoTransactions.map((i) => i.entry.id), ['t1']);
        // Newest first across both kinds: transaction (6 Nov), attempt (5),
        // info (4), bill (3).
        expect(lists.auto.map((i) => i.orderKey), [
          't1',
          'attempt',
          'info',
          'bill',
        ]);
        final reads = {for (final r in lists.autoReads) r.sourceKey: r};
        expect(reads.keys, {'bill', 'attempt', 'info'});
        expect(reads['bill']!.summary, 'Bill due ₹1,179 on 15 Nov');
        expect(
          reads['attempt']!.summary,
          startsWith('Payment attempt failed ₹349'),
        );
        expect(reads['info']!.summary, 'Info: service notice');
        expect(reads['bill']!.occurredAt.toUtc(), DateTime.utc(2026, 11, 3, 8));
        expect(reads['bill']!.confidence, isNotNull);
      },
    );

    test(
      'the unverified flag follows the local rule id, like a transaction',
      () {
        final reads = {
          for (final r in settledLists(
            const [],
            sampleFacts(),
            now: now,
          ).autoReads)
            r.sourceKey: r,
        };
        expect(reads['attempt']!.unverified, isTrue);
        expect(reads['bill']!.unverified, isFalse);
        expect(reads['info']!.unverified, isFalse);
      },
    );

    test(
      'a message that has a transaction is listed once, as the transaction',
      () {
        final lists = settledLists(
          [_entry('t1', 'txn', DateTime(2026, 11, 6))],
          sampleFacts(),
          now: now,
        );
        expect(lists.autoReads.map((r) => r.sourceKey), isNot(contains('txn')));
      },
    );

    test('rule reads and messages the person edited are not listed', () {
      final lists = settledLists(const [], sampleFacts(), now: now);
      final keys = lists.autoReads.map((r) => r.sourceKey).toSet();
      expect(keys, isNot(contains('rule-bill')));
      expect(keys, isNot(contains('edited')));
      expect(lists.history, isEmpty);
    });

    test(
      'all time: an old AI read stays, and the count is the real length',
      () {
        final old = _fact(
          'bill_due.total_only',
          'f-old',
          'old',
          observedAt: DateTime.utc(2025, 3, 1),
        );
        final lists = settledLists(const [], {
          ...sampleFacts(),
          'old': [old],
        }, now: now);
        expect(lists.autoReads.map((r) => r.sourceKey), contains('old'));
        expect(lists.auto.last.orderKey, 'old');
        expect(
          lists.auto.length,
          lists.autoTransactions.length + lists.autoReads.length,
        );
      },
    );

    test('a read already open on Needs review says so', () {
      final lists = settledLists(
        const [],
        sampleFacts(),
        now: now,
        openReviewSources: {'bill'},
      );
      final reads = {for (final r in lists.autoReads) r.sourceKey: r};
      expect(reads['bill']!.inReview, isTrue);
      expect(reads['info']!.inReview, isFalse);
    });

    test('other fact types read in plain words too', () {
      final balance = _fact(
        'balance_snapshot.available_credit',
        'f-bal',
        'bal',
      );
      final limit = _fact('limit_change.increase', 'f-lim', 'lim');
      final hold = _fact('hold.ipo_placed', 'f-hold', 'hold');
      final lists = settledLists(const [], {
        'bal': [balance],
        'lim': [limit],
        'hold': [hold],
      }, now: now);
      final reads = {for (final r in lists.autoReads) r.sourceKey: r.summary};
      expect(reads['bal'], startsWith('Balance ₹'));
      expect(reads['lim'], startsWith('Credit limit increased to ₹'));
      expect(reads['hold'], startsWith('Money blocked'));
    });
  });

  group('the AI read card', () {
    Future<void> pumpCard(
      WidgetTester tester,
      AiReadItem item, {
      AiReadPreview? preview,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiReadPreviewProvider.overrideWith((ref, key) async => preview),
          ],
          child: MaterialApp(
            home: Scaffold(body: AiReadCard(item: item)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows what the AI understood, date, sender, badge and Fix', (
      tester,
    ) async {
      await pumpCard(
        tester,
        AiReadItem(
          sourceKey: 'bill',
          occurredAt: DateTime(2026, 11, 3),
          summary: 'Bill due ₹1,179 on 15 Nov',
          unverified: true,
        ),
        preview: const AiReadPreview(
          sender: 'AX-SYNTHBK',
          head: 'Your invented bill of Rs 1179 is due on 15-Nov.',
        ),
      );
      expect(find.text('Bill due ₹1,179 on 15 Nov'), findsOneWidget);
      expect(find.text('3 Nov 2026 · AX-SYNTHBK'), findsOneWidget);
      expect(find.text('Not verified yet'), findsOneWidget);
      expect(find.textContaining('invented bill of Rs 1179'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
    });

    testWidgets('a verified read says Verified', (tester) async {
      await pumpCard(
        tester,
        AiReadItem(
          sourceKey: 'k',
          occurredAt: DateTime(2026, 11, 3),
          summary: 'Info: service notice',
          unverified: false,
        ),
      );
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Not verified yet'), findsNothing);
      // The message is gone from the phone: still a card, just no sender or quote.
      expect(find.text('3 Nov 2026'), findsOneWidget);
    });

    testWidgets('a read already waiting in Needs review offers no second Fix', (
      tester,
    ) async {
      await pumpCard(
        tester,
        AiReadItem(
          sourceKey: 'k',
          occurredAt: DateTime(2026, 11, 3),
          summary: 'Balance ₹40,200',
          unverified: false,
          inReview: true,
        ),
      );
      expect(find.text('Waiting in Needs review'), findsOneWidget);
      expect(find.text('Fix'), findsNothing);
    });

    testWidgets(
      'the list reads each message lazily, only for the cards on screen',
      (tester) async {
        final asked = <String>[];
        final items = [
          for (var i = 0; i < 300; i++)
            AiReadItem(
              sourceKey: 's$i',
              occurredAt: DateTime(2026, 11, 3).subtract(Duration(minutes: i)),
              summary: 'Balance ₹$i',
              unverified: false,
            ),
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settledListsProvider.overrideWith(
                (ref) async => SettledLists(auto: items),
              ),
              aiReadPreviewProvider.overrideWith((ref, key) async {
                asked.add(key);
                return null;
              }),
            ],
            child: const MaterialApp(
              home: Scaffold(body: SettledList(history: false)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(asked, isNotEmpty);
        expect(
          asked.length,
          lessThan(30),
          reason: '300 items, only the visible ones read',
        );
      },
    );

    testWidgets('the tab lists transactions and other reads together', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settledListsProvider.overrideWith(
              (ref) async => SettledLists(
                auto: [
                  SettledItem(
                    entry: _entry('g', 'sg', DateTime(2026, 11, 8)),
                    byUser: false,
                    source: SettledSource.ai,
                    how: 'Read by an AI rule, verified',
                  ),
                  AiReadItem(
                    sourceKey: 'bill',
                    occurredAt: DateTime(2026, 11, 3),
                    summary: 'Bill due ₹1,179 on 15 Nov',
                    unverified: true,
                  ),
                ],
              ),
            ),
            aiReadPreviewProvider.overrideWith((ref, key) async => null),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettledList(history: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Shop g'), findsOneWidget);
      expect(find.text('Bill due ₹1,179 on 15 Nov'), findsOneWidget);
      expect(find.text('Not verified yet'), findsOneWidget);
      expect(find.textContaining('Not verified yet'), findsWidgets);
    });
  });

  group('Fix puts the message back on Needs review', () {
    late ResponseCache cache;
    late ProviderContainer container;
    setUp(() {
      final db = openInMemoryForTesting();
      cache = ResponseCache(db);
      SmsV2Schema.ensure(cache.financialStore.database.db);
      container = ProviderContainer(
        overrides: [
          app.cacheNamespaceProvider.overrideWithValue('user:one'),
          app.responseCacheProvider.overrideWith((ref) async => cache),
          aiReviewStatusProvider.overrideWith(
            (ref) async => const AiReviewStatus(),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        cache.financialStore.dispose();
        db.close();
      });
    });

    testWidgets('opens one template question keyed by the message, repeatably', (
      tester,
    ) async {
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, r, _) {
                ref = r;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final db = cache.financialStore.database.db;
      await tester.runAsync(() => reopenReadForReview(ref, 'bill'));
      var rows = db.select(
        "SELECT review_id, kind, status, payload FROM v2_review_items WHERE namespace='user:one'",
      );
      expect(rows.length, 1);
      expect(rows.single['kind'], 'template');
      expect(rows.single['status'], 'open');
      expect(jsonDecode(rows.single['payload'] as String) as Map, {
        'sourceKey': 'bill',
        'reason': 'reopened',
        // Keeps the message from being sent to the AI again for a new rule.
        'aiHold': 'reopened',
      });
      expect(openReviewSources(db, 'user:one'), {'bill'});
      expect(openReviewSources(db, 'user:two'), isEmpty);
      // Answered, then fixed again later: it opens once more, still one row.
      db.execute("UPDATE v2_review_items SET status='resolved'");
      expect(openReviewSources(db, 'user:one'), isEmpty);
      await tester.runAsync(() => reopenReadForReview(ref, 'bill'));
      rows = db.select('SELECT status FROM v2_review_items');
      expect(rows.length, 1);
      expect(rows.single['status'], 'open');
    });

    test(
      'the preview reads the sender and only the first 140 characters',
      () async {
        final db = cache.financialStore.database.db;
        db.execute('''
        CREATE TABLE IF NOT EXISTS sms_captured_messages (
          namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
          body TEXT NOT NULL, received_at INTEGER NOT NULL,
          PRIMARY KEY (namespace, id))''');
        db.execute(
          'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
          ['user:one', 'bill', 'AX-SYNTHBK', 'x' * 500, 1],
        );
        final preview = await container.read(
          aiReadPreviewProvider('bill').future,
        );
        expect(preview!.sender, 'AX-SYNTHBK');
        expect(preview.head.length, aiReadSnippetChars);
        expect(
          await container.read(aiReadPreviewProvider('none').future),
          isNull,
        );
      },
    );
  });

  testWidgets('the AI auto-resolved tab count is the real length of the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auto = <AutoItem>[
      SettledItem(
        entry: _entry('g', 'sg', DateTime(2026, 11, 8)),
        byUser: false,
        source: SettledSource.ai,
        how: 'Read by an AI rule, verified',
      ),
      for (var i = 0; i < 3; i++)
        AiReadItem(
          sourceKey: 'r$i',
          occurredAt: DateTime(2026, 11, 3).subtract(Duration(days: i)),
          summary: 'Balance ₹$i',
          unverified: i == 0,
        ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settledListsProvider.overrideWith(
            (ref) async => SettledLists(auto: auto),
          ),
          reviewItemsProvider.overrideWith((ref) async => const []),
          dismissedReviewItemsProvider.overrideWith((ref) async => const []),
          aiReviewStatusProvider.overrideWith(
            (ref) async => const AiReviewStatus(),
          ),
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
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const ReviewInboxScreen()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI auto-resolved (4)'), findsOneWidget);
    // The banner counts the same messages, never the server's 86 formats.
    expect(find.text('AI read 4 of your messages'), findsOneWidget);
    expect(find.textContaining('86'), findsNothing);
    await tester.tap(find.text('AI auto-resolved (4)'));
    await tester.pumpAndSettle();
    expect(find.text('Shop g'), findsOneWidget);
    expect(find.text('Balance ₹0'), findsOneWidget);
    expect(find.text('Not verified yet'), findsOneWidget);
  });
}
