import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Fact _fact(String id, String source, String engine, {String? ruleId}) {
  final j =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  j['factId'] = _hex(id);
  j['sourceKey'] = source;
  final prov = (j['provenance'] as Map).cast<String, Object?>();
  prov['engine'] = engine;
  if (ruleId != null) prov['ruleId'] = ruleId;
  j['provenance'] = prov;
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
  final now = DateTime(2026, 11, 10);

  test(
    'only Gemini reads are AI auto-resolved; user facts are History; rule reads show nowhere',
    () {
      final lists = settledLists(
        [
          _entry('a', 'sa', DateTime(2026, 11, 8)),
          _entry('b', 'sb', DateTime(2026, 11, 9)),
          _entry('c', 'sc', DateTime(2026, 11, 7)),
        ],
        {
          'sa': [_fact('fa', 'sa', 'rules')],
          'sb': [_fact('fb1', 'sb', 'rules'), _fact('fb2', 'sb', 'user')],
          'sc': [_fact('fc', 'sc', 'rules', ruleId: 'AI-abc123')],
        },
        now: now,
      );
      expect(lists.history.map((i) => i.entry.id), ['b']);
      expect(lists.history.single.byUser, isTrue);
      // Rule reads are silent; only the Gemini one (c) is listed.
      expect(lists.auto.map((i) => i.entry.id), ['c']);
      expect(lists.auto.single.how, 'Read by a Gemini AI rule, verified');
      expect(lists.auto.single.source, SettledSource.ai);
    },
  );

  test('the reader is named from the rule ids', () {
    expect(settledSourceOf(['BNK-HDFC-01']), SettledSource.rule);
    expect(settledSourceOf(['SOLVER-REFINED']), SettledSource.onDevice);
    expect(
      settledSourceOf(['GEN-DEBIT-01', 'AI-9f:local:ab']),
      SettledSource.ai,
    );
    expect(settledSourceOf(const []), SettledSource.rule);
  });

  test('an AI rule that exists only on this phone is not yet verified', () {
    final lists = settledLists(
      [_entry('u', 'su', DateTime(2026, 11, 8))],
      {
        'su': [_fact('fu', 'su', 'rules', ruleId: 'AI-abc:local:def')],
      },
      now: now,
    );
    expect(lists.auto.single.how, 'Read by a Gemini AI rule, not yet verified');
  });

  test('old, unsourced and non-v2 transactions are left out', () {
    final old = _entry('old', 'so', DateTime(2026, 5, 1));
    final v1 = TransactionEntry(
      id: 'v1',
      amount: Money.fromPaise(100),
      occurredAt: DateTime(2026, 11, 9),
      sourceKey: 'sv',
      source: 'sms',
      status: 'active',
    );
    final lists = settledLists(
      [old, v1, _entry('n', 'sn', DateTime(2026, 11, 9))],
      {
        'so': [_fact('fo', 'so', 'rules')],
        'sv': [_fact('fv', 'sv', 'rules')],
      },
      now: now,
    );
    expect(lists.auto, isEmpty);
    expect(lists.history, isEmpty);
  });

  test('each list is capped at the row limit, newest first', () {
    final entries = [
      for (var i = 0; i < settledMaxRows + 20; i++)
        _entry(
          't$i',
          's$i',
          DateTime(2026, 11, 9).subtract(Duration(minutes: i)),
        ),
    ];
    final facts = {
      for (var i = 0; i < settledMaxRows + 20; i++)
        's$i': [_fact('f$i', 's$i', 'rules', ruleId: 'AI-cap$i')],
    };
    final lists = settledLists(entries, facts, now: now);
    expect(lists.auto.length, settledMaxRows);
    expect(lists.auto.first.entry.id, 't0');
  });

  testWidgets('a card shows the shop, the amount and how it was settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SettledCard(
              item: SettledItem(
                entry: _entry('x', 'sx', DateTime(2026, 11, 8)),
                byUser: false,
                how: 'Read by a rule',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Shop x'), findsOneWidget);
    expect(find.text('Read by a rule'), findsOneWidget);
    expect(find.textContaining('250'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Move back to review'), findsOneWidget);
  });

  group('with a phone database', () {
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

    testWidgets('Move to Needs review opens one review row, and is repeatable', (
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
      final entry = _entry('r', 'sr', DateTime(2026, 11, 8));
      await tester.runAsync(() => reopenForReview(ref, entry));
      var rows = db.select(
        "SELECT kind, status, payload FROM v2_review_items WHERE namespace='user:one'",
      );
      expect(rows.length, 1);
      expect(rows.single['kind'], 'event');
      expect(rows.single['status'], 'open');
      expect(jsonDecode(rows.single['payload'] as String) as Map, {
        'sourceKey': 'sr',
        'eventId': 'event-r',
        'reason': 'reopened',
        'hasReading': true,
      });
      // Answered earlier, then moved back again: it opens once more.
      db.execute("UPDATE v2_review_items SET status='resolved'");
      await tester.runAsync(() => reopenForReview(ref, entry));
      rows = db.select('SELECT status FROM v2_review_items');
      expect(rows.length, 1);
      expect(rows.single['status'], 'open');
      // A transaction with no stored message cannot be put back.
      final bare = TransactionEntry(
        id: 'b',
        amount: Money.fromPaise(100),
        occurredAt: DateTime(2026, 11, 8),
        source: 'sms',
        status: 'active',
      );
      Object? failure;
      await tester.runAsync(() async {
        try {
          await reopenForReview(ref, bare);
        } catch (e) {
          failure = e;
        }
      });
      expect(failure, isA<ArgumentError>());
    });

    test(
      'failed and turned-down AI drafts are counted; ready ones are not',
      () async {
        final db = cache.financialStore.database.db;
        void put(String key, String status) => db.execute(
          'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?)',
          [
            'user:one',
            key,
            jsonEncode({'status': status}),
          ],
        );
        put('ai:a', 'failed');
        put('ai:b', 'rejected');
        put('ai:c', 'ready');
        db.execute(
          'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?)',
          [
            'user:two',
            'ai:z',
            jsonEncode({'status': 'failed'}),
          ],
        );
        expect(await container.read(aiUnreadCountProvider.future), 2);
      },
    );
  });

  testWidgets(
    'the AI auto-resolved tab lists the Gemini items with a plain note',
    (tester) async {
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
                    how: 'Read by a Gemini AI rule, verified',
                  ),
                ],
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettledList(history: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Filed by Gemini AI'), findsOneWidget);
      expect(find.text('Shop g'), findsOneWidget);
      expect(find.text('Read by a Gemini AI rule, verified'), findsOneWidget);
    },
  );

  testWidgets('an empty AI tab says what will appear there', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settledListsProvider.overrideWith(
            (ref) async => const SettledLists(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SettledList(history: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing filed by Gemini yet'), findsOneWidget);
  });

  group('the Gemini status bar', () {
    const counted = AiServerStatus(countedNow: true, eligible: true);

    test(
      'says it is unavailable, never an error, when the server is unreachable',
      () {
        final s = geminiBarState(
          server: null,
          local: const AiReviewStatus(),
          unreadOnPhone: 0,
          openItems: 4,
        );
        expect(s.tone, GeminiTone.unknown);
        expect(s.title, 'Gemini status unavailable');
        expect(s.detail, contains('4 still need you'));
        expect(s.progress, isFalse);
      },
    );

    test(
      'offline, a format the phone already sent still shows as checking',
      () {
        final s = geminiBarState(
          server: null,
          local: const AiReviewStatus(checkingTemplates: {'a', 'b'}),
          unreadOnPhone: 0,
          openItems: 1,
        );
        expect(s.tone, GeminiTone.ok);
        expect(s.title, 'Gemini is checking 2 message formats');
        expect(s.progress, isTrue);
      },
    );

    test(
      'a phone that is not counted says Gemini is not receiving its formats',
      () {
        final s = geminiBarState(
          server: const AiServerStatus(
            countedNow: false,
            eligible: false,
            total: 12,
            held: 12,
          ),
          local: const AiReviewStatus(),
          unreadOnPhone: 0,
          openItems: 0,
        );
        expect(s.tone, GeminiTone.warn);
        expect(s.title, 'Gemini is not receiving your message formats');
        expect(s.detail, contains('12 formats held back'));
        expect(s.detail, contains('tester'));
      },
    );

    test('a not-counted phone with no formats yet still warns', () {
      final s = geminiBarState(
        server: const AiServerStatus(countedNow: false, eligible: false),
        local: null,
        unreadOnPhone: 0,
        openItems: 0,
      );
      expect(s.tone, GeminiTone.warn);
      expect(s.detail, contains('would be held back'));
    });

    test(
      'layouts waiting or being drafted show as working, with a moving bar',
      () {
        final s = geminiBarState(
          server: const AiServerStatus(
            countedNow: true,
            eligible: true,
            total: 6,
            queued: 2,
            working: 1,
            ready: 2,
            failed: 1,
          ),
          local: null,
          unreadOnPhone: 0,
          openItems: 0,
        );
        expect(s.tone, GeminiTone.ok);
        expect(s.title, 'Gemini is working');
        expect(s.detail, '1 drafting · 2 waiting · 2 done · 1 failed');
        expect(s.progress, isTrue);
      },
    );

    test(
      'an older queued layout still shows as working on a phone not counted now',
      () {
        final s = geminiBarState(
          server: const AiServerStatus(
            countedNow: false,
            eligible: true,
            total: 1,
            queued: 1,
          ),
          local: null,
          unreadOnPhone: 0,
          openItems: 0,
        );
        expect(s.title, 'Gemini is working');
      },
    );

    test(
      'when everything finished and some failed, it warns with the failures',
      () {
        final s = geminiBarState(
          server: const AiServerStatus(
            countedNow: true,
            eligible: true,
            total: 3,
            ready: 2,
            failed: 1,
          ),
          local: null,
          unreadOnPhone: 0,
          openItems: 0,
        );
        expect(s.tone, GeminiTone.warn);
        expect(s.title, 'Gemini could not draft 1 format');
      },
    );

    test('on and idle: nothing sent yet, and all done', () {
      expect(
        geminiBarState(
          server: counted,
          local: null,
          unreadOnPhone: 0,
          openItems: 0,
        ).detail,
        'No unreadable message formats have been sent yet.',
      );
      final s = geminiBarState(
        server: const AiServerStatus(
          countedNow: true,
          eligible: true,
          total: 4,
          ready: 3,
          covered: 1,
        ),
        local: null,
        unreadOnPhone: 0,
        openItems: 0,
      );
      expect(s.title, 'Gemini is on');
      expect(s.detail, '4 formats sent · 4 done · 0 held back');
      expect(s.progress, isFalse);
    });

    test('the server reply is read defensively', () {
      final s = AiServerStatus.fromJson({
        'countedNow': true,
        'eligible': 'yes',
        'total': -2,
        'held': 1.5,
        'ready': 3,
      });
      expect(s.countedNow, isTrue);
      expect(s.eligible, isFalse);
      expect(s.total, 0);
      expect(s.held, 0);
      expect(s.ready, 3);
    });

    Future<void> pumpBar(WidgetTester tester, AiServerStatus? server) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            geminiServerStatusProvider.overrideWith((ref) async => server),
            aiReviewStatusProvider.overrideWith(
              (ref) async => const AiReviewStatus(),
            ),
            aiUnreadCountProvider.overrideWith((ref) async => 0),
          ],
          child: const MaterialApp(
            home: Scaffold(body: GeminiStatusBar(openItems: 2)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows the warning for a phone that is not counted', (
      tester,
    ) async {
      await pumpBar(
        tester,
        const AiServerStatus(
          countedNow: false,
          eligible: false,
          total: 5,
          held: 5,
        ),
      );
      expect(find.byKey(const Key('gemini-status-bar')), findsOneWidget);
      expect(
        find.text('Gemini is not receiving your message formats'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('shows a moving bar while Gemini works', (tester) async {
      await pumpBar(
        tester,
        const AiServerStatus(
          countedNow: true,
          eligible: true,
          total: 2,
          working: 1,
          queued: 1,
        ),
      );
      expect(find.text('Gemini is working'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });
}
