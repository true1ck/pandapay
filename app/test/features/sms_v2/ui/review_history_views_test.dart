import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart' show ConsentRecord;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart' show AiPhoneDiagnostics, AiResolution;
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
      expect(lists.autoTransactions.map((i) => i.entry.id), ['c']);
      expect(lists.autoTransactions.single.how, 'Read by an AI rule, verified');
      expect(lists.autoTransactions.single.source, SettledSource.ai);
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
    expect(lists.autoTransactions.single.how, 'Read by an AI rule, not yet verified');
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

  test('AI auto-resolved lists every AI read, newest first; History stays capped at the row limit', () {
    final entries = [
      for (var i = 0; i < settledMaxRows + 20; i++)
        _entry(
          't$i',
          's$i',
          DateTime(2026, 11, 9).subtract(Duration(minutes: i)),
        ),
    ];
    final aiFacts = {
      for (var i = 0; i < settledMaxRows + 20; i++)
        's$i': [_fact('f$i', 's$i', 'rules', ruleId: 'AI-cap$i')],
    };
    final ai = settledLists(entries, aiFacts, now: now);
    expect(ai.auto.length, settledMaxRows + 20, reason: 'owner: show all, not a slice');
    expect((ai.auto.first as SettledItem).entry.id, 't0');
    final userFacts = {
      for (var i = 0; i < settledMaxRows + 20; i++)
        's$i': [_fact('u$i', 's$i', 'user')],
    };
    expect(settledLists(entries, userFacts, now: now).history.length, settledMaxRows);
  });

  test('AI auto-resolved covers all time; History keeps its 90-day window', () {
    final lists = settledLists(
      [
        _entry('ai-old', 'sa', DateTime(2025, 6, 3)),
        _entry('ai-new', 'sb', DateTime(2026, 11, 8)),
        _entry('user-old', 'sc', DateTime(2025, 8, 2)),
      ],
      {
        'sa': [_fact('fa', 'sa', 'rules', ruleId: 'AI-old1')],
        'sb': [_fact('fb', 'sb', 'rules', ruleId: 'AI-new1')],
        'sc': [_fact('fc', 'sc', 'user')],
      },
      now: now,
    );
    expect(lists.autoTransactions.map((i) => i.entry.id), ['ai-new', 'ai-old']);
    expect(lists.history, isEmpty, reason: 'an edit older than 90 days stays out of History');
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
                    how: 'Read by an AI rule, verified',
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
      expect(find.textContaining('messages AI read, newest first'), findsOneWidget);
      expect(find.text('Shop g'), findsOneWidget);
      expect(find.text('Read by an AI rule, verified'), findsOneWidget);
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
    expect(find.textContaining('No message has been read by AI yet'), findsOneWidget);
    expect(find.textContaining('open one to fix it'), findsOneWidget);
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
        expect(s.title, 'AI status unavailable');
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
        expect(s.title, 'AI is checking 2 message formats');
        expect(s.progress, isTrue);
      },
    );

    test(
      'a phone that is not counted says AI is not receiving its formats',
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
        expect(s.title, 'AI is not receiving your message formats yet');
        expect(s.detail, contains('12 formats held back'));
        expect(s.detail, contains('Nothing for you to do'));
        // No roles or owners are ever asked of the person.
        expect(s.detail.toLowerCase(), isNot(contains('tester')));
        expect(s.detail.toLowerCase(), isNot(contains('owner')));
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
        expect(s.title, 'AI is working');
        expect(s.detail, 'AI has not read any of your messages yet');
        expect(
          s.serverDetail,
          contains('Formats: 2 answered · 1 drafting · 2 waiting · 1 failed · 0 held back'),
        );
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
        expect(s.title, 'AI is working');
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
        expect(s.title, 'AI could not draft 1 format');
        // Says what happens next, so a failure is not a dead end.
        expect(s.detail, contains('stay in Needs review'));
        expect(s.detail, contains('AI has not read any of your messages yet'));
        expect(s.serverDetail, contains('Formats: 2 answered'));
        expect(s.serverDetail, contains('1 failed'));
      },
    );

    test('the main line counts messages from the phone; format counts sit apart', () {
      final s = geminiBarState(
        server: const AiServerStatus(
          countedNow: true,
          eligible: true,
          total: 86,
          ready: 2,
          covered: 1,
        ),
        local: const AiReviewStatus(
          resolved: {'a': AiResolution(ruleId: 'AI-x', verified: true)},
        ),
        unreadOnPhone: 3,
        openItems: 0,
        aiReadMessages: 4,
        unreadMessages: 2,
      );
      expect(s.detail, 'AI read 4 of your messages · 2 could not be read yet');
      // The server's numbers count formats, say so, and never reach the main line.
      expect(s.detail, isNot(contains('86')));
      expect(
        s.serverDetail,
        contains('Formats learned for your account: 86 (formats, not messages'),
      );
      expect(s.serverDetail, contains('Formats: 3 answered'));
      expect(s.serverDetail, contains('Formats applied on this phone: 1'));
    });

    test('a failed format keeps its explanation and says the messages are retried', () {
      final s = geminiBarState(
        server: const AiServerStatus(
          countedNow: true,
          eligible: true,
          total: 5,
          ready: 4,
          failed: 1,
        ),
        local: null,
        unreadOnPhone: 1,
        openItems: 2,
        aiReadMessages: 4,
        unreadMessages: 1,
      );
      expect(s.tone, GeminiTone.warn);
      expect(
        s.detail,
        startsWith('AI read 4 of your messages · 1 could not be read yet, retrying\n'),
      );
      expect(s.detail, contains('stay in Needs review'));
    });

    test('offline and silent keep the phone numbers per message', () {
      final s = geminiBarState(
        server: null,
        local: const AiReviewStatus(),
        unreadOnPhone: 0,
        openItems: 3,
        aiReadMessages: 4,
        unreadMessages: 2,
        offline: true,
      );
      expect(
        s.detail,
        contains('AI read 4 of your messages · 2 could not be read yet · 3 still need you'),
      );
    });

    test('with sharing off the bar says so, whatever the server answers', () {
      for (final server in [
        null,
        counted,
        const AiServerStatus(countedNow: false, eligible: false, held: 3),
      ]) {
        final s = geminiBarState(
          server: server,
          local: null,
          unreadOnPhone: 0,
          openItems: 0,
          sharingOff: true,
        );
        expect(s.tone, GeminiTone.warn);
        expect(s.title, 'AI is off: sharing is off on this phone');
        expect(s.detail, contains('Help PandaPay read messages'));
        expect(s.progress, isFalse);
      }
    });

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
      expect(s.title, 'AI is on');
      expect(s.detail, 'AI has not read any of your messages yet');
      expect(s.serverDetail, contains('Formats learned for your account: 4'));
      expect(s.serverDetail, contains('0 held back'));
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

    Future<void> pumpBar(
      WidgetTester tester,
      AiServerStatus? server, {
      bool sharing = true,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            geminiServerStatusProvider.overrideWith((ref) async => server),
            aiReviewStatusProvider.overrideWith(
              (ref) async => const AiReviewStatus(),
            ),
            aiUnreadCountProvider.overrideWith((ref) async => 0),
            app.smsSharedLearningConsentProvider.overrideWith(
              (ref) async => sharing
                  ? ConsentRecord(
                      purpose: 'sms_shared_learning',
                      granted: true,
                      grantedAt: DateTime(2026, 11, 1),
                    )
                  : null,
            ),
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
        find.text('AI is not receiving your message formats yet'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('says sharing is off, and shows no server numbers', (
      tester,
    ) async {
      await pumpBar(
        tester,
        const AiServerStatus(
          countedNow: true,
          eligible: true,
          total: 4,
          ready: 4,
        ),
        sharing: false,
      );
      expect(
        find.text('AI is off: sharing is off on this phone'),
        findsOneWidget,
      );
      expect(find.textContaining('done'), findsNothing);
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
      expect(find.text('AI is working'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('the phone details line is closed at first and shows this '
        "phone's own counts when opened", (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            geminiServerStatusProvider.overrideWith(
              (ref) async => const AiServerStatus(
                countedNow: true,
                eligible: true,
                total: 4,
                ready: 4,
              ),
            ),
            aiReviewStatusProvider.overrideWith(
              (ref) async => const AiReviewStatus(),
            ),
            aiUnreadCountProvider.overrideWith((ref) async => 0),
            aiPhoneDiagnosticsProvider.overrideWith(
              (ref) async => const AiPhoneDiagnostics(
                answersReady: 50,
                answersFailed: 14,
                linksSaved: 48,
                readyWithLink: 46,
                unknownMessages: 123,
                unknownWithText: 120,
                readByAiRule: 7,
                activeAiRules: 46,
                lastErasedAt: '2026-11-19T10:00:00Z',
                restoresTried: 1,
                lastPullProblem: 'SqliteException: refused here',
                lastPullProblemAt: '2026-11-20T16:01:00Z',
              ),
            ),
            app.smsSharedLearningConsentProvider.overrideWith(
              (ref) async => ConsentRecord(
                purpose: 'sms_shared_learning',
                granted: true,
                grantedAt: DateTime(2026, 11, 1),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: GeminiStatusBar(openItems: 2)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('gemini-phone-details')), findsNothing);
      await tester.tap(find.byKey(const Key('gemini-phone-details-toggle')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining(
          'Formats learned for your account: 4 (formats, not messages',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('50 usable, 14 failed'), findsOneWidget);
      expect(find.textContaining('46 of 50'), findsOneWidget);
      expect(find.textContaining('Formats linked to answers: 48'), findsOneWidget);
      expect(find.textContaining('last erased: 2026-11-19T10:00:00Z; restores tried: 1'), findsOneWidget);
      expect(find.textContaining('AI rules in use now: 46'), findsOneWidget);
      expect(find.textContaining('read by an AI rule: 7'), findsOneWidget);
      expect(find.textContaining('Unknown messages: 123, text still here: 120'), findsOneWidget);
      expect(
        find.textContaining('Last sync problem: SqliteException: refused here'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('gemini-phone-details-toggle')));
      await tester.pump();
      expect(find.byKey(const Key('gemini-phone-details')), findsNothing);
    });
  });
}
